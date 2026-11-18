import Foundation
import Testing

@testable import InkpaneKit

@Suite struct BridgeRecordingTests {
    @Test func methodsAreAdvertised() {
        #expect(BridgeMethod(rawValue: "record_start") == .recordStart)
        #expect(BridgeMethod(rawValue: "record_stop") == .recordStop)
        #expect(BridgeMethod(rawValue: "record_status") == .recordStatus)
        #expect(HelloResult(app: "A", appVersion: "1").methods.contains("record_start"))
    }

    @Test func startParamsUseSnakeCase() throws {
        let params = RecordStartParams(target: .region, region: Rect(x: 10, y: 20, width: 300, height: 200), fps: 24, showKeys: true, maxDuration: 60)
        let json = String(decoding: try BridgeJSON.encoder().encode(BridgeRequest(id: "1", token: "t", method: .recordStart, params: params)), as: UTF8.self)
        #expect(json.contains(#""method":"record_start""#))
        #expect(json.contains(#""target":"region""#))
        #expect(json.contains(#""show_keys":true"#))
        #expect(json.contains(#""max_duration":60"#))
        let decoded = try BridgeJSON.decoder().decode(BridgeRequest<RecordStartParams>.self, from: Data(json.utf8))
        #expect(decoded.params == params)
        #expect(!json.contains("microphone") && !json.contains("system_audio"))
    }

    @Test func soundIsAdditive() throws {
        let params = RecordStartParams(microphone: true, systemAudio: false)
        let json = String(decoding: try BridgeJSON.encoder().encode(params), as: UTF8.self)
        #expect(json.contains(#""microphone":true"#) && json.contains(#""system_audio":false"#))
        #expect(try BridgeJSON.decoder().decode(RecordStartParams.self, from: Data(json.utf8)) == params)
        // An older client's request (no sound keys) and an older app's result still decode.
        let old = try BridgeJSON.decoder().decode(RecordStartParams.self, from: Data(#"{"target":"display"}"#.utf8))
        #expect(old.microphone == nil && old.systemAudio == nil)
        let oldResult = try BridgeJSON.decoder().decode(RecordStartResult.self, from: Data(#"{"recording_id":"r","frame":{"x":0,"y":0,"width":10,"height":10},"pixel_width":20,"pixel_height":20,"fps":30,"show_clicks":true,"show_keys":false,"max_duration":300}"#.utf8))
        #expect(oldResult.microphone == nil && oldResult.systemAudio == nil)
        let stop = RecordStopResult(recordingId: "r", path: "/a.mp4", duration: 1, pixelWidth: 2, pixelHeight: 2, frameCount: 1,
                                    frame: Rect(x: 0, y: 0, width: 1, height: 1), endedBy: .agent, audio: [.microphone, .systemAudio])
        let stopJSON = String(decoding: try BridgeJSON.encoder().encode(stop), as: UTF8.self)
        #expect(stopJSON.contains(#""audio":["microphone","system_audio"]"#))
        #expect(try BridgeJSON.decoder().decode(RecordStopResult.self, from: Data(stopJSON.utf8)) == stop)
        #expect(BridgeProtocol.version == 1)
    }

    @Test func startValidation() {
        #expect(throws: Never.self) { try RecordStartParams().validate() }
        #expect(throws: Never.self) { try RecordStartParams(target: .window, windowId: 42).validate() }
        #expect(throws: BridgeErrorPayload.self) { try RecordStartParams(target: .window).validate() }
        #expect(throws: BridgeErrorPayload.self) { try RecordStartParams(target: .region).validate() }
        #expect(throws: BridgeErrorPayload.self) { try RecordStartParams(target: .region, region: Rect(x: 0, y: 0, width: 4, height: 400)).validate() }
        #expect(throws: BridgeErrorPayload.self) { try RecordStartParams(target: .display, displayIndex: -1).validate() }
        #expect(throws: BridgeErrorPayload.self) { try RecordStartParams(target: .display, windowId: 3).validate() }
        #expect(throws: BridgeErrorPayload.self) { try RecordStartParams(fps: 0).validate() }
        #expect(throws: BridgeErrorPayload.self) { try RecordStartParams(maxDuration: 99_999).validate() }
        #expect(RecordStartParams().effectiveMaxDuration == RecordStartParams.defaultMaxDuration)
    }

    @Test func stopValidationAndResultRoundTrip() throws {
        #expect(throws: Never.self) { try RecordStopParams(gif: true, gifFps: 12, gifWidth: 480).validate() }
        #expect(throws: BridgeErrorPayload.self) { try RecordStopParams(gifFps: 12).validate() }
        #expect(throws: BridgeErrorPayload.self) { try RecordStopParams(gif: true, gifFps: 99).validate() }

        let result = RecordStopResult(
            recordingId: "r1", path: "/tmp/a.mp4", duration: 3.5, pixelWidth: 640, pixelHeight: 400, frameCount: 90,
            frame: Rect(x: 0, y: 0, width: 320, height: 200), endedBy: .maxDuration, gifPath: "/tmp/a.gif")
        let line = try BridgeJSON.line(BridgeResponse.success(id: "1", result))
        let json = String(decoding: line, as: UTF8.self)
        #expect(json.contains(#""ended_by":"max_duration""#))
        #expect(json.contains(#""gif_path":"/tmp/a.gif""#))
        #expect(try BridgeClient.decodeResult(line.dropLast(), as: RecordStopResult.self) == result)
        #expect(!json.contains("annotations"))

        // W6-2: an editable track is reported additively; older results still decode.
        var editable = result
        editable.annotationsPath = "/tmp/a.inkpane-annotations.json"
        editable.annotationsEditable = true
        let editableJSON = String(decoding: try BridgeJSON.line(BridgeResponse.success(id: "2", editable)), as: UTF8.self)
        #expect(editableJSON.contains(#""annotations_path":"/tmp/a.inkpane-annotations.json""#))
        #expect(editableJSON.contains(#""annotations_editable":true"#))
        #expect(try BridgeClient.decodeResult(try BridgeJSON.line(BridgeResponse.success(id: "2", editable)).dropLast(),
                                              as: RecordStopResult.self) == editable)
        #expect(!editableJSON.contains("privacy"))

        // Password fields blacked out in an agent's recording, reported like a screenshot's.
        var masked = result
        masked.privacy = PrivacyReport(redactedSecureFields: 2)
        let maskedLine = try BridgeJSON.line(BridgeResponse.success(id: "3", masked))
        #expect(String(decoding: maskedLine, as: UTF8.self).contains(#""redacted_secure_fields":2"#))
        #expect(try BridgeClient.decodeResult(maskedLine.dropLast(), as: RecordStopResult.self) == masked)
    }
}
