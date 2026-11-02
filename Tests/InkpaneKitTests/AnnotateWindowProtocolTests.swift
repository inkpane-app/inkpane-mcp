import Foundation
import Testing

@testable import InkpaneKit

/// `window_id` on `annotate` (W6-3): additive on protocol v1.
@Suite struct AnnotateWindowProtocolTests {
    @Test func windowIDIsAdditiveOnTheWire() throws {
        let rect = Rect(x: 1, y: 2, width: 3, height: 4)
        let pinned = AnnotateParams(annotations: [.box(rect)], windowId: 4242)
        let request = BridgeRequest(id: "1", token: "t", method: .annotate, params: pinned)
        let json = try #require(String(data: BridgeJSON.encoder().encode(request), encoding: .utf8))
        #expect(json.contains(#""window_id":4242"#))
        #expect(try BridgeJSON.decoder().decode(BridgeRequest<AnnotateParams>.self, from: Data(json.utf8)).params == pinned)
        let plain = try #require(String(data: BridgeJSON.encoder().encode(AnnotateParams(annotations: [.box(rect)])), encoding: .utf8))
        #expect(!plain.contains("window"))
        // A request from an older client decodes without it.
        let old = try BridgeJSON.decoder().decode(
            AnnotateParams.self, from: Data(#"{"annotations":[{"kind":"box","rect":{"x":1,"y":2,"width":3,"height":4}}]}"#.utf8))
        #expect(old.windowId == nil)

        #expect(throws: Never.self) { try pinned.validate() }
        #expect(throws: BridgeErrorPayload.self) { try AnnotateParams(annotations: [.box(rect)], windowId: 0).validate() }
        #expect(BridgeProtocol.version == 1)
    }

    @Test func resultSaysWhichWindowTheMarksFollow() throws {
        let window = AnnotateResult.Window(windowId: 7, appName: "Safari", title: "Docs", frame: Rect(x: 0, y: 25, width: 800, height: 600), isOnScreen: true)
        let result = AnnotateResult(items: [.init(id: "a")], window: window)
        let data = try BridgeJSON.encoder().encode(BridgeResponse.success(id: "1", result))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""window_id":7"#) && json.contains(#""is_on_screen":true"#) && json.contains(#""app_name":"Safari""#))
        #expect(try BridgeClient.decodeResult(data, as: AnnotateResult.self) == result)
        // Results from an app without window support have no window.
        let legacy = try BridgeJSON.encoder().encode(BridgeResponse.success(id: "1", AnnotateResult(items: [.init(id: "a")])))
        #expect(try BridgeClient.decodeResult(legacy, as: AnnotateResult.self).window == nil)
    }
}
