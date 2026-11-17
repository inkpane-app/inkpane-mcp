import MCP

/// Tool and resource definitions advertised to MCP clients.
public enum ToolCatalog {
    public static let captureScreen = "capture_screen"
    public static let captureWindow = "capture_window"
    public static let captureRegion = "capture_region"
    public static let readScreenOCR = "read_screen_ocr"
    public static let listWindows = "list_windows"

    public static let activeWindowsURI = "screen://windows/active"

    static let privacyNote =
        "When the Inkpane app is running, the user may be asked to allow access first, apps they excluded are left out (capturing them directly fails), and personal data may be blacked out; the result says what was hidden."

    static let coordinateNote =
        "Coordinates are global screen points: origin at the top-left of the main display, y grows downward, same space as list_windows frames."

    private static func integer(_ description: String, minimum: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .int(minimum) }
        return .object(schema)
    }

    private static func number(_ description: String) -> Value {
        .object(["type": "number", "description": .string(description)])
    }

    private static func string(_ description: String) -> Value {
        .object(["type": "string", "description": .string(description)])
    }

    private static func boolean(_ description: String) -> Value {
        .object(["type": "boolean", "description": .string(description)])
    }

    private static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    private static let maxDimension = integer(
        "Downscale the returned image so its longer edge is at most this many pixels (default \(ArgumentParsing.defaultMaxDimension); 0 = full resolution). The saved file is always full resolution.",
        minimum: 0)
    private static let display = integer("Display index from list_windows (0 = main display). Default 0.", minimum: 0)
    private static let windowID = integer("Window id from list_windows.", minimum: 1)
    private static let app = string("App name (e.g. \"Safari\") or bundle id (e.g. \"com.apple.Safari\"); captures its frontmost window.")
    private static let title = string("With app: only windows whose title contains this text (case-insensitive).")
    private static let region: [String: Value] = [
        "x": number("Left edge in global points."),
        "y": number("Top edge in global points."),
        "width": number("Width in points."),
        "height": number("Height in points."),
    ]
    private static let readOnly = Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: false)

    /// Every tool: the standalone screen tools, then the ones forwarded to the Inkpane app,
    /// then the UI tree and screenshot diff (`UITreeTool.swift`, `DiffTool.swift`).
    public static var tools: [Tool] { screenTools + bridgeTools + recordingTools + scrollingTools + [uiTreeTool, diffScreenshotsTool] }

    /// Tools that work without the Inkpane app.
    static let screenTools: [Tool] = [
        Tool(
            name: captureScreen,
            title: "Capture screen",
            description: "Screenshot a whole display. Returns a PNG image plus JSON metadata (saved file path, frame, scale). Requires Screen Recording permission. \(privacyNote)",
            inputSchema: object(["display": display, "max_dimension": maxDimension]),
            annotations: readOnly),
        Tool(
            name: captureWindow,
            title: "Capture window",
            description: "Screenshot a single window by window_id, or the frontmost window of an app. Works even if the window is partly covered. Returns a PNG image plus JSON metadata. \(privacyNote)",
            inputSchema: object(["window_id": windowID, "app": app, "title": title, "max_dimension": maxDimension]),
            annotations: readOnly),
        Tool(
            name: captureRegion,
            title: "Capture region",
            description: "Screenshot a rectangle of the screen. \(coordinateNote) A region spanning several displays is clipped to the display it overlaps most. \(privacyNote)",
            inputSchema: object(region.merging(["max_dimension": maxDimension]) { a, _ in a }, required: ["x", "y", "width", "height"]),
            annotations: readOnly),
        Tool(
            name: readScreenOCR,
            title: "Read text on screen (OCR)",
            description: "Recognize text locally with Apple Vision (Simplified Chinese + English by default). Target one of: display, window_id, app (+ title), a region (x/y/width/height) or image_path; defaults to the main display. Returns the text plus per-line bounding boxes in screen points (\(coordinateNote)) and normalized image coordinates. \(privacyNote)",
            inputSchema: object(
                region.merging([
                    "display": display,
                    "window_id": windowID,
                    "app": app,
                    "title": title,
                    "image_path": string("Path to a local image file to OCR instead of capturing the screen."),
                    "languages": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Vision language codes in priority order. Default [\"zh-Hans\", \"en-US\"].",
                    ]),
                    "recognition_level": .object([
                        "type": "string", "enum": ["accurate", "fast"], "description": "Default accurate.",
                    ]),
                    "min_confidence": number("Drop lines below this confidence (0-1). Default 0."),
                    "include_image": boolean("Also return the captured image. Default false."),
                    "include_boxes": boolean("Return per-line bounding boxes as JSON. Default true."),
                    "max_dimension": maxDimension,
                ]) { a, _ in a }),
            annotations: readOnly),
        Tool(
            name: listWindows,
            title: "List windows",
            description: "List windows front to back (lower z_order = closer to the front) with app name, bundle id, pid, window id, title, frame, layer and on-screen state, plus the active displays. Titles are only available with Screen Recording permission. With the Inkpane app running, windows of apps the user excluded are not listed.",
            inputSchema: object([
                "app": string("Only windows of this app (name or bundle id)."),
                "include_offscreen": boolean("Include minimized, hidden and other-Space windows. Default false."),
                "include_system": boolean("Include non-zero layers (menu bar, Dock, status items, overlays). Default false."),
            ]),
            annotations: Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
    ]

    /// Every resource: the window list, then the Inkpane library (`AssetResources.swift`).
    public static var resources: [Resource] { windowResources + assetResources }

    static let windowResources: [Resource] = [
        Resource(
            name: "active-windows",
            uri: activeWindowsURI,
            title: "Active windows",
            description: "On-screen windows front to back, the frontmost window, and the active displays.",
            mimeType: "application/json")
    ]
}
