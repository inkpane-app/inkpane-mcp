import Foundation
import MCP
import InkpaneKit
import Testing

@testable import InkpaneMCP

@Suite struct ToolArgumentsTests {
    @Test func numbersAcceptIntsDoublesAndStrings() throws {
        let args = ToolArguments(["a": .int(3), "b": .double(4.0), "c": .string(" 5 "), "d": .double(1.5)])
        #expect(try args.int("a") == 3)
        #expect(try args.int("b") == 4)
        #expect(try args.int("c") == 5)
        #expect(throws: ArgumentError.self) { try args.int("d") }
        #expect(try args.double("d") == 1.5)
        #expect(try args.int("missing") == nil)
    }

    @Test func nullIsTreatedAsMissing() throws {
        let args = ToolArguments(["window_id": .null])
        #expect(!args.has("window_id"))
        #expect(try args.int("window_id") == nil)
    }

    @Test func booleansAndStrings() throws {
        let args = ToolArguments(["t": .bool(true), "s": .string("FALSE"), "blank": .string("   "), "n": .int(1)])
        #expect(try args.bool("t") == true)
        #expect(try args.bool("s") == false)
        #expect(try args.string("blank") == nil)
        #expect(throws: ArgumentError.self) { try args.string("n") }
        #expect(throws: ArgumentError.self) { try args.bool("n") }
    }

    @Test func stringArrays() throws {
        let args = ToolArguments(["a": ["en-US", "zh-Hans"], "b": .string("en-US, ja-JP"), "c": [.int(1)]])
        #expect(try args.stringArray("a") == ["en-US", "zh-Hans"])
        #expect(try args.stringArray("b") == ["en-US", "ja-JP"])
        #expect(throws: ArgumentError.self) { try args.stringArray("c") }
    }
}

@Suite struct ArgumentParsingTests {
    @Test func captureScreenDefaultsToMainDisplay() throws {
        #expect(try ArgumentParsing.captureScreen(ToolArguments(nil)) == .display(index: 0))
        #expect(try ArgumentParsing.captureScreen(ToolArguments(["display": 2])) == .display(index: 2))
        #expect(throws: ArgumentError.self) { try ArgumentParsing.captureScreen(ToolArguments(["display": -1])) }
    }

    @Test func unknownArgumentsAreRejected() {
        #expect(throws: ArgumentError.self) { try ArgumentParsing.captureScreen(ToolArguments(["screen": 1])) }
        #expect(throws: ArgumentError.self) { try ArgumentParsing.captureWindow(ToolArguments(["window": 12])) }
    }

    @Test func maxDimension() throws {
        #expect(try ArgumentParsing.maxDimension(ToolArguments(nil)) == ArgumentParsing.defaultMaxDimension)
        #expect(try ArgumentParsing.maxDimension(ToolArguments(["max_dimension": 0])) == nil)
        #expect(try ArgumentParsing.maxDimension(ToolArguments(["max_dimension": 800])) == 800)
        #expect(throws: ArgumentError.self) { try ArgumentParsing.maxDimension(ToolArguments(["max_dimension": -5])) }
    }

    @Test func captureWindowTargets() throws {
        #expect(try ArgumentParsing.captureWindow(ToolArguments(["window_id": 4242])) == .window(id: 4242))
        #expect(try ArgumentParsing.captureWindow(ToolArguments(["app": "Safari"])) == .app("Safari", titleContains: nil))
        #expect(
            try ArgumentParsing.captureWindow(ToolArguments(["app": "com.apple.Safari", "title": "GitHub"]))
                == .app("com.apple.Safari", titleContains: "GitHub"))
    }

    @Test func captureWindowValidation() {
        let invalid: [[String: Value]] = [
            [:],
            ["window_id": 1, "app": "Safari"],
            ["window_id": 0],
            ["window_id": 5, "title": "x"],
            ["title": "x"],
            ["window_id": .int(Int(UInt32.max) + 1)],
        ]
        for args in invalid {
            #expect(throws: ArgumentError.self) { try ArgumentParsing.captureWindow(ToolArguments(args)) }
        }
    }

    @Test func captureRegion() throws {
        let target = try ArgumentParsing.captureRegion(
            ToolArguments(["x": -100.5, "y": 20, "width": "300", "height": 200, "max_dimension": 0]))
        #expect(target == .region(Rect(x: -100.5, y: 20, width: 300, height: 200)))
        #expect(throws: ArgumentError.self) { try ArgumentParsing.captureRegion(ToolArguments(["x": 1, "y": 2, "width": 3])) }
        #expect(throws: ArgumentError.self) {
            try ArgumentParsing.captureRegion(ToolArguments(["x": 1, "y": 2, "width": 0, "height": 3]))
        }
    }

    @Test func ocrDefaultsToMainDisplayWithDefaultOptions() throws {
        let request = try ArgumentParsing.readScreenOCR(ToolArguments(nil))
        #expect(request.source == .capture(.display(index: 0)))
        #expect(request.recognizer.languages == TextRecognizer.defaultLanguages)
        #expect(request.recognizer.level == .accurate)
        #expect(request.includeImage == false)
        #expect(request.includeBoxes == true)
    }

    @Test func ocrTargets() throws {
        #expect(try ArgumentParsing.readScreenOCR(ToolArguments(["display": 1])).source == .capture(.display(index: 1)))
        #expect(try ArgumentParsing.readScreenOCR(ToolArguments(["window_id": 7])).source == .capture(.window(id: 7)))
        #expect(
            try ArgumentParsing.readScreenOCR(ToolArguments(["app": "Xcode", "title": "Build"])).source
                == .capture(.app("Xcode", titleContains: "Build")))
        #expect(
            try ArgumentParsing.readScreenOCR(ToolArguments(["x": 0, "y": 0, "width": 10, "height": 10])).source
                == .capture(.region(Rect(x: 0, y: 0, width: 10, height: 10))))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(
            try ArgumentParsing.readScreenOCR(ToolArguments(["image_path": "~/shot.png"])).source
                == .image(path: home + "/shot.png"))
    }

    @Test func ocrRejectsMultipleTargets() {
        #expect(throws: ArgumentError.self) {
            try ArgumentParsing.readScreenOCR(ToolArguments(["display": 0, "window_id": 3]))
        }
        #expect(throws: ArgumentError.self) {
            try ArgumentParsing.readScreenOCR(ToolArguments(["image_path": "/a.png", "x": 0, "y": 0, "width": 1, "height": 1]))
        }
    }

    @Test func ocrOptions() throws {
        let request = try ArgumentParsing.readScreenOCR(
            ToolArguments([
                "languages": ["en-US"], "recognition_level": "FAST", "min_confidence": 0.5, "include_image": true,
                "include_boxes": false,
            ]))
        #expect(request.recognizer.languages == ["en-US"])
        #expect(request.recognizer.level == .fast)
        #expect(request.recognizer.minimumConfidence == 0.5)
        #expect(request.includeImage)
        #expect(!request.includeBoxes)
        #expect(throws: ArgumentError.self) { try ArgumentParsing.readScreenOCR(ToolArguments(["recognition_level": "best"])) }
        #expect(throws: ArgumentError.self) { try ArgumentParsing.readScreenOCR(ToolArguments(["min_confidence": 2])) }
    }

    @Test func listWindowsOptions() throws {
        let options = try ArgumentParsing.listWindows(ToolArguments(["app": "Finder", "include_offscreen": true]))
        #expect(options == WindowListOptions(includeOffscreen: true, includeSystemLayers: false, app: "Finder"))
        #expect(try ArgumentParsing.listWindows(ToolArguments(nil)) == WindowListOptions())
    }
}

@Suite struct ToolCatalogTests {
    @Test func advertisesAllTools() {
        #expect(
            Set(ToolCatalog.tools.map(\.name))
                == ["capture_screen", "capture_window", "capture_region", "read_screen_ocr", "list_windows",
                    "annotate_screen", "clear_annotations", "wait_for_user_annotation", "record_action",
                    "get_ui_tree", "diff_screenshots"])
        #expect(ToolCatalog.screenTools.allSatisfy { $0.annotations.readOnlyHint == true })
        #expect(ToolCatalog.resources.map(\.uri) == ["screen://windows/active", "screen://assets/recent"])
    }

    @Test func schemasListEveryParsedArgument() throws {
        // Every property the parser accepts must be in the schema, so clients can discover it.
        let ocr = try #require(ToolCatalog.tools.first { $0.name == "read_screen_ocr" })
        let properties = try #require(ocr.inputSchema.objectValue?["properties"]?.objectValue)
        for key in [
            "display", "window_id", "app", "title", "x", "y", "width", "height", "image_path", "languages",
            "recognition_level", "min_confidence", "include_image", "include_boxes", "max_dimension",
        ] {
            #expect(properties[key] != nil, "missing \(key)")
        }
    }
}

@Suite struct ToolHandlerTests {
    // A bridge folder nothing listens on, so these tests never reach a real Inkpane app.
    let tools = InkpaneTools(
        store: CaptureStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("inkpane-tests")),
        bridge: BridgeClient(location: BridgeLocation(directory: FileManager.default.temporaryDirectory.appendingPathComponent("inkpane-tests-noapp"))))

    @Test func argumentErrorsBecomeToolErrors() async {
        let result = await tools.call(name: "capture_window", arguments: [:])
        #expect(result.isError == true)
    }

    @Test func unknownToolIsAnError() async {
        let result = await tools.call(name: "nope", arguments: nil)
        #expect(result.isError == true)
    }

    @Test func listWindowsReturnsJSON() async throws {
        let result = await tools.call(name: "list_windows", arguments: nil)
        #expect(result.isError == false)
        guard case .text(let text, _, _) = try #require(result.content.first) else {
            Issue.record("expected text content")
            return
        }
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(json?["windows"] is [Any])
        #expect(json?["displays"] is [Any])
        #expect(json?["screen_recording_permission"] is Bool)
    }

    @Test func ocrOnImagePath() async throws {
        // Shares the InkpaneKitTests fixture rather than duplicating it.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("InkpaneKitTests/Fixtures/ocr-sample.png")
        let result = await tools.call(name: "read_screen_ocr", arguments: ["image_path": .string(fixture.path)])
        #expect(result.isError == false)
        guard case .text(let text, _, _) = try #require(result.content.first) else {
            Issue.record("expected text content")
            return
        }
        #expect(text.contains("2026"))
        #expect(result.content.count == 2)
    }

    @Test func activeWindowsResource() async throws {
        let result = try await tools.readResource(uri: "screen://windows/active")
        let content = try #require(result.contents.first)
        #expect(content.mimeType == "application/json")
        #expect(content.text?.contains("\"windows\"") == true)
        await #expect(throws: (any Error).self) { try await tools.readResource(uri: "screen://nope") }
    }
}
