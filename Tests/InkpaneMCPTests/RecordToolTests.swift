import Darwin
import Foundation
import MCP
import InkpaneKit
import Testing

@testable import InkpaneMCP

@Suite struct RecordArgumentTests {
    func parse(_ args: [String: Value]) throws -> ArgumentParsing.RecordRequest {
        try ArgumentParsing.recordAction(ToolArguments(args))
    }

    @Test func startTargets() throws {
        #expect(try parse(["action": "start"]) == .start(RecordStartParams(target: .display, displayIndex: 0), app: nil, title: nil))
        #expect(try parse(["action": "START", "display": 1, "fps": 15, "show_clicks": false]) ==
            .start(RecordStartParams(target: .display, displayIndex: 1, fps: 15, showClicks: false), app: nil, title: nil))
        #expect(try parse(["action": "start", "window_id": 77, "show_keys": true]) ==
            .start(RecordStartParams(target: .window, windowId: 77, showKeys: true), app: nil, title: nil))
        #expect(try parse(["action": "start", "app": "Safari", "title": "Docs"]) ==
            .start(RecordStartParams(target: .window), app: "Safari", title: "Docs"))
        #expect(try parse(["action": "start", "x": 10, "y": 20, "width": 300, "height": 200, "max_duration_seconds": 30]) ==
            .start(RecordStartParams(target: .region, region: Rect(x: 10, y: 20, width: 300, height: 200), maxDuration: 30), app: nil, title: nil))
    }

    @Test func startSoundOptions() throws {
        #expect(try parse(["action": "start", "microphone": true]) ==
            .start(RecordStartParams(target: .display, displayIndex: 0, microphone: true), app: nil, title: nil))
        #expect(try parse(["action": "start", "window_id": 5, "microphone": false, "system_audio": true]) ==
            .start(RecordStartParams(target: .window, windowId: 5, microphone: false, systemAudio: true), app: nil, title: nil))
        #expect(throws: ArgumentError.self) { try parse(["action": "start", "microphone": "yes"]) }
        #expect(throws: ArgumentError.self) { try parse(["action": "stop", "microphone": true]) }
        #expect(RecordStartParams(systemAudio: true).requestsAudio)
        #expect(!RecordStartParams(microphone: false).requestsAudio)
        let tool = try #require(ToolCatalog.tools.first { $0.name == ToolCatalog.recordAction })
        guard case .object(let schema) = tool.inputSchema, case .object(let properties)? = schema["properties"] else {
            Issue.record("no properties")
            return
        }
        #expect(properties["microphone"] != nil && properties["system_audio"] != nil)
    }

    @Test func soundSummaries() {
        #expect(InkpaneTools.soundSummary(microphone: true, systemAudio: true) == ", with microphone and system audio")
        #expect(InkpaneTools.soundSummary(microphone: true, systemAudio: false) == ", with the microphone")
        #expect(InkpaneTools.soundSummary(microphone: false, systemAudio: true) == ", with system audio")
        #expect(InkpaneTools.soundSummary(microphone: false, systemAudio: false) == ", without sound")
        #expect(InkpaneTools.soundSummary(microphone: nil, systemAudio: nil) == "")
    }

    @Test func startRejectsBadInput() {
        #expect(throws: ArgumentError.self) { try parse([:]) }
        #expect(throws: ArgumentError.self) { try parse(["action": "rewind"]) }
        #expect(throws: ArgumentError.self) { try parse(["action": "start", "target": "window"]) }
        #expect(throws: ArgumentError.self) { try parse(["action": "start", "target": "display", "window_id": 3]) }
        #expect(throws: ArgumentError.self) { try parse(["action": "start", "window_id": 3, "x": 1, "y": 1, "width": 50, "height": 50]) }
        #expect(throws: ArgumentError.self) { try parse(["action": "start", "x": 1, "y": 1, "width": 50]) }
        #expect(throws: ArgumentError.self) { try parse(["action": "start", "fps": 120]) }
        #expect(throws: ArgumentError.self) { try parse(["action": "start", "gif": true]) }
    }

    @Test func stopAndStatus() throws {
        #expect(try parse(["action": "stop"]) == .stop(RecordStopParams()))
        #expect(try parse(["action": "stop", "recording_id": "r1", "gif": true, "gif_fps": 8, "gif_width": 480]) ==
            .stop(RecordStopParams(recordingId: "r1", gif: true, gifFps: 8, gifWidth: 480)))
        #expect(throws: ArgumentError.self) { try parse(["action": "stop", "gif_fps": 8]) }
        #expect(throws: ArgumentError.self) { try parse(["action": "stop", "fps": 8]) }
        #expect(try parse(["action": "status"]) == .status)
        #expect(throws: ArgumentError.self) { try parse(["action": "status", "gif": true]) }
    }

    @Test func catalogListsTheTool() throws {
        let tool = try #require(ToolCatalog.tools.first { $0.name == ToolCatalog.recordAction })
        #expect(tool.description?.contains("MP4") == true)
        #expect(ToolCatalog.bridgeToolNames.contains(ToolCatalog.recordAction))
    }
}

/// `record_action` against a fake app that answers the recording methods.
@Suite(.serialized) struct RecordToolHandlerTests {
    @Test func explainsThatTheAppIsNotRunning() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbm-\(UUID().uuidString.prefix(8))")
        let tools = InkpaneTools(bridge: BridgeClient(location: BridgeLocation(directory: dir)))
        let result = await tools.call(name: ToolCatalog.recordAction, arguments: ["action": "status"])
        #expect(result.isError == true)
        guard case .text(let text, _, _)? = result.content.first else { return }
        #expect(text.hasPrefix("Inkpane app is not running"))
        #expect(text.contains("record_action"))
    }

    @Test func startAndStopGoThroughTheApp() async throws {
        let location = BridgeLocation(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sbr-\(UUID().uuidString.prefix(8))"))
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try BridgeToken.write("tok", to: location.tokenURL)
        let fd = try UnixSocket.listen(path: location.socketURL.path)
        let methods = MethodLog()

        // Answers three connections (one per call), then stops.
        let server = Thread {
            defer { close(fd) }
            for _ in 0..<3 {
                let client = accept(fd, nil, nil)
                var buffer = LineBuffer()
                var bytes = [UInt8](repeating: 0, count: 4096)
                reading: while true {
                    let n = read(client, &bytes, bytes.count)
                    guard n > 0 else { break }
                    guard let line = try? buffer.append(Data(bytes[0..<n])).first,
                          let header = try? BridgeJSON.decoder().decode(BridgeRequestHeader.self, from: line)
                    else { continue }
                    methods.append(header.method ?? "")
                    let id = header.id ?? ""
                    let reply: Data
                    if header.method == "record_start" {
                        let request = try! BridgeJSON.decoder().decode(BridgeRequest<RecordStartParams>.self, from: line)
                        #expect(request.params.target == .region)
                        // The first start asks for the microphone; the second plays an app from
                        // before sound, which ignores system_audio and doesn't report it.
                        let old = request.params.systemAudio == true
                        #expect(old || request.params.microphone == true)
                        reply = try! BridgeJSON.line(BridgeResponse.success(id: id, RecordStartResult(
                            recordingId: "rec-1", frame: request.params.region!, displayIndex: 0, pixelWidth: 600, pixelHeight: 400,
                            fps: 30, showClicks: true, showKeys: false, maxDuration: 300, note: old ? nil : "Keys need Accessibility.",
                            microphone: old ? nil : true, systemAudio: old ? nil : false)))
                    } else {
                        let request = try! BridgeJSON.decoder().decode(BridgeRequest<RecordStopParams>.self, from: line)
                        #expect(request.params.gif == true)
                        reply = try! BridgeJSON.line(BridgeResponse.success(id: id, RecordStopResult(
                            recordingId: "rec-1", path: "/tmp/recording.mp4", duration: 4.25, pixelWidth: 600, pixelHeight: 400,
                            frameCount: 120, frame: Rect(x: 10, y: 20, width: 300, height: 200), endedBy: .agent, gifPath: "/tmp/recording.gif",
                            audio: [.microphone], annotationsPath: "/tmp/recording.inkpane-annotations.json", annotationsEditable: true,
                            privacy: PrivacyReport(redactedSecureFields: 1))))
                    }
                    try! UnixSocket.writeAll(client, reply)
                    break reading
                }
                close(client)
            }
        }
        server.start()

        let tools = InkpaneTools(bridge: BridgeClient(location: location))
        let started = await tools.call(name: ToolCatalog.recordAction,
                                       arguments: ["action": "start", "x": 10, "y": 20, "width": 300, "height": 200, "microphone": true])
        #expect(started.isError == false)
        guard case .text(let startText, _, _)? = started.content.first else { return }
        #expect(startText.contains("600×400 px, 30 fps, with the microphone."))
        #expect(startText.contains(#""microphone":true"#))
        #expect(!startText.contains("can't record sound"))
        #expect(startText.contains("Keys need Accessibility."))
        #expect(startText.contains(#""recording_id":"rec-1""#))

        let stopped = await tools.call(name: ToolCatalog.recordAction, arguments: ["action": "stop", "gif": true])
        #expect(stopped.isError == false)
        guard case .text(let stopText, _, _)? = stopped.content.first else { return }
        #expect(stopText.contains("/tmp/recording.mp4"))
        #expect(stopText.contains("4.2 s") || stopText.contains("4.3 s"))
        #expect(stopText.contains("GIF: /tmp/recording.gif"))
        #expect(stopText.contains("Sound: microphone."))
        #expect(stopText.contains(#""audio":["microphone"]"#))
        #expect(stopText.contains("editable track (/tmp/recording.inkpane-annotations.json)"))
        #expect(stopText.contains(#""annotations_editable":true"#))
        #expect(stopText.contains("Privacy: 1 password field(s) blacked out."))

        let oldApp = await tools.call(name: ToolCatalog.recordAction,
                                      arguments: ["action": "start", "x": 10, "y": 20, "width": 300, "height": 200, "system_audio": true])
        guard case .text(let oldText, _, _)? = oldApp.content.first else { return }
        #expect(oldText.contains("600×400 px, 30 fps."))
        #expect(oldText.contains("can't record sound"))
        #expect(methods.values == ["record_start", "record_stop", "record_start"])
    }
}

final class MethodLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.withLock { _values } }
    func append(_ value: String) { lock.withLock { _values.append(value) } }
}
