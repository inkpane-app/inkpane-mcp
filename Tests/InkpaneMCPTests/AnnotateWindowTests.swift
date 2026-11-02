import Foundation
import MCP
import InkpaneKit
import Testing

@testable import InkpaneMCP

/// `annotate_screen` with `window_id`: marks that stick to a window (W6-3).
@Suite(.serialized) struct AnnotateWindowTests {
    private let box: [String: Value] = ["type": "box", "x": 10, "y": 20, "width": 30, "height": 40]

    private func tools(_ app: FakeApp) -> InkpaneTools {
        InkpaneTools(bridge: BridgeClient(location: app.location, timeout: 5))
    }

    private func texts(_ result: CallTool.Result) -> [String] {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }
    }

    private struct Envelope: Decodable { var params: AnnotateParams }

    @Test func parsesWindowID() throws {
        let params = try ArgumentParsing.annotateScreen(ToolArguments(["annotations": [.object(box)], "window_id": 4242]))
        #expect(params.windowId == 4242)
        #expect(try ArgumentParsing.annotateScreen(ToolArguments(["annotations": [.object(box)], "window_id": "17"])).windowId == 17)
        #expect(try ArgumentParsing.annotateScreen(ToolArguments(["annotations": [.object(box)]])).windowId == nil)
        for bad: Value in [0, -3, 1.5, "front", .int(Int(UInt32.max) + 1)] {
            #expect(throws: ArgumentError.self, "\(bad)") {
                try ArgumentParsing.annotateScreen(ToolArguments(["annotations": [.object(self.box)], "window_id": bad]))
            }
        }
        let tool = try #require(ToolCatalog.tools.first { $0.name == ToolCatalog.annotateScreen })
        #expect(tool.description?.contains("window_id") == true)
        #expect(String(describing: tool.inputSchema).contains("window_id"))
    }

    @Test func anchoredMarksRoundTripThroughTheApp() async throws {
        let window = AnnotateResult.Window(
            windowId: 4242, appName: "Notes", title: "Groceries", frame: Rect(x: 100, y: 80, width: 600, height: 400), isOnScreen: false)
        let app = try FakeApp { _, _ in FakeApp.success(AnnotateResult(items: [.init(id: UUID().uuidString, ttl: 10)], window: window)) }
        defer { app.stop() }
        let result = await tools(app).call(name: ToolCatalog.annotateScreen, arguments: ["annotations": [.object(box)], "window_id": 4242])
        #expect(result.isError == false)
        let summary = try #require(texts(result).first)
        #expect(summary.contains("anchored to window 4242 (Notes \"Groceries\")"))
        #expect(summary.contains("isn't on screen right now"))
        #expect(summary.contains("\"window_id\":4242") && summary.contains("\"is_on_screen\":false"))

        #expect(app.methods == ["annotate"])
        let sent = try BridgeJSON.decoder().decode(Envelope.self, from: try #require(app.lines.first)).params
        #expect(sent.windowId == 4242)
        #expect(sent.annotations.first?.rect == Rect(x: 10, y: 20, width: 30, height: 40), "window-relative, as given")
    }

    @Test func anAppWithoutWindowSupportIsUndoneAndReported() async throws {
        let id = UUID().uuidString
        let app = try FakeApp { method, _ in
            method == "clear" ? FakeApp.success(ClearResult(removed: 1)) : FakeApp.success(AnnotateResult(items: [.init(id: id)]))
        }
        defer { app.stop() }
        let result = await tools(app).call(name: ToolCatalog.annotateScreen, arguments: ["annotations": [.object(box)], "window_id": 9])
        #expect(result.isError == true)
        #expect(texts(result).first?.contains("update Inkpane") == true)
        #expect(app.methods == ["annotate", "clear"])
    }

    @Test func excludedWindowsAreRefusedByTheApp() async throws {
        let app = try FakeApp { _, _ in FakeApp.failure(.excluded, InkpaneError.excludedApp(name: "1Password").localizedDescription) }
        defer { app.stop() }
        let result = await tools(app).call(name: ToolCatalog.annotateScreen, arguments: ["annotations": [.object(box)], "window_id": 3])
        #expect(result.isError == true)
        #expect(texts(result).first?.contains("1Password") == true)
    }
}
