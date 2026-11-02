import CoreGraphics
import Foundation

/// What a privacy filter did to one capture. Returned to agents so they know parts are hidden.
public struct PrivacyReport: Codable, Sendable, Hashable {
    /// Names (or bundle ids) of excluded apps that had windows in the captured area.
    public var excludedApps: [String]
    public var redactedEmails: Int
    public var redactedPhoneNumbers: Int
    public var redactedSecureFields: Int

    public init(excludedApps: [String] = [], redactedEmails: Int = 0, redactedPhoneNumbers: Int = 0, redactedSecureFields: Int = 0) {
        self.excludedApps = excludedApps
        self.redactedEmails = redactedEmails
        self.redactedPhoneNumbers = redactedPhoneNumbers
        self.redactedSecureFields = redactedSecureFields
    }

    public var redactedCount: Int { redactedEmails + redactedPhoneNumbers + redactedSecureFields }
    public var isEmpty: Bool { excludedApps.isEmpty && redactedCount == 0 }

    /// One sentence for the agent, or `nil` when nothing was hidden.
    public var summary: String? {
        var parts: [String] = []
        if !excludedApps.isEmpty {
            parts.append("windows of \(excludedApps.joined(separator: ", ")) were left out (excluded by the user)")
        }
        var redacted: [String] = []
        if redactedEmails > 0 { redacted.append("\(redactedEmails) email address(es)") }
        if redactedPhoneNumbers > 0 { redacted.append("\(redactedPhoneNumbers) phone number(s)") }
        if redactedSecureFields > 0 { redacted.append("\(redactedSecureFields) password field(s)") }
        if !redacted.isEmpty { parts.append("\(redacted.joined(separator: ", ")) blacked out") }
        guard !parts.isEmpty else { return nil }
        return "Privacy: " + parts.joined(separator: "; ") + "."
    }
}

/// Fills rectangles of an image with black.
public enum ImageRedactor {
    /// `rects` are in image pixels with a top-left origin; each grows by `padding` pixels.
    public static func blackOut(_ image: CGImage, pixelRects rects: [CGRect], padding: CGFloat = 2) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rects.map { $0.insetBy(dx: -padding, dy: -padding).intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        guard !clipped.isEmpty else { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw InkpaneError.imageEncodingFailed }
        context.draw(image, in: bounds)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for rect in clipped {
            // Core Graphics contexts have a bottom-left origin.
            context.fill(CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height))
        }
        guard let output = context.makeImage() else { throw InkpaneError.imageEncodingFailed }
        return output
    }

    /// Converts a rectangle in global points into pixels of an image that covers `frame`.
    public static func pixelRect(forScreenRect rect: Rect, imageWidth: Int, imageHeight: Int, frame: Rect) -> CGRect? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let visible = rect.cgRect.intersection(frame.cgRect)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        let sx = Double(imageWidth) / frame.width
        let sy = Double(imageHeight) / frame.height
        return CGRect(x: (visible.minX - frame.x) * sx, y: (visible.minY - frame.y) * sy,
                      width: visible.width * sx, height: visible.height * sy)
    }
}

/// Applies a `CapturePolicy`'s redaction to a capture, optionally returning OCR as well.
/// Exclusions are applied earlier, while capturing (see `ScreenCapturer.exclusions`).
public enum PrivacyFilter {
    public struct Output: @unchecked Sendable {
        public var capture: Capture
        /// Present when OCR was requested; sensitive text in it is replaced by placeholders.
        public var ocr: OCRResult?
        public var report: PrivacyReport
    }

    /// Runs OCR when `ocr` is given or the policy needs it, blacks out what the policy asks
    /// for, and redacts the OCR text the same way.
    public static func apply(
        to capture: Capture, policy: CapturePolicy, ocr: TextRecognizer?, excludedApps: [String] = []
    ) throws -> Output {
        // Detection sees every line; the caller's confidence threshold only filters the output.
        var recognizer = ocr ?? TextRecognizer()
        let threshold = recognizer.minimumConfidence
        recognizer.minimumConfidence = 0
        return try apply(to: capture, policy: policy, wantsOCR: ocr != nil, excludedApps: excludedApps, minimumConfidence: threshold) { image, frame, locating in
            try recognizer.recognize(image, captureFrame: frame, locating: locating)
        }
    }

    /// The same with an injectable recognizer. Run it without a confidence threshold so that
    /// nothing escapes redaction; `minimumConfidence` filters the returned lines.
    public static func apply(
        to capture: Capture, policy: CapturePolicy, wantsOCR: Bool, excludedApps: [String] = [], minimumConfidence: Double = 0,
        recognize: (CGImage, Rect?, ((String) -> [Range<String.Index>])?) throws -> (result: OCRResult, located: [[Rect]])
    ) throws -> Output {
        var report = PrivacyReport(excludedApps: excludedApps)
        let detector = SensitiveTextDetector(policy.redaction)
        var boxes: [CGRect] = []
        var ocr: OCRResult?

        if wantsOCR || detector.isEnabled {
            let locating: ((String) -> [Range<String.Index>])? = detector.isEnabled ? { detector.matches(in: $0).map(\.range) } : nil
            let (result, located) = try recognize(capture.image, capture.frame, locating)
            var lines = result.lines
            for index in lines.indices {
                guard detector.isEnabled else { break }
                let matches = detector.matches(in: lines[index].text)
                guard !matches.isEmpty else { continue }
                report.redactedEmails += matches.filter { $0.kind == .email }.count
                report.redactedPhoneNumbers += matches.filter { $0.kind == .phoneNumber }.count
                let found = index < located.count ? located[index] : []
                // Fall back to the whole line when Vision can't place the substring.
                boxes += found.isEmpty ? [lines[index].pixelBox.cgRect] : found.map(\.cgRect)
                lines[index].text = detector.redact(lines[index].text)
            }
            if wantsOCR { ocr = OCRResult(imageWidth: result.imageWidth, imageHeight: result.imageHeight, languages: result.languages, lines: lines) }
        }

        if policy.redaction.secureFields {
            for rect in policy.secureFieldRects {
                guard let pixels = ImageRedactor.pixelRect(
                    forScreenRect: rect, imageWidth: capture.image.width, imageHeight: capture.image.height, frame: capture.frame)
                else { continue }
                boxes.append(pixels)
                report.redactedSecureFields += 1
                // Whatever OCR read inside a password field (usually bullets) goes too.
                if var result = ocr {
                    result.lines.removeAll { $0.pixelBox.cgRect.intersects(pixels) }
                    ocr = result
                }
            }
        }

        if minimumConfidence > 0, var result = ocr {
            result.lines.removeAll { $0.confidence < minimumConfidence }
            ocr = result
        }
        var output = capture
        if !boxes.isEmpty { output.image = try ImageRedactor.blackOut(capture.image, pixelRects: boxes) }
        return Output(capture: output, ocr: ocr, report: report)
    }
}
