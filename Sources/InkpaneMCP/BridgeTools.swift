import CoreGraphics
import Foundation
import ImageIO
import MCP
import InkpaneKit

// Tools that need the Inkpane menu bar app: they are forwarded over its Unix socket
// (`BridgeClient`). Everything else in this server works without the app.

extension ToolCatalog {
    public static let annotateScreen = "annotate_screen"
    public static let clearAnnotations = "clear_annotations"
    public static let waitForUserAnnotation = "wait_for_user_annotation"

    public static let bridgeToolNames: Set<String> = [annotateScreen, clearAnnotations, waitForUserAnnotation, recordAction, captureScrolling]

    static let appNote = "Needs the Inkpane menu bar app to be running."

    private static func schema(_ type: String, _ description: String, extra: [String: Value] = [:]) -> Value {
        var schema: [String: Value] = ["type": .string(type), "description": .string(description)]
        schema.merge(extra) { a, _ in a }
        return .object(schema)
    }

    static let bridgeTools: [Tool] = [
        Tool(
            name: annotateScreen,
            title: "Annotate the user's screen",
            description: """
                Draw boxes, arrows, text and highlights on the user's screen to point at things, \
                or a spotlight that dims everything around an area. \
                \(coordinateNote) Annotations are click-through and fade out after ttl_seconds \
                (default \(Int(AnnotateParams.defaultTTL)); 0 keeps them until clear_annotations). \
                With window_id (from list_windows), the marks stick to that window: coordinates are \
                relative to the top-left corner of its frame, and the marks follow it when it moves, \
                hide while it is minimized, on another Space or covered, and go when it closes. \
                Returns the annotation ids. \(appNote)
                """,
            inputSchema: .object([
                "type": "object",
                "additionalProperties": false,
                "required": ["annotations"],
                "properties": .object([
                    "annotations": .object([
                        "type": "array",
                        "minItems": 1,
                        "maxItems": .int(AnnotateParams.maxAnnotations),
                        "description": "Marks to draw.",
                        "items": .object([
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["type"],
                            "properties": .object([
                                "type": schema("string", "box: outline of x/y/width/height. highlight: translucent marker over x/y/width/height. arrow: from_x/from_y to to_x/to_y (head at the 'to' end). text: text with its top-left corner at x/y. spotlight: dims the rest of the display, leaving x/y/width/height clear (several spotlights share one dim layer).", extra: ["enum": ["box", "arrow", "text", "highlight", "spotlight"]]),
                                "x": schema("number", "box/highlight/spotlight: left edge. text: left edge of the text."),
                                "y": schema("number", "box/highlight/spotlight: top edge. text: top edge of the text."),
                                "width": schema("number", "box/highlight/spotlight: width in points."),
                                "height": schema("number", "box/highlight/spotlight: height in points."),
                                "from_x": schema("number", "arrow: tail x."),
                                "from_y": schema("number", "arrow: tail y."),
                                "to_x": schema("number", "arrow: head x."),
                                "to_y": schema("number", "arrow: head y."),
                                "text": schema("string", "text: the text to show."),
                                "label": schema("string", "box/arrow/highlight/spotlight: optional caption drawn next to the mark."),
                                "color": schema("string", "Hex (#FF3B30, #FF3B3080) or a name: \(BridgeColor.names.keys.sorted().joined(separator: ", ")). Default red (yellow for highlight). For a spotlight, the colour of its label's plate (default black)."),
                                "shape": schema("string", "spotlight: shape of the clear area. Default rectangle.", extra: ["enum": ["rectangle", "ellipse"]]),
                                "dim_opacity": schema("number", "spotlight: how dark the rest of the screen gets, \(BridgeAnnotation.dimOpacityRange.lowerBound) to \(BridgeAnnotation.dimOpacityRange.upperBound). Default \(BridgeAnnotation.defaultDimOpacity).", extra: ["minimum": .double(BridgeAnnotation.dimOpacityRange.lowerBound), "maximum": .double(BridgeAnnotation.dimOpacityRange.upperBound)]),
                                "line_width": schema("number", "Stroke width in points (default 4)."),
                                "font_size": schema("number", "Text size in points (default 20 for text, 16 for labels)."),
                                "ttl_seconds": schema("number", "Overrides the call's ttl_seconds for this mark.", extra: ["minimum": 0, "maximum": .double(AnnotateParams.maxTTL)]),
                            ]),
                        ]),
                    ]),
                    "ttl_seconds": schema("number", "Seconds before the marks fade out. Default \(Int(AnnotateParams.defaultTTL)); 0 keeps them until clear_annotations. At most \(Int(AnnotateParams.maxTTL)).", extra: ["minimum": 0, "maximum": .double(AnnotateParams.maxTTL)]),
                    "replace": schema("boolean", "Remove your previous annotations first. Default false."),
                    "window_id": schema("integer", "Stick the marks to this window (window_id from list_windows). All coordinates are then relative to the top-left corner of the window's frame (x 0, y 0 is that corner), in points. Windows of apps on the user's privacy exclusion list are refused.", extra: ["minimum": 1]),
                ]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
        Tool(
            name: clearAnnotations,
            title: "Clear annotations",
            description: "Remove annotations drawn with annotate_screen: the given ids, or all of yours when ids is omitted. The user's own drawings stay unless include_user is true. \(appNote)",
            inputSchema: .object([
                "type": "object",
                "additionalProperties": false,
                "properties": .object([
                    "ids": schema("array", "Annotation ids returned by annotate_screen.", extra: ["items": .object(["type": "string"])]),
                    "include_user": schema("boolean", "Without ids: also clear what the user drew. Default false."),
                ]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)),
        Tool(
            name: waitForUserAnnotation,
            title: "Ask the user to point at something",
            description: """
                Show the user a banner with your prompt (e.g. "Circle the broken button") and wait \
                while they drag a rectangle or draw a freehand outline on screen and press Enter \
                (Esc cancels). Returns the region's bounding box in global screen points, a \
                screenshot of the region and the text recognized in it. Returns status \
                "cancelled" or "timed_out" when the user doesn't answer. Blocks for up to \
                timeout_seconds. \(appNote)
                """,
            inputSchema: .object([
                "type": "object",
                "additionalProperties": false,
                "required": ["prompt"],
                "properties": .object([
                    "prompt": schema("string", "What the user should select, shown on screen. Keep it short."),
                    "shape": schema("string", "The selection tool the user starts with (they can switch). Default rectangle.", extra: ["enum": ["rectangle", "freehand"]]),
                    "timeout_seconds": schema("number", "How long to wait. Default \(Int(UserAnnotationParams.defaultTimeout)), maximum \(Int(UserAnnotationParams.maxTimeout)).", extra: ["minimum": 1]),
                    "include_image": schema("boolean", "Return a screenshot of the region. Default true."),
                    "include_ocr": schema("boolean", "Return the text recognized in the region. Default true."),
                    "languages": schema("array", "OCR language codes in priority order. Default [\"zh-Hans\", \"en-US\"].", extra: ["items": .object(["type": "string"])]),
                    "max_dimension": schema("integer", "Downscale the returned image so its longer edge is at most this many pixels (default \(ArgumentParsing.defaultMaxDimension); 0 = full resolution).", extra: ["minimum": 0]),
                ]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
    ]
}

// MARK: - Argument parsing

extension ArgumentParsing {
    static let annotationKeys = [
        "type", "x", "y", "width", "height", "from_x", "from_y", "to_x", "to_y", "text", "label", "color",
        "line_width", "font_size", "ttl_seconds", "shape", "dim_opacity",
    ]

    public static func annotateScreen(_ args: ToolArguments) throws -> AnnotateParams {
        try args.rejectUnknown(allowed: ["annotations", "ttl_seconds", "replace", "window_id"])
        guard let value = args.values["annotations"] else { throw ArgumentError("annotations is required.") }
        guard let items = value.arrayValue else { throw ArgumentError("annotations must be an array of objects.") }
        let annotations = try items.enumerated().map { index, item in
            guard let object = item.objectValue else { throw ArgumentError("annotations[\(index)] must be an object.") }
            do {
                return try annotation(ToolArguments(object))
            } catch let error as ArgumentError {
                throw ArgumentError("annotations[\(index)]: \(error.message)")
            }
        }
        var windowID: UInt32?
        if let id = try args.int("window_id") {
            guard id > 0, id <= Int(UInt32.max) else { throw ArgumentError("window_id must be a positive window id (from list_windows).") }
            windowID = UInt32(id)
        }
        let params = AnnotateParams(
            annotations: annotations,
            ttl: try nonNegative(args, "ttl_seconds"),
            replace: try args.bool("replace"),
            windowId: windowID)
        do {
            try params.validate()
        } catch {
            throw ArgumentError(error.message)
        }
        return params
    }

    static func annotation(_ args: ToolArguments) throws -> BridgeAnnotation {
        try args.rejectUnknown(allowed: annotationKeys)
        guard let typeName = try args.string("type") else { throw ArgumentError("type is required (box, arrow, text, highlight or spotlight).") }
        guard let kind = BridgeAnnotation.Kind(rawValue: typeName.lowercased()) else {
            throw ArgumentError("type must be box, arrow, text, highlight or spotlight (got \(typeName)).")
        }
        func require(_ keys: [String]) throws -> [Double] {
            let missing = keys.filter { !args.has($0) }
            guard missing.isEmpty else { throw ArgumentError("a \(kind.rawValue) needs \(keys.joined(separator: ", ")); missing \(missing.joined(separator: ", ")).") }
            return try keys.map { try args.double($0)! }
        }
        func reject(_ keys: [String]) throws {
            let extra = keys.filter(args.has)
            guard extra.isEmpty else { throw ArgumentError("\(extra.joined(separator: ", ")) can't be used with a \(kind.rawValue).") }
        }

        var annotation = BridgeAnnotation(kind: kind)
        if kind != .spotlight { try reject(["shape", "dim_opacity"]) }
        switch kind {
        case .box, .highlight:
            try reject(["from_x", "from_y", "to_x", "to_y", "text"])
            let v = try require(["x", "y", "width", "height"])
            annotation.rect = Rect(x: v[0], y: v[1], width: v[2], height: v[3])
        case .spotlight:
            try reject(["from_x", "from_y", "to_x", "to_y", "text", "line_width"])
            let v = try require(["x", "y", "width", "height"])
            annotation.rect = Rect(x: v[0], y: v[1], width: v[2], height: v[3])
            if let name = try args.string("shape") {
                guard let shape = BridgeAnnotation.SpotlightShape(rawValue: name.lowercased()) else {
                    throw ArgumentError("shape must be rectangle or ellipse (got \(name)).")
                }
                annotation.shape = shape
            }
            annotation.dimOpacity = try args.double("dim_opacity")
        case .arrow:
            try reject(["x", "y", "width", "height", "text"])
            let v = try require(["from_x", "from_y", "to_x", "to_y"])
            annotation.from = BridgePoint(x: v[0], y: v[1])
            annotation.to = BridgePoint(x: v[2], y: v[3])
        case .text:
            try reject(["width", "height", "from_x", "from_y", "to_x", "to_y", "label"])
            let v = try require(["x", "y"])
            annotation.origin = BridgePoint(x: v[0], y: v[1])
            guard let text = try args.string("text") else { throw ArgumentError("a text annotation needs text.") }
            annotation.text = text
        }
        annotation.label = try args.string("label")
        if let color = try args.string("color") {
            guard let hex = BridgeColor.normalizedHex(color) else {
                throw ArgumentError("color must be #RRGGBB, #RRGGBBAA or one of \(BridgeColor.names.keys.sorted().joined(separator: ", ")).")
            }
            annotation.color = hex
        }
        annotation.lineWidth = try args.double("line_width")
        annotation.fontSize = try args.double("font_size")
        annotation.ttl = try nonNegative(args, "ttl_seconds")
        do {
            try annotation.validate()
        } catch {
            throw ArgumentError(error.message)
        }
        return annotation
    }

    public static func clearAnnotations(_ args: ToolArguments) throws -> ClearParams {
        try args.rejectUnknown(allowed: ["ids", "include_user"])
        let ids = try args.stringArray("ids")
        if let ids, let bad = ids.first(where: { UUID(uuidString: $0) == nil }) {
            throw ArgumentError("\(bad) is not an annotation id (ids come from annotate_screen).")
        }
        let includeUser = try args.bool("include_user")
        if ids != nil, includeUser == true { throw ArgumentError("include_user only applies when ids is omitted.") }
        return ClearParams(ids: ids, includeUser: includeUser)
    }

    public struct UserAnnotationRequest: Sendable {
        public var params: UserAnnotationParams
        public var maxDimension: Int?
    }

    public static func waitForUserAnnotation(_ args: ToolArguments) throws -> UserAnnotationRequest {
        try args.rejectUnknown(allowed: [
            "prompt", "shape", "timeout_seconds", "include_image", "include_ocr", "languages", maxDimensionKey,
        ])
        guard let prompt = try args.string("prompt") else { throw ArgumentError("prompt is required.") }
        var shape: SelectionShape?
        if let name = try args.string("shape") {
            guard let parsed = SelectionShape(rawValue: name.lowercased()) else {
                throw ArgumentError("shape must be rectangle or freehand.")
            }
            shape = parsed
        }
        let params = UserAnnotationParams(
            prompt: prompt, shape: shape, timeout: try args.double("timeout_seconds"),
            includeImage: try args.bool("include_image"), includeOcr: try args.bool("include_ocr"),
            languages: try args.stringArray("languages"))
        do {
            try params.validate()
        } catch {
            throw ArgumentError(error.message)
        }
        return UserAnnotationRequest(params: params, maxDimension: try maxDimension(args))
    }

    private static func nonNegative(_ args: ToolArguments, _ key: String) throws -> Double? {
        guard let value = try args.double(key) else { return nil }
        guard value >= 0 else { throw ArgumentError("\(key) must be >= 0.") }
        return value
    }
}

// MARK: - Handlers

extension InkpaneTools {
    /// Explains what to do when the app isn't running.
    static func appNotRunningMessage(tool: String, socketPath: String) -> String {
        """
        Inkpane app is not running, so \(tool) can't reach it (nothing is listening on \(socketPath)). \
        annotate_screen, clear_annotations, wait_for_user_annotation, record_action and capture_scrolling need the Inkpane menu bar app: \
        ask the user to start it (for example `open -a Inkpane`), then call \(tool) again. \
        capture_screen, capture_window, capture_region, read_screen_ocr and list_windows keep working without it.
        """
    }

    func callBridgeTool(name: String, args: ToolArguments) async -> CallTool.Result {
        do {
            switch name {
            case ToolCatalog.annotateScreen:
                return try await annotateScreen(ArgumentParsing.annotateScreen(args))
            case ToolCatalog.clearAnnotations:
                return try await clearAnnotations(ArgumentParsing.clearAnnotations(args))
            case ToolCatalog.recordAction:
                return try await recordAction(ArgumentParsing.recordAction(args))
            case ToolCatalog.captureScrolling:
                return try await captureScrolling(ArgumentParsing.captureScrolling(args))
            default:
                return try await waitForUserAnnotation(ArgumentParsing.waitForUserAnnotation(args))
            }
        } catch BridgeClientError.appNotRunning(let path) {
            return Self.error(Self.appNotRunningMessage(tool: name, socketPath: path))
        } catch {
            return Self.error(error.localizedDescription)
        }
    }

    struct AnnotateMetadata: Encodable {
        var ids: [String]
        var items: [AnnotateResult.Item]
        var window: AnnotateResult.Window?
    }

    func annotateScreen(_ params: AnnotateParams) async throws -> CallTool.Result {
        let result = try await bridge.annotate(params)
        let kinds = params.annotations.map(\.kind.rawValue).joined(separator: ", ")
        let lifetimes = Set(result.items.map(\.ttl))
        let lifetime: String
        switch lifetimes.count == 1 ? lifetimes.first! : -1 {
        case nil: lifetime = "they stay until clear_annotations"
        case let ttl? where ttl >= 0: lifetime = "they fade out after \(Self.seconds(ttl))"
        default: lifetime = "each fades out after its own ttl (or stays when it has none)"
        }
        var summary = "Drew \(result.items.count) annotation(s) on the user's screen (\(kinds)); \(lifetime)."
        if let windowID = params.windowId {
            guard let window = result.window else {
                // An app from before window_id ignored it and drew at screen coordinates: undo that.
                _ = try? await bridge.clear(ClearParams(ids: result.ids))
                return Self.error("""
                    This version of the Inkpane app can't stick annotations to a window (window_id). \
                    Ask the user to update Inkpane, or call annotate_screen without window_id, in screen coordinates.
                    """)
            }
            let name = [window.appName, window.title.map { "\"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
            summary += " They are anchored to window \(windowID)\(name.isEmpty ? "" : " (\(name))"): they follow it when it moves"
                + " and hide while it is minimized, on another Space or covered."
            if !window.isOnScreen { summary += " The window isn't on screen right now; they appear when it is." }
        }
        return CallTool.Result(
            content: [Self.text(summary + "\n" + JSON.encode(AnnotateMetadata(ids: result.ids, items: result.items, window: result.window)))],
            isError: false)
    }

    func clearAnnotations(_ params: ClearParams) async throws -> CallTool.Result {
        let result = try await bridge.clear(params)
        return CallTool.Result(
            content: [Self.text("Removed \(result.removed) annotation(s).\n" + JSON.encode(result))], isError: false)
    }

    struct SelectionMetadata: Encodable {
        var status: UserAnnotationResult.Status
        var reason: String?
        var region: UserAnnotationResult.Region?
        var path: String?
        /// Global frame (points) covered by the image.
        var frame: Rect?
        var scale: Double?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var returnedWidth: Int?
        var returnedHeight: Int?
        var pointsPerReturnedPixel: Double?
        var ocr: UserAnnotationResult.OCR?
        var captureError: String?
        var privacy: PrivacyReport?
        var note: String?
    }

    func waitForUserAnnotation(_ request: ArgumentParsing.UserAnnotationRequest) async throws -> CallTool.Result {
        let params = request.params
        var result = try await bridge.waitForUserAnnotation(params)
        var metadata = SelectionMetadata(status: result.status, reason: result.reason, region: result.region)

        switch result.status {
        case .cancelled:
            let why = result.reason.map { " (\($0))" } ?? ""
            metadata.note = "The user did not select anything. Ask in chat or try again later."
            return CallTool.Result(
                content: [Self.text("Cancelled: the user dismissed the selection request\(why).\n" + JSON.encode(metadata))],
                isError: false)
        case .timedOut:
            return CallTool.Result(
                content: [Self.text("Timed out: no selection within \(Self.seconds(params.effectiveTimeout)).\n" + JSON.encode(metadata))],
                isError: false)
        case .selected:
            break
        }
        guard let region = result.region else { throw BridgeClientError.invalidResponse("selected without a region") }

        let wantsImage = params.includeImage ?? true
        let wantsOCR = params.includeOcr ?? true
        var image: CGImage?
        var fullPNG: Data?
        var frame = result.image?.frame
        var scale = result.image?.scale

        if let encoded = result.image, let png = Data(base64Encoded: encoded.pngBase64), let decoded = Self.decodePNG(png) {
            image = decoded
            fullPNG = png
        } else if wantsImage || wantsOCR {
            // The app couldn't capture (e.g. it lacks Screen Recording); try from this process.
            do {
                let recognizer = TextRecognizer(languages: params.languages ?? TextRecognizer.defaultLanguages)
                let capture: Capture
                var ocr: OCRResult?
                if let policy = result.policy {
                    // The app's privacy rules travel with its answer: apply them here too.
                    let filtered = try await captureUnderPolicy(.region(region.bbox), policy: policy, ocr: wantsOCR ? recognizer : nil)
                    capture = filtered.capture
                    ocr = filtered.ocr
                    result.privacy = filtered.report
                } else {
                    capture = try await capturer.capture(.region(region.bbox))
                    if wantsOCR { ocr = try recognizer.recognize(capture.image, captureFrame: capture.frame) }
                }
                image = capture.image
                frame = capture.frame
                scale = capture.scale
                if let ocr, result.ocr == nil {
                    result.ocr = UserAnnotationResult.OCR(
                        text: ocr.text, languages: ocr.languages,
                        lines: ocr.lines.map { .init(text: $0.text, confidence: $0.confidence, screenBox: $0.screenBox) })
                }
                metadata.note = "Captured by inkpane-mcp because the app could not: \(result.captureError ?? "unknown error")"
                result.captureError = nil
            } catch {
                result.captureError = [result.captureError, error.localizedDescription].compactMap { $0 }.joined(separator: " / ")
            }
        }
        metadata.ocr = result.ocr.map { ocr in
            var rounded = ocr
            rounded.lines = ocr.lines.map {
                .init(text: $0.text, confidence: ($0.confidence * 100).rounded() / 100, screenBox: $0.screenBox?.rounded(places: 1))
            }
            return rounded
        }
        metadata.captureError = result.captureError
        metadata.privacy = result.privacy.flatMap { $0.isEmpty ? nil : $0 }

        var imageContent: Tool.Content?
        if let image {
            let png = try fullPNG ?? ImageUtilities.pngData(image)
            metadata.path = try store.save(png: png, kind: "selection").path
            metadata.frame = frame
            metadata.scale = scale.map { ($0 * 100).rounded() / 100 }
            metadata.pixelWidth = image.width
            metadata.pixelHeight = image.height
            if wantsImage {
                let scaled = try ImageUtilities.downscale(image, maxDimension: request.maxDimension)
                imageContent = Self.image(scaled === image ? png : try ImageUtilities.pngData(scaled))
                metadata.returnedWidth = scaled.width
                metadata.returnedHeight = scaled.height
                if let frame {
                    metadata.pointsPerReturnedPixel = ((frame.width / Double(scaled.width)) * 10_000).rounded() / 10_000
                }
            }
        }

        let display = region.displayIndex.map { " on display \($0)" } ?? ""
        var summary = "The user selected a \(region.shape.rawValue) region at \(region.bbox.rounded(places: 1))\(display)."
        if let ocr = result.ocr {
            summary += ocr.lines.isEmpty ? "\n\nNo text recognized in the region." : "\n\nText in the region:\n\(ocr.text)"
        }
        if let error = result.captureError { summary += "\n\nCould not capture the region: \(error)" }
        if let privacy = result.privacy?.summary { summary += "\n\n" + privacy }
        var content: [Tool.Content] = [Self.text(summary), Self.text(JSON.encode(metadata))]
        if let imageContent { content.append(imageContent) }
        return CallTool.Result(content: content, isError: false)
    }

    static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func seconds(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value)) s" : String(format: "%.1f s", value)
    }
}
