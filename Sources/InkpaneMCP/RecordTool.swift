import Foundation
import MCP
import InkpaneKit

// `record_action`: screen recording through the Inkpane app (forwarded over its socket like
// the annotation tools).

extension ToolCatalog {
    public static let recordAction = "record_action"

    private static func property(_ type: String, _ description: String, extra: [String: Value] = [:]) -> Value {
        var schema: [String: Value] = ["type": .string(type), "description": .string(description)]
        schema.merge(extra) { a, _ in a }
        return .object(schema)
    }

    static let recordingTools: [Tool] = [
        Tool(
            name: recordAction,
            title: "Record the screen",
            description: """
                Record the user's screen to an MP4, e.g. to show a bug or a demo. action "start" \
                begins recording a display (default the main one), a window's area (window_id, or \
                app + title) or a region (x/y/width/height; \(coordinateNote)). Your \
                annotate_screen marks and the user's drawings appear in the video; Inkpane's \
                controls don't. The user sees a recording panel and can stop it. action "stop" \
                finishes it and returns the file path and duration (optionally also a GIF); \
                "status" says whether a recording is running. Recordings stop by themselves after \
                max_duration_seconds. On macOS 15+ the video can have sound (microphone, \
                system_audio). \(appNote)
                """,
            inputSchema: .object([
                "type": "object",
                "additionalProperties": false,
                "required": ["action"],
                "properties": .object([
                    "action": property("string", "start, stop or status.", extra: ["enum": ["start", "stop", "status"]]),
                    "target": property("string", "start: what to record. Default display, or window/region when window_id/app or x/y/width/height are given.", extra: ["enum": ["display", "window", "region"]]),
                    "display": property("integer", "start: display index from list_windows (0 = main display).", extra: ["minimum": 0]),
                    "window_id": property("integer", "start: window id from list_windows; records that window's area.", extra: ["minimum": 1]),
                    "app": property("string", "start: app name or bundle id; records its frontmost window's area."),
                    "title": property("string", "start, with app: only windows whose title contains this text."),
                    "x": property("number", "start: region left edge in global points."),
                    "y": property("number", "start: region top edge in global points."),
                    "width": property("number", "start: region width in points."),
                    "height": property("number", "start: region height in points."),
                    "fps": property("integer", "start: frames per second (1-60). Default: the user's setting (30).", extra: ["minimum": 1, "maximum": 60]),
                    "show_clicks": property("boolean", "start: highlight mouse clicks. Default: the user's setting."),
                    "show_keys": property("boolean", "start: show pressed keys (needs Accessibility permission for Inkpane). Default: the user's setting."),
                    "show_cursor": property("boolean", "start: record the mouse pointer. Default: the user's setting."),
                    "microphone": property("boolean", "start: record the microphone (macOS 15+; needs Microphone permission for Inkpane, otherwise the recording is silent and the result has a note). Default: the user's setting."),
                    "system_audio": property("boolean", "start: record the Mac's sound, without Inkpane's own (macOS 15+). Default: the user's setting."),
                    "max_duration_seconds": property("number", "start: stop automatically after this long. Default \(Int(RecordStartParams.defaultMaxDuration)), maximum \(Int(RecordStartParams.maxDurationLimit)).", extra: ["minimum": 1]),
                    "recording_id": property("string", "stop: the id returned by start. Default: the current recording."),
                    "gif": property("boolean", "stop: also export an animated GIF. Default false."),
                    "gif_fps": property("integer", "stop, with gif: GIF frames per second (1-30, default 10).", extra: ["minimum": 1, "maximum": 30]),
                    "gif_width": property("integer", "stop, with gif: maximum GIF width in pixels (default 720).", extra: ["minimum": 64]),
                ]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
    ]
}

// MARK: - Argument parsing

extension ArgumentParsing {
    public enum RecordRequest: Sendable, Equatable {
        /// `app`/`title` are resolved to a window id by the handler, which can list windows.
        case start(RecordStartParams, app: String?, title: String?)
        case stop(RecordStopParams)
        case status
    }

    static let recordStartKeys = [
        "action", "target", "display", "window_id", "app", "title", "x", "y", "width", "height", "fps", "show_clicks",
        "show_keys", "show_cursor", "max_duration_seconds", "microphone", "system_audio",
    ]
    static let recordStopKeys = ["action", "recording_id", "gif", "gif_fps", "gif_width"]

    public static func recordAction(_ args: ToolArguments) throws -> RecordRequest {
        guard let action = try args.string("action")?.lowercased() else { throw ArgumentError("action is required (start, stop or status).") }
        switch action {
        case "start": return try recordStart(args)
        case "stop": return try recordStop(args)
        case "status":
            try args.rejectUnknown(allowed: ["action"])
            return .status
        default:
            throw ArgumentError("action must be start, stop or status (got \(action)).")
        }
    }

    static func recordStart(_ args: ToolArguments) throws -> RecordRequest {
        try args.rejectUnknown(allowed: recordStartKeys)
        var params = RecordStartParams()
        let window = try windowTarget(args)
        let region = try regionTarget(args)
        var target: RecordStartParams.Target
        if let name = try args.string("target") {
            guard let parsed = RecordStartParams.Target(rawValue: name.lowercased()) else {
                throw ArgumentError("target must be display, window or region.")
            }
            target = parsed
        } else {
            target = window != nil ? .window : region != nil ? .region : .display
        }
        var app: String?, title: String?
        switch target {
        case .display:
            guard window == nil, region == nil else { throw ArgumentError("A display recording takes only display.") }
            if case .display(let index) = try displayTarget(args) { params.displayIndex = index }
        case .window:
            guard region == nil, !args.has("display") else { throw ArgumentError("A window recording takes window_id or app (+ title) only.") }
            switch window {
            case .window(let id)?: params.windowId = id
            case .app(let name, let titleContains)?:
                app = name
                title = titleContains
            default: throw ArgumentError("A window recording needs window_id (from list_windows) or app.")
            }
        case .region:
            guard window == nil, !args.has("display") else { throw ArgumentError("A region recording takes x, y, width and height only.") }
            guard case .region(let rect)? = region else { throw ArgumentError("A region recording needs x, y, width and height.") }
            params.region = rect
        }
        params.target = target
        params.fps = try args.int("fps")
        params.showClicks = try args.bool("show_clicks")
        params.showKeys = try args.bool("show_keys")
        params.showCursor = try args.bool("show_cursor")
        params.maxDuration = try args.double("max_duration_seconds")
        params.microphone = try args.bool("microphone")
        params.systemAudio = try args.bool("system_audio")
        // App windows get their id later; validate the rest with a placeholder.
        var check = params
        if app != nil { check.windowId = 1 }
        do {
            try check.validate()
        } catch {
            throw ArgumentError(error.message)
        }
        return .start(params, app: app, title: title)
    }

    static func recordStop(_ args: ToolArguments) throws -> RecordRequest {
        try args.rejectUnknown(allowed: recordStopKeys)
        let params = RecordStopParams(
            recordingId: try args.string("recording_id"), gif: try args.bool("gif"),
            gifFps: try args.int("gif_fps"), gifWidth: try args.int("gif_width"))
        do {
            try params.validate()
        } catch {
            throw ArgumentError(error.message)
        }
        return .stop(params)
    }
}

// MARK: - Handler

extension InkpaneTools {
    /// ", with the microphone", ", with microphone and system audio", ", without sound", or ""
    /// when the app doesn't say (one from before sound).
    static func soundSummary(microphone: Bool?, systemAudio: Bool?) -> String {
        switch (microphone == true, systemAudio == true) {
        case (true, true): ", with microphone and system audio"
        case (true, false): ", with the microphone"
        case (false, true): ", with system audio"
        case (false, false): microphone == nil && systemAudio == nil ? "" : ", without sound"
        }
    }

    func recordAction(_ request: ArgumentParsing.RecordRequest) async throws -> CallTool.Result {
        switch request {
        case .start(var params, let app, let title):
            if let app {
                guard let window = WindowList.bestWindow(forApp: app, titleContains: title, in: WindowList.windows()) else {
                    throw InkpaneError.appWindowNotFound(app: app, title: title)
                }
                params.windowId = window.windowID
            }
            let result = try await bridge.recordStart(params)
            var summary = "Recording \(result.frame.rounded(places: 1)) at \(result.pixelWidth)×\(result.pixelHeight) px, \(result.fps) fps"
                + Self.soundSummary(microphone: result.microphone, systemAudio: result.systemAudio) + ". "
                + "Call record_action with action \"stop\" to finish it; it stops by itself after \(Self.seconds(result.maxDuration))."
            if let note = result.note { summary += "\nNote: \(note)" }
            if params.requestsAudio, result.microphone == nil, result.systemAudio == nil {
                summary += "\nNote: This version of the Inkpane app can't record sound, so the recording is silent. Update the app for sound."
            }
            return CallTool.Result(content: [Self.text(summary + "\n" + JSON.encode(result))], isError: false)
        case .stop(let params):
            let result = try await bridge.recordStop(params)
            var summary = "Saved a \(Self.seconds(result.duration)) recording (\(result.pixelWidth)×\(result.pixelHeight) px) to \(result.path)."
            switch result.endedBy {
            case .user: summary += " The user had already stopped it."
            case .maxDuration: summary += " It had stopped at its maximum duration."
            case .error: summary += " Capture had stopped early (for example a display was disconnected); the file has what was recorded."
            case .agent: break
            }
            if let audio = result.audio, !audio.isEmpty {
                summary += "\nSound: " + audio.map { $0 == .microphone ? "microphone" : "system audio" }.joined(separator: " and ") + "."
            }
            if let gif = result.gifPath { summary += "\nGIF: \(gif)" }
            if let error = result.gifError { summary += "\nThe GIF couldn't be made: \(error)" }
            if result.annotationsEditable == true, let track = result.annotationsPath {
                summary += "\nAnnotations are on a separate, editable track (\(track)); the MP4 has none drawn in. "
                    + "The user can edit them and export a version with or without them in Inkpane."
            }
            return CallTool.Result(content: [Self.text(summary + "\n" + JSON.encode(result))], isError: false)
        case .status:
            let result = try await bridge.recordStatus()
            let summary: String
            switch result.state {
            case .idle: summary = "Nothing is being recorded."
            case .recording: summary = "Recording, \(Self.seconds(result.elapsed ?? 0)) so far."
            case .paused: summary = "Recording is paused at \(Self.seconds(result.elapsed ?? 0))."
            }
            return CallTool.Result(content: [Self.text(summary + "\n" + JSON.encode(result))], isError: false)
        }
    }
}
