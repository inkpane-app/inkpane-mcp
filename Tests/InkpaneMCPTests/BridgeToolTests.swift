import Foundation
import MCP
import InkpaneKit
import Testing

@testable import InkpaneMCP

@Suite struct BridgeArgumentTests {
    @Test func annotateScreenParsesEveryKind() throws {
        let params = try ArgumentParsing.annotateScreen(ToolArguments([
            "annotations": [
                ["type": "box", "x": 10, "y": 20, "width": 30, "height": 40, "label": "Here", "color": "blue"],
                ["type": "arrow", "from_x": 0, "from_y": 0, "to_x": 50.5, "to_y": "60", "ttl_seconds": 0],
                ["type": "text", "x": 1, "y": 2, "text": "Hello", "font_size": 30],
                ["type": "HIGHLIGHT", "x": 5, "y": 5, "width": 100, "height": 20],
            ],
            "ttl_seconds": 4,
            "replace": true,
        ]))
        #expect(params.ttl == 4)
        #expect(params.replace == true)
        #expect(params.annotations.map(\.kind) == [.box, .arrow, .text, .highlight])
        #expect(params.annotations[0].rect == Rect(x: 10, y: 20, width: 30, height: 40))
        #expect(params.annotations[0].label == "Here")
        #expect(params.annotations[0].color == "#0A84FF")
        #expect(params.annotations[1].to == BridgePoint(x: 50.5, y: 60))
        #expect(params.annotations[1].ttl == 0)
        #expect(params.annotations[2].text == "Hello")
        #expect(params.annotations[2].origin == BridgePoint(x: 1, y: 2))
        #expect(params.annotations[2].fontSize == 30)
    }

    @Test func annotateScreenRejectsBadInput() {
        func parse(_ args: [String: Value]) throws { _ = try ArgumentParsing.annotateScreen(ToolArguments(args)) }
        #expect(throws: ArgumentError.self) { try parse([:]) }
        #expect(throws: ArgumentError.self) { try parse(["annotations": []]) }
        #expect(throws: ArgumentError.self) { try parse(["annotations": [["type": "circle", "x": 1, "y": 1]]]) }
        #expect(throws: ArgumentError.self) { try parse(["annotations": [["type": "box", "x": 1, "y": 1, "width": 5]]]) }
        #expect(throws: ArgumentError.self) { try parse(["annotations": [["type": "box", "x": 1, "y": 1, "width": 5, "height": 5, "to_x": 3]]]) }
        #expect(throws: ArgumentError.self) { try parse(["annotations": [["type": "text", "x": 1, "y": 1]]]) }
        #expect(throws: ArgumentError.self) { try parse(["annotations": [["type": "text", "x": 1, "y": 1, "text": "a", "label": "b"]]]) }
        #expect(throws: ArgumentError.self) { try parse(["annotations": [["type": "box", "x": 1, "y": 1, "width": 5, "height": 5, "color": "nope"]]]) }
        #expect(throws: ArgumentError.self) { try parse(["annotations": [["type": "box", "x": 1, "y": 1, "width": 5, "height": 5]], "ttl_seconds": -1]) }
        // A mark lasts at most a day (0 keeps it until cleared).
        #expect(throws: ArgumentError.self) { try parse(["annotations": [["type": "box", "x": 1, "y": 1, "width": 5, "height": 5]], "ttl_seconds": 86_401]) }
        #expect(throws: ArgumentError.self) { try parse(["annotations": [["type": "box", "x": 1, "y": 1, "width": 5, "height": 5, "ttl_seconds": 1e300]]]) }
        #expect(throws: Never.self) { try parse(["annotations": [["type": "box", "x": 1, "y": 1, "width": 5, "height": 5]], "ttl_seconds": 86_400]) }
        let box = BridgeAnnotation.box(Rect(x: 1, y: 1, width: 5, height: 5))
        #expect(throws: BridgeErrorPayload.self) { try AnnotateParams(annotations: [box], ttl: .infinity).validate() }
        var lasting = box
        lasting.ttl = 1e12
        #expect(throws: BridgeErrorPayload.self) { try AnnotateParams(annotations: [lasting]).validate() }
        do {
            try parse(["annotations": [["type": "box", "x": 1, "y": 1, "width": 5, "height": 5], ["type": "arrow"]]])
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.hasPrefix("annotations[1]:"))
        }
    }

    @Test func annotateScreenParsesSpotlights() throws {
        let params = try ArgumentParsing.annotateScreen(ToolArguments([
            "annotations": [
                ["type": "spotlight", "x": 10, "y": 20, "width": 300, "height": 200],
                ["type": "Spotlight", "x": 0, "y": 0, "width": 50, "height": 40, "shape": "ELLIPSE", "dim_opacity": 0.8,
                 "label": "Look here", "color": "blue", "font_size": 18, "ttl_seconds": 0],
            ],
        ]))
        #expect(params.annotations.map(\.kind) == [.spotlight, .spotlight])
        #expect(params.annotations[0] == .spotlight(Rect(x: 10, y: 20, width: 300, height: 200)))
        let second = params.annotations[1]
        #expect(second.shape == .ellipse && second.dimOpacity == 0.8)
        #expect(second.label == "Look here" && second.color == "#0A84FF" && second.fontSize == 18 && second.ttl == 0)
    }

    @Test func annotateScreenRejectsBadSpotlights() {
        func parse(_ mark: [String: Value]) throws { _ = try ArgumentParsing.annotateScreen(ToolArguments(["annotations": [.object(mark)]])) }
        let rect: [String: Value] = ["type": "spotlight", "x": 1, "y": 1, "width": 50, "height": 50]
        #expect(throws: Never.self) { try parse(rect) }
        #expect(throws: ArgumentError.self) { try parse(["type": "spotlight", "x": 1, "y": 1, "width": 50]) }
        #expect(throws: ArgumentError.self) { try parse(rect.merging(["width": 0]) { $1 }) }
        #expect(throws: ArgumentError.self) { try parse(rect.merging(["shape": "star"]) { $1 }) }
        #expect(throws: ArgumentError.self) { try parse(rect.merging(["dim_opacity": 1]) { $1 }) }
        #expect(throws: ArgumentError.self) { try parse(rect.merging(["dim_opacity": 0.05]) { $1 }) }
        #expect(throws: ArgumentError.self) { try parse(rect.merging(["line_width": 3]) { $1 }) }
        #expect(throws: ArgumentError.self) { try parse(rect.merging(["to_x": 3]) { $1 }) }
        #expect(throws: ArgumentError.self) { try parse(rect.merging(["text": "hi"]) { $1 }) }
        // Spotlight options on other kinds.
        #expect(throws: ArgumentError.self) { try parse(["type": "box", "x": 1, "y": 1, "width": 5, "height": 5, "shape": "ellipse"]) }
        #expect(throws: ArgumentError.self) { try parse(["type": "highlight", "x": 1, "y": 1, "width": 5, "height": 5, "dim_opacity": 0.5]) }
    }

    @Test func catalogDescribesSpotlights() throws {
        let tool = try #require(ToolCatalog.tools.first { $0.name == ToolCatalog.annotateScreen })
        #expect(tool.description?.contains("spotlight") == true)
        let schema = String(describing: tool.inputSchema)
        #expect(schema.contains("spotlight") && schema.contains("dim_opacity") && schema.contains("ellipse"))
    }

    @Test func clearAnnotations() throws {
        #expect(try ArgumentParsing.clearAnnotations(ToolArguments(nil)) == ClearParams())
        let id = UUID().uuidString
        #expect(try ArgumentParsing.clearAnnotations(ToolArguments(["ids": [.string(id)]])) == ClearParams(ids: [id]))
        #expect(try ArgumentParsing.clearAnnotations(ToolArguments(["include_user": true])) == ClearParams(includeUser: true))
        #expect(throws: ArgumentError.self) { try ArgumentParsing.clearAnnotations(ToolArguments(["ids": ["not-an-id"]])) }
        #expect(throws: ArgumentError.self) {
            try ArgumentParsing.clearAnnotations(ToolArguments(["ids": [.string(id)], "include_user": true]))
        }
    }

    @Test func waitForUserAnnotation() throws {
        let request = try ArgumentParsing.waitForUserAnnotation(ToolArguments([
            "prompt": "Circle the broken button", "shape": "freehand", "timeout_seconds": 30, "include_ocr": false,
            "max_dimension": 0,
        ]))
        #expect(request.params == UserAnnotationParams(prompt: "Circle the broken button", shape: .freehand, timeout: 30, includeOcr: false))
        #expect(request.maxDimension == nil)
        #expect(throws: ArgumentError.self) { try ArgumentParsing.waitForUserAnnotation(ToolArguments(nil)) }
        #expect(throws: ArgumentError.self) { try ArgumentParsing.waitForUserAnnotation(ToolArguments(["prompt": "x", "shape": "circle"])) }
        #expect(throws: ArgumentError.self) { try ArgumentParsing.waitForUserAnnotation(ToolArguments(["prompt": "x", "timeout_seconds": 99999])) }
    }
}

@Suite struct BridgeToolHandlerTests {
    private func tools() -> InkpaneTools {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbm-\(UUID().uuidString.prefix(8))")
        return InkpaneTools(bridge: BridgeClient(location: BridgeLocation(directory: dir)))
    }

    @Test(arguments: [ToolCatalog.annotateScreen, ToolCatalog.clearAnnotations, ToolCatalog.waitForUserAnnotation])
    func explainsThatTheAppIsNotRunning(tool: String) async throws {
        let arguments: [String: Value] = switch tool {
        case ToolCatalog.annotateScreen: ["annotations": [["type": "box", "x": 1, "y": 1, "width": 5, "height": 5]]]
        case ToolCatalog.waitForUserAnnotation: ["prompt": "Circle it"]
        default: [:]
        }
        let result = await tools().call(name: tool, arguments: arguments)
        #expect(result.isError == true)
        guard case .text(let text, _, _)? = result.content.first else {
            Issue.record("expected text")
            return
        }
        #expect(text.hasPrefix("Inkpane app is not running"))
        #expect(text.contains("capture_screen"))
    }

    @Test func badArgumentsFailBeforeContactingTheApp() async {
        let result = await tools().call(name: ToolCatalog.annotateScreen, arguments: ["annotations": [["type": "box"]]])
        #expect(result.isError == true)
        guard case .text(let text, _, _)? = result.content.first else { return }
        #expect(!text.contains("not running"))
    }

    @Test func catalogListsTheBridgeTools() {
        let names = ToolCatalog.tools.map(\.name)
        #expect(names.contains("annotate_screen"))
        #expect(names.contains("clear_annotations"))
        #expect(names.contains("wait_for_user_annotation"))
        #expect(names.contains("capture_screen"))
        #expect(Set(names).count == names.count)
    }
}
