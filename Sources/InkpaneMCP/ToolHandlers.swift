import CoreGraphics
import Foundation
import MCP
import InkpaneKit

/// Executes Inkpane tools and resources. Independent of the transport so it
/// can be exercised directly in tests.
public struct InkpaneTools: Sendable {
    /// Used when capturing without the app; its `exclusions` come from `INKPANE_MCP_EXCLUDE_APPS`.
    public var capturer: ScreenCapturer
    public var store: CaptureStore
    /// Connection to the Inkpane app: screen reads go through it when it is running, and
    /// annotate/clear/wait_for_user_annotation always need it.
    public var bridge: BridgeClient
    /// Whether screen reads may run without the app (see `ScreenRouting.swift`).
    public var requirement: AppRequirement
    /// Reads UI trees in this process (standalone, or under the app's policy).
    public var uiTreeReading: UITreeReading

    public init(
        capturer: ScreenCapturer = .init(), store: CaptureStore = .init(), bridge: BridgeClient = .init(),
        requirement: AppRequirement = .optional, uiTreeReading: UITreeReading = .live
    ) {
        self.capturer = capturer
        self.store = store
        self.bridge = bridge
        self.requirement = requirement
        self.uiTreeReading = uiTreeReading
    }

    /// Output directory from `INKPANE_MCP_OUTPUT_DIR`, else `$TMPDIR/inkpane-mcp`; app
    /// folder from `INKPANE_APP_DIR`, else the app's Application Support folder;
    /// `INKPANE_MCP_REQUIRE_APP` and `INKPANE_MCP_EXCLUDE_APPS`.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> InkpaneTools {
        let dir = environment["INKPANE_MCP_OUTPUT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        return InkpaneTools(
            capturer: ScreenCapturer(exclusions: StandaloneExclusions.fromEnvironment(environment)),
            store: CaptureStore(directory: dir), bridge: BridgeClient(location: .fromEnvironment(environment)),
            requirement: AppRequirement.fromEnvironment(environment))
    }

    // MARK: - Dispatch

    public func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let args = ToolArguments(arguments)
        if ToolCatalog.bridgeToolNames.contains(name) {
            return await callBridgeTool(name: name, args: args)
        }
        do {
            switch name {
            case ToolCatalog.captureScreen:
                return try await capture(ArgumentParsing.captureScreen(args), maxDimension: ArgumentParsing.maxDimension(args), tool: name)
            case ToolCatalog.captureWindow:
                return try await capture(ArgumentParsing.captureWindow(args), maxDimension: ArgumentParsing.maxDimension(args), tool: name)
            case ToolCatalog.captureRegion:
                return try await capture(ArgumentParsing.captureRegion(args), maxDimension: ArgumentParsing.maxDimension(args), tool: name)
            case ToolCatalog.readScreenOCR:
                return try await readText(ArgumentParsing.readScreenOCR(args))
            case ToolCatalog.listWindows:
                return try await listWindows(ArgumentParsing.listWindows(args))
            case ToolCatalog.getUITree:
                return try await getUITree(ArgumentParsing.getUITree(args))
            case ToolCatalog.diffScreenshots:
                return try await diffScreenshots(ArgumentParsing.diffScreenshots(args))
            default:
                return Self.error("Unknown tool: \(name)")
            }
        } catch {
            return Self.error(error.localizedDescription)
        }
    }

    // MARK: - Tools

    struct CaptureMetadata: Encodable {
        var kind: Capture.Kind
        var path: String
        /// Global frame (points) covered by the image.
        var frame: Rect
        var scale: Double
        var pixelWidth: Int
        var pixelHeight: Int
        var returnedWidth: Int?
        var returnedHeight: Int?
        /// Multiply a pixel coordinate in the returned image by this and add
        /// `frame.x` / `frame.y` to get global screen points.
        var pointsPerReturnedPixel: Double?
        var display: DisplayInfo?
        var window: WindowInfo?
        var requestedRegion: Rect?
        /// What was left out or blacked out for the user's privacy.
        var privacy: PrivacyReport?
        var note: String?
    }

    func capture(_ target: CaptureTarget, maxDimension: Int?, tool: String) async throws -> CallTool.Result {
        let obtained = try await obtainCapture(target, ocr: nil, tool: tool)
        let capture = obtained.capture
        let (metadata, image) = try saveAndPrepare(obtained, maxDimension: maxDimension, includeImage: true)
        var summary = "Captured \(Self.describe(capture)) — \(capture.image.width)×\(capture.image.height) px, saved to \(metadata.path)"
        if let privacy = obtained.privacy?.summary { summary += "\n" + privacy }
        var content: [Tool.Content] = [Self.text(summary + "\n" + JSON.encode(metadata))]
        if let image { content.append(image) }
        return CallTool.Result(content: content, isError: false)
    }

    struct OCRLine: Encodable {
        var text: String
        var confidence: Double
        var screenBox: Rect?
        var pixelBox: Rect
        var normalizedBox: Rect
    }

    struct OCRMetadata: Encodable {
        var source: String
        var path: String?
        var frame: Rect?
        var imageWidth: Int
        var imageHeight: Int
        var languages: [String]
        var lineCount: Int
        var lines: [OCRLine]?
        var privacy: PrivacyReport?
        var note: String?
    }

    func readText(_ request: ArgumentParsing.OCRRequest) async throws -> CallTool.Result {
        let result: OCRResult
        var frame: Rect?
        var path: String?
        var source: String
        var imageContent: Tool.Content?
        var privacy: PrivacyReport?
        var note: String?

        switch request.source {
        case .image(let imagePath):
            // A file the agent already has: no screen is read, so the app isn't involved.
            let url = URL(fileURLWithPath: imagePath)
            let image = try ImageUtilities.loadImage(at: url)
            path = url.path
            source = "image \(url.path)"
            if request.includeImage {
                let scaled = try ImageUtilities.downscale(image, maxDimension: request.maxDimension)
                imageContent = Self.image(try ImageUtilities.pngData(scaled))
            }
            result = try request.recognizer.recognize(image, captureFrame: nil)
        case .capture(let target):
            let obtained = try await obtainCapture(target, ocr: request.recognizer, tool: ToolCatalog.readScreenOCR)
            let (metadata, content) = try saveAndPrepare(obtained, maxDimension: request.maxDimension, includeImage: request.includeImage)
            frame = obtained.capture.frame
            path = metadata.path
            source = Self.describe(obtained.capture)
            imageContent = content
            privacy = obtained.privacy
            note = obtained.note
            result = try obtained.ocr ?? request.recognizer.recognize(obtained.capture.image, captureFrame: frame)
        }

        let lines = result.lines.map {
            OCRLine(
                text: $0.text,
                confidence: ($0.confidence * 100).rounded() / 100,
                screenBox: $0.screenBox?.rounded(places: 1),
                pixelBox: $0.pixelBox.rounded(places: 0),
                normalizedBox: $0.normalizedBox.rounded(places: 4))
        }
        let metadata = OCRMetadata(
            source: source, path: path, frame: frame, imageWidth: result.imageWidth, imageHeight: result.imageHeight,
            languages: result.languages, lineCount: lines.count, lines: request.includeBoxes ? lines : nil,
            privacy: privacy.flatMap { $0.isEmpty ? nil : $0 }, note: note)

        let text = result.lines.isEmpty ? "(no text recognized)" : result.text
        var header = "Recognized \(lines.count) line(s) from \(source):"
        if let summary = privacy?.summary { header = summary + "\n" + header }
        var content: [Tool.Content] = [
            Self.text("\(header)\n\n\(text)"),
            Self.text(JSON.encode(metadata)),
        ]
        if let imageContent { content.append(imageContent) }
        return CallTool.Result(content: content, isError: false)
    }

    struct WindowListing: Encodable {
        var screenRecordingPermission: Bool
        var note: String?
        var displays: [DisplayInfo]
        var frontmostWindowID: UInt32?
        var windows: [WindowInfo]
    }

    func listWindows(_ options: WindowListOptions) async throws -> CallTool.Result {
        let listing = try await obtainWindowListing(options, tool: ToolCatalog.listWindows)
        return CallTool.Result(content: [Self.text(JSON.encode(listing))], isError: false)
    }

    static func windowListing(_ options: WindowListOptions) -> WindowListing {
        let windows = WindowList.windows(options)
        let granted = ScreenRecordingPermission.isGranted
        return WindowListing(
            screenRecordingPermission: granted,
            note: granted
                ? nil
                : "Window titles are hidden because Screen Recording permission is not granted. "
                    + InkpaneError.permissionDenied().localizedDescription,
            displays: DisplayInfo.all(),
            frontmostWindowID: WindowList.frontmostWindow(in: windows)?.windowID,
            windows: windows)
    }

    // MARK: - Resources

    struct ActiveWindows: Encodable {
        var screenRecordingPermission: Bool
        var note: String?
        var frontmostWindow: WindowInfo?
        var displays: [DisplayInfo]
        var windows: [WindowInfo]
    }

    public func readResource(uri: String) async throws -> ReadResource.Result {
        if uri == ToolCatalog.activeWindowsURI {
            let listing: WindowListing
            do {
                listing = try await obtainWindowListing(.init(), tool: uri)
            } catch {
                throw MCPError.internalError(error.localizedDescription)
            }
            let payload = ActiveWindows(
                screenRecordingPermission: listing.screenRecordingPermission,
                note: listing.note,
                frontmostWindow: listing.windows.first { $0.windowID == listing.frontmostWindowID },
                displays: listing.displays,
                windows: listing.windows)
            return ReadResource.Result(contents: [.text(JSON.encode(payload), uri: uri, mimeType: "application/json")])
        }
        if uri == ToolCatalog.recentAssetsURI || uri.hasPrefix(ToolCatalog.assetURIPrefix) {
            return try await readAssetResource(uri: uri)
        }
        throw MCPError.invalidParams("Unknown resource: \(uri)")
    }

    // MARK: - Helpers

    private func saveAndPrepare(_ obtained: ObtainedCapture, maxDimension: Int?, includeImage: Bool) throws -> (CaptureMetadata, Tool.Content?) {
        let capture = obtained.capture
        let fullPNG = try ImageUtilities.pngData(capture.image)
        let url = try store.save(png: fullPNG, kind: capture.kind.rawValue, date: capture.capturedAt)

        var content: Tool.Content?
        var returned: CGImage?
        if includeImage {
            let scaled = try ImageUtilities.downscale(capture.image, maxDimension: maxDimension)
            let png = scaled === capture.image ? fullPNG : try ImageUtilities.pngData(scaled)
            content = Self.image(png)
            returned = scaled
        }

        var notes: [String] = []
        if let requested = capture.requestedRegion {
            notes.append("Requested region \(requested) was clipped to display \(capture.display?.index ?? 0).")
        } else if let window = capture.window, !window.isOnScreen {
            notes.append("Window is not on screen (minimized, hidden or on another Space); the image may be blank or stale.")
        }
        if let note = obtained.note { notes.append(note) }

        let metadata = CaptureMetadata(
            kind: capture.kind, path: url.path, frame: capture.frame, scale: (capture.scale * 100).rounded() / 100,
            pixelWidth: capture.image.width, pixelHeight: capture.image.height,
            returnedWidth: returned?.width, returnedHeight: returned?.height,
            pointsPerReturnedPixel: returned.map { ((capture.frame.width / Double($0.width)) * 10_000).rounded() / 10_000 },
            display: capture.display, window: capture.window, requestedRegion: capture.requestedRegion,
            privacy: obtained.privacy.flatMap { $0.isEmpty ? nil : $0 },
            note: notes.isEmpty ? nil : notes.joined(separator: " "))
        return (metadata, content)
    }

    static func describe(_ capture: Capture) -> String {
        switch capture.kind {
        case .display:
            return "display \(capture.display?.index ?? 0)"
        case .window:
            guard let window = capture.window else { return "window" }
            let title = window.title.map { " \"\($0)\"" } ?? ""
            return "window \(window.windowID)\(title) of \(window.appName ?? "unknown app")"
        case .region:
            return "region \(capture.frame)"
        }
    }

    static func text(_ string: String) -> Tool.Content {
        .text(text: string, annotations: nil, _meta: nil)
    }

    static func image(_ png: Data) -> Tool.Content {
        .image(data: png.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil)
    }

    static func error(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [text(message)], isError: true)
    }
}

enum JSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
