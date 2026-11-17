import Foundation

// Scrolling captures over the bridge (`capture_scrolling`). The app asks the user to confirm,
// brings the target window forward, scrolls it automatically from where it is to the end
// while stitching the frames into one long image (its own scrolling capture, with its border
// and controls on screen), applies the user's privacy settings, and writes the image to a PNG
// file in its folder. The caller takes the file over (moves or deletes it).

// MARK: - capture_scrolling

public struct CaptureScrollingParams: Codable, Sendable, Equatable {
    /// Default and largest image height, in pixels.
    public static let maxHeightLimit = 30_000
    /// How long the app may scroll before it stops and returns what it has, by default and at most.
    public static let defaultMaxDuration: Double = 90
    public static let maxDurationLimit: Double = 300

    /// A window (`window` / `app`) or a region; not a display.
    public var target: BridgeCaptureTarget
    /// Also recognize the text of the whole image.
    public var ocr: BridgeOCROptions?
    /// Stop once the image is this tall (pixels). Default `maxHeightLimit`.
    public var maxHeight: Int?
    /// Stop scrolling after this many seconds. Default `defaultMaxDuration`.
    public var maxDuration: Double?
    /// The MCP tool this is for, for the audit log.
    public var tool: String?

    public init(target: CaptureTarget, ocr: TextRecognizer? = nil, maxHeight: Int? = nil, maxDuration: Double? = nil, tool: String? = nil) {
        self.target = BridgeCaptureTarget(target)
        self.ocr = ocr.map(BridgeOCROptions.init)
        self.maxHeight = maxHeight
        self.maxDuration = maxDuration
        self.tool = tool
    }

    public var effectiveMaxDuration: Double { maxDuration ?? Self.defaultMaxDuration }

    public func validate() throws(BridgeErrorPayload) {
        func fail(_ message: String) -> BridgeErrorPayload { BridgeErrorPayload(.invalidRequest, message) }
        switch target.kind {
        case .display:
            throw fail("A scrolling capture needs a window (window_id or app) or a region, not a whole display.")
        case .window:
            guard let id = target.windowId, id > 0 else { throw fail("window_id must be a window id from list_windows.") }
        case .app:
            guard let app = target.app, !app.isEmpty else { throw fail("app is empty.") }
        case .region:
            guard let rect = target.rect, rect.width >= 16, rect.height >= 16 else { throw fail("The region must be at least 16×16 points.") }
        }
        if let maxHeight, !(100...Self.maxHeightLimit).contains(maxHeight) {
            throw fail("max_height must be between 100 and \(Self.maxHeightLimit) pixels.")
        }
        if let maxDuration, !(maxDuration.isFinite && maxDuration >= 5 && maxDuration <= Self.maxDurationLimit) {
            throw fail("max_duration_seconds must be between 5 and \(Int(Self.maxDurationLimit)).")
        }
    }
}

public struct CaptureScrollingResult: Codable, Sendable, Equatable {
    /// Why the capture ended.
    public enum EndedBy: String, Codable, Sendable {
        /// Scrolling reached the end of the content.
        case bottom
        /// The image reached `max_height` (or the app's own limit).
        case limit
        /// `max_duration_seconds` ran out.
        case timeout
        /// The app didn't scroll for synthetic scroll events: the image is what was visible.
        case unsupported
        /// The user took over (touched the mouse or trackpad) and clicked Done.
        case user
        /// The stitching lost its place (the content changed as it scrolled) and stepping back
        /// didn't find it again: the image stops where it was lost.
        case lost

        /// Unknown values from a newer app decode as `user`.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = EndedBy(rawValue: raw) ?? .user
        }
    }

    /// The stitched image (PNG), with the privacy settings applied. The caller owns it.
    public var path: String
    /// The scrolled area on screen (global points); the image is its width.
    public var frame: Rect
    /// Pixels per point.
    public var scale: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// The window captured, when the target was one.
    public var window: WindowInfo?
    public var endedBy: EndedBy
    /// Present when OCR was requested. Line boxes are in image pixels; `screen_box` is absent.
    public var ocr: OCRResult?
    public var privacy: PrivacyReport?
    public var note: String?

    public init(
        path: String, frame: Rect, scale: Double, pixelWidth: Int, pixelHeight: Int, window: WindowInfo? = nil, endedBy: EndedBy,
        ocr: OCRResult? = nil, privacy: PrivacyReport? = nil, note: String? = nil
    ) {
        self.path = path
        self.frame = frame
        self.scale = scale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.window = window
        self.endedBy = endedBy
        self.ocr = ocr
        self.privacy = privacy
        self.note = note
    }
}

extension BridgeClient {
    /// Waits for the whole capture: the user's confirmation, the scrolling (up to
    /// `max_duration_seconds`) and the privacy pass.
    public func captureScrolling(_ params: CaptureScrollingParams) async throws -> CaptureScrollingResult {
        try await call(.captureScrolling, params, as: CaptureScrollingResult.self,
                       timeout: params.effectiveMaxDuration + 240, tool: params.tool)
    }
}
