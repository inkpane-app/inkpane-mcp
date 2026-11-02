import CoreGraphics
import Foundation
import Vision

/// One line of text found by OCR.
public struct RecognizedText: Codable, Sendable, Hashable {
    public var text: String
    /// Vision confidence, 0...1.
    public var confidence: Double
    /// Bounding box normalized to the image, origin top-left, 0...1.
    public var normalizedBox: Rect
    /// Bounding box in image pixels, origin top-left.
    public var pixelBox: Rect
    /// Bounding box in global screen points. `nil` when the image did not come
    /// from a screen capture.
    public var screenBox: Rect?

    public init(text: String, confidence: Double, normalizedBox: Rect, pixelBox: Rect, screenBox: Rect?) {
        self.text = text
        self.confidence = confidence
        self.normalizedBox = normalizedBox
        self.pixelBox = pixelBox
        self.screenBox = screenBox
    }
}

public struct OCRResult: Codable, Sendable, Hashable {
    public var imageWidth: Int
    public var imageHeight: Int
    public var languages: [String]
    public var lines: [RecognizedText]

    public init(imageWidth: Int, imageHeight: Int, languages: [String], lines: [RecognizedText]) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.languages = languages
        self.lines = lines
    }

    /// All recognized lines joined with newlines, in reading order.
    public var text: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

/// Local OCR with Vision's `VNRecognizeTextRequest`.
public struct TextRecognizer: Sendable {
    public enum Level: String, Codable, Sendable, CaseIterable {
        case accurate, fast
    }

    public static let defaultLanguages = ["zh-Hans", "en-US"]

    public var languages: [String]
    public var level: Level
    public var usesLanguageCorrection: Bool
    /// Lines below this confidence are dropped.
    public var minimumConfidence: Double

    public init(
        languages: [String] = TextRecognizer.defaultLanguages, level: Level = .accurate,
        usesLanguageCorrection: Bool = true, minimumConfidence: Double = 0
    ) {
        self.languages = languages
        self.level = level
        self.usesLanguageCorrection = usesLanguageCorrection
        self.minimumConfidence = minimumConfidence
    }

    /// Recognition languages Vision supports for `level` on this system.
    public static func supportedLanguages(level: Level = .accurate) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .accurate ? .accurate : .fast
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    /// Recognizes text in `image`. Pass `captureFrame` (the global frame the
    /// image covers) to also get screen-space boxes.
    public func recognize(_ image: CGImage, captureFrame: Rect? = nil) throws -> OCRResult {
        try recognize(image, captureFrame: captureFrame, locating: nil).result
    }

    /// Like `recognize(_:captureFrame:)`, and also finds where parts of each line are:
    /// `locating` returns ranges within a line's text, and `located[i]` holds their boxes in
    /// image pixels (top-left origin) for line `i`. Auto-redaction uses it to black out just
    /// an email address or a phone number rather than its whole line.
    public func recognize(
        _ image: CGImage, captureFrame: Rect?, locating: ((String) -> [Range<String.Index>])?
    ) throws -> (result: OCRResult, located: [[Rect]]) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = usesLanguageCorrection

        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let unsupported = languages.filter { !supported.contains($0) }
        if !unsupported.isEmpty {
            throw InkpaneError.unsupportedLanguages(unsupported, supported: supported)
        }
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw InkpaneError.ocrFailed(error.localizedDescription)
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        var located: [[Rect]] = []
        let lines: [RecognizedText] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                Double(candidate.confidence) >= minimumConfidence
            else { return nil }
            if let locating {
                located.append(locating(candidate.string).compactMap { range in
                    guard let box = (try? candidate.boundingBox(for: range))??.boundingBox else { return nil }
                    let flipped = CoordinateConversion.flipNormalized(box)
                    return Rect(CoordinateConversion.normalizedToPixels(flipped, imageSize: imageSize))
                })
            } else {
                located.append([])
            }
            let normalized = CoordinateConversion.flipNormalized(observation.boundingBox)
            let pixels = CoordinateConversion.normalizedToPixels(normalized, imageSize: imageSize)
            let screen = captureFrame.map {
                Rect(CoordinateConversion.pixelsToScreen(pixels, imageSize: imageSize, captureFrame: $0.cgRect))
            }
            return RecognizedText(
                text: candidate.string, confidence: Double(candidate.confidence),
                normalizedBox: Rect(normalized), pixelBox: Rect(pixels), screenBox: screen)
        }
        return (OCRResult(imageWidth: image.width, imageHeight: image.height, languages: languages, lines: lines), located)
    }
}
