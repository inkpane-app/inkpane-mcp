import CoreGraphics
import Foundation
import MCP
import InkpaneKit

// `capture_scrolling`: a scrolling capture through the Inkpane app (forwarded over its socket
// like record_action). The app scrolls the target to the end and stitches one long image; this
// side saves it and returns it in slices a model can read, since one image of a long page
// would be scaled down until its text is unreadable.

extension ToolCatalog {
    public static let captureScrolling = "capture_scrolling"

    static let scrollingTools: [Tool] = [
        Tool(
            name: captureScrolling,
            title: "Capture a whole scrolling page",
            description: """
                Capture a window or region that scrolls (a long web page, chat, document or list) as \
                one long image: Inkpane scrolls it from where it is now to the end and stitches the \
                frames. Give window_id (from list_windows), app (+ title), or a region \
                (x/y/width/height; \(coordinateNote)). With a window, Inkpane brings it to the front \
                and captures its scrolling content area when it can find one (otherwise the whole \
                window). Scroll the content to where the capture should start first: it only scrolls \
                down. The user is asked to confirm every capture, sees Inkpane's border and controls, \
                and can take over or cancel by touching the mouse or trackpad. Returns the image in \
                slices from top to bottom (slice_width wide, overlapping a little) plus the saved \
                full-size file path; include_ocr adds the page's text, which is often all you need. \
                Needs Inkpane Pro and Accessibility permission for Inkpane. \(privacyNote) \(appNote)
                """,
            inputSchema: .object([
                "type": "object",
                "additionalProperties": false,
                "properties": .object([
                    "window_id": .object(["type": "integer", "minimum": 1, "description": "Window id from list_windows."]),
                    "app": .object(["type": "string", "description": "App name or bundle id; its frontmost window."]),
                    "title": .object(["type": "string", "description": "With app: only windows whose title contains this text."]),
                    "x": .object(["type": "number", "description": "Region left edge in global points."]),
                    "y": .object(["type": "number", "description": "Region top edge in global points."]),
                    "width": .object(["type": "number", "description": "Region width in points."]),
                    "height": .object(["type": "number", "description": "Region height in points."]),
                    "include_image": .object(["type": "boolean", "description": "Return the image slices. Default true."]),
                    "include_ocr": .object(["type": "boolean", "description": "Also return the recognized text of the whole capture. Default false."]),
                    "languages": .object(["type": "array", "items": .object(["type": "string"]), "description": "include_ocr: recognition languages, e.g. [\"en-US\", \"zh-Hans\"]."]),
                    "slice_width": .object([
                        "type": "integer", "minimum": 200, "maximum": 4000,
                        "description": .string("Width of the returned slices in pixels (default \(ArgumentParsing.ScrollingRequest.defaultSliceWidth); the capture is never scaled up)."),
                    ]),
                    "max_slices": .object([
                        "type": "integer", "minimum": 1, "maximum": .int(ArgumentParsing.ScrollingRequest.maxSlicesLimit),
                        "description": .string("Return at most this many slices, from the top (default \(ArgumentParsing.ScrollingRequest.defaultMaxSlices)). The saved file always has everything."),
                    ]),
                    "max_height": .object([
                        "type": "integer", "minimum": 100, "maximum": .int(CaptureScrollingParams.maxHeightLimit),
                        "description": .string("Stop once the image is this many pixels tall (default and maximum \(CaptureScrollingParams.maxHeightLimit))."),
                    ]),
                    "max_duration_seconds": .object([
                        "type": "number", "minimum": 5, "maximum": .int(Int(CaptureScrollingParams.maxDurationLimit)),
                        "description": .string("Stop scrolling after this long and return what was captured (default \(Int(CaptureScrollingParams.defaultMaxDuration)))."),
                    ]),
                ]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
    ]
}

// MARK: - Argument parsing

extension ArgumentParsing {
    public struct ScrollingRequest: Sendable, Equatable {
        public static let defaultSliceWidth = 1280
        public static let defaultMaxSlices = 6
        public static let maxSlicesLimit = 20

        public var params: CaptureScrollingParams
        public var includeImage: Bool
        public var sliceWidth: Int
        public var maxSlices: Int
    }

    static let scrollingKeys = windowKeys + regionKeys + [
        "include_image", "include_ocr", "languages", "slice_width", "max_slices", "max_height", "max_duration_seconds",
    ]

    public static func captureScrolling(_ args: ToolArguments) throws -> ScrollingRequest {
        try args.rejectUnknown(allowed: scrollingKeys)
        let window = try windowTarget(args)
        let region = try regionTarget(args)
        if window != nil, region != nil { throw ArgumentError("Choose one target: window_id, app, or a region (x/y/width/height).") }
        guard let target = window ?? region else {
            throw ArgumentError("Provide window_id (from list_windows), app, or a region (x/y/width/height).")
        }
        var recognizer: TextRecognizer?
        if try args.bool("include_ocr") == true {
            var ocr = TextRecognizer()
            if let languages = try args.stringArray("languages") { ocr.languages = languages }
            recognizer = ocr
        } else if args.has("languages") {
            throw ArgumentError("languages only applies with include_ocr.")
        }
        let params = CaptureScrollingParams(
            target: target, ocr: recognizer, maxHeight: try args.int("max_height"), maxDuration: try args.double("max_duration_seconds"),
            tool: ToolCatalog.captureScrolling)
        do {
            try params.validate()
        } catch {
            throw ArgumentError(error.message)
        }
        let sliceWidth = try args.int("slice_width") ?? ScrollingRequest.defaultSliceWidth
        guard (200...4000).contains(sliceWidth) else { throw ArgumentError("slice_width must be between 200 and 4000.") }
        let maxSlices = try args.int("max_slices") ?? ScrollingRequest.defaultMaxSlices
        guard (1...ScrollingRequest.maxSlicesLimit).contains(maxSlices) else {
            throw ArgumentError("max_slices must be between 1 and \(ScrollingRequest.maxSlicesLimit).")
        }
        return ScrollingRequest(params: params, includeImage: try args.bool("include_image") ?? true, sliceWidth: sliceWidth, maxSlices: maxSlices)
    }
}

// MARK: - Slicing

/// How a long image is cut for a model: scaled to `width` (never up), then cut into pieces at
/// most `maxHeight` tall that overlap by `overlap` pixels, so a line cut at one edge is whole in
/// the next piece.
public enum LongImageSlicing {
    public static let maxSliceHeight = 1568
    public static let overlap = 48

    public struct Slice: Sendable, Equatable, Encodable {
        /// Rows of the full image this slice shows (`y` to `y + height`), in its pixels.
        public var y: Int
        public var height: Int
        /// The returned image's size.
        public var returnedWidth: Int
        public var returnedHeight: Int
    }

    public static func slices(width: Int, height: Int, sliceWidth: Int, maxHeight: Int = maxSliceHeight, overlap: Int = overlap) -> [Slice] {
        guard width > 0, height > 0 else { return [] }
        let scale = min(1, Double(sliceWidth) / Double(width))
        let returnedWidth = max(1, Int((Double(width) * scale).rounded()))
        // Source rows per slice and per overlap, so the returned slices stay within maxHeight.
        let rows = max(1, Int((Double(maxHeight) / scale).rounded(.down)))
        let overlapRows = min(rows / 2, Int((Double(overlap) / scale).rounded(.up)))
        var result: [Slice] = []
        var y = 0
        while true {
            let h = min(rows, height - y)
            result.append(Slice(y: y, height: h, returnedWidth: returnedWidth, returnedHeight: max(1, Int((Double(h) * scale).rounded()))))
            if y + h >= height { break }
            y += rows - overlapRows
        }
        return result
    }

    /// The slice's pixels, scaled.
    public static func image(_ slice: Slice, of image: CGImage) throws -> CGImage {
        guard let cropped = image.cropping(to: CGRect(x: 0, y: slice.y, width: image.width, height: slice.height)) else {
            throw InkpaneError.imageEncodingFailed
        }
        guard slice.returnedWidth != cropped.width || slice.returnedHeight != cropped.height else { return cropped }
        guard let context = CGContext(
            data: nil, width: slice.returnedWidth, height: slice.returnedHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw InkpaneError.imageEncodingFailed }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: slice.returnedWidth, height: slice.returnedHeight))
        guard let scaled = context.makeImage() else { throw InkpaneError.imageEncodingFailed }
        return scaled
    }
}

// MARK: - Handler

extension InkpaneTools {
    struct ScrollingMetadata: Encodable {
        var path: String
        /// The scrolled area on screen (global points).
        var frame: Rect
        var scale: Double
        var pixelWidth: Int
        var pixelHeight: Int
        var window: WindowInfo?
        var endedBy: CaptureScrollingResult.EndedBy
        var slices: [LongImageSlicing.Slice]
        /// Slices left out by max_slices.
        var omittedSlices: Int?
        var privacy: PrivacyReport?
        var note: String?
    }

    static func endedBySummary(_ endedBy: CaptureScrollingResult.EndedBy) -> String {
        switch endedBy {
        case .bottom: "It scrolled to the end."
        case .limit: "It stopped at the maximum height; there may be more below."
        case .timeout: "It stopped at max_duration_seconds; there may be more below."
        case .unsupported: "The app didn't scroll for automatic scrolling, so this is only what was visible."
        case .user: "The user took over and finished the capture."
        case .lost: "Inkpane lost its place while scrolling (the content changed as it scrolled), so the image stops there; the rest of the page is missing."
        }
    }

    func captureScrolling(_ request: ArgumentParsing.ScrollingRequest) async throws -> CallTool.Result {
        let result: CaptureScrollingResult
        do {
            result = try await bridge.captureScrolling(request.params)
        } catch BridgeClientError.remote(let payload) where payload.code == .unknownMethod {
            throw ArgumentError("The running Inkpane app is too old for capture_scrolling. Ask the user to update Inkpane.")
        }
        // Take the app's file over: it goes where this server keeps its captures.
        let source = URL(fileURLWithPath: result.path)
        let png = try Data(contentsOf: source)
        let url = try store.save(png: png, kind: "scrolling", label: result.window?.appName)
        try? FileManager.default.removeItem(at: source)

        var content: [Tool.Content] = []
        let all = LongImageSlicing.slices(width: result.pixelWidth, height: result.pixelHeight, sliceWidth: request.sliceWidth)
        let returned = request.includeImage ? Array(all.prefix(request.maxSlices)) : []
        var notes = [result.note].compactMap { $0 }
        if request.includeImage, returned.count < all.count {
            notes.append("Returned the first \(returned.count) of \(all.count) slices (max_slices); the rest is in the saved file.")
        }
        let metadata = ScrollingMetadata(
            path: url.path, frame: result.frame, scale: result.scale, pixelWidth: result.pixelWidth, pixelHeight: result.pixelHeight,
            window: result.window, endedBy: result.endedBy, slices: returned,
            omittedSlices: request.includeImage && returned.count < all.count ? all.count - returned.count : nil,
            privacy: result.privacy.flatMap { $0.isEmpty ? nil : $0 }, note: notes.isEmpty ? nil : notes.joined(separator: " "))
        var summary = "Scrolling capture: \(result.pixelWidth)×\(result.pixelHeight) px, saved to \(url.path). " + Self.endedBySummary(result.endedBy)
        if !returned.isEmpty {
            summary += " Slices below go from top to bottom; each overlaps the next by a few lines."
        }
        content.append(Self.text(summary + "\n" + JSON.encode(metadata)))

        if !returned.isEmpty {
            let image = try ImageUtilities.loadImage(at: url)
            for (index, slice) in returned.enumerated() {
                content.append(Self.text("Slice \(index + 1) of \(all.count): rows \(slice.y)–\(slice.y + slice.height) of \(result.pixelHeight)"))
                content.append(Self.image(try ImageUtilities.pngData(LongImageSlicing.image(slice, of: image))))
            }
        }
        if let ocr = result.ocr {
            content.append(Self.text("Text (\(ocr.lines.count) lines):\n" + ocr.text))
        }
        return CallTool.Result(content: content, isError: false)
    }
}
