import CoreGraphics
import Foundation
import MCP
import InkpaneKit
import Testing

@testable import InkpaneMCP

@Suite struct ScrollingArgumentTests {
    func parse(_ args: [String: Value]) throws -> ArgumentParsing.ScrollingRequest {
        try ArgumentParsing.captureScrolling(ToolArguments(args))
    }

    @Test func aWindowAnAppOrARegion() throws {
        #expect(try parse(["window_id": 42]).params.target == BridgeCaptureTarget(.window(id: 42)))
        #expect(try parse(["app": "Safari", "title": "Docs"]).params.target == BridgeCaptureTarget(.app("Safari", titleContains: "Docs")))
        let region = try parse(["x": 10, "y": 20, "width": 400, "height": 300])
        #expect(region.params.target == BridgeCaptureTarget(.region(Rect(x: 10, y: 20, width: 400, height: 300))))
        #expect(region.includeImage)
        #expect(region.params.ocr == nil)
        #expect(region.sliceWidth == 1280 && region.maxSlices == 6)
        #expect(region.params.tool == ToolCatalog.captureScrolling)
    }

    @Test func rejectsMissingOrMixedTargetsAndDisplays() {
        #expect(throws: ArgumentError.self) { try parse([:]) }
        #expect(throws: ArgumentError.self) { try parse(["window_id": 1, "x": 0, "y": 0, "width": 100, "height": 100]) }
        #expect(throws: ArgumentError.self) { try parse(["display": 0]) }
        #expect(throws: ArgumentError.self) { try parse(["x": 0, "y": 0, "width": 10, "height": 10]) }
    }

    @Test func optionsAreChecked() throws {
        let ocr = try parse(["window_id": 1, "include_ocr": true, "languages": ["zh-Hans"]])
        #expect(ocr.params.ocr?.languages == ["zh-Hans"])
        #expect(throws: ArgumentError.self) { try parse(["window_id": 1, "languages": ["en-US"]]) }
        #expect(throws: ArgumentError.self) { try parse(["window_id": 1, "slice_width": 100]) }
        #expect(throws: ArgumentError.self) { try parse(["window_id": 1, "max_slices": 0]) }
        #expect(throws: ArgumentError.self) { try parse(["window_id": 1, "max_height": 40_000]) }
        #expect(throws: ArgumentError.self) { try parse(["window_id": 1, "max_duration_seconds": 1]) }
        let custom = try parse(["window_id": 1, "max_height": 5_000, "max_duration_seconds": 30, "slice_width": 800, "max_slices": 3, "include_image": false])
        #expect(custom.params.maxHeight == 5_000 && custom.params.maxDuration == 30)
        #expect(custom.sliceWidth == 800 && custom.maxSlices == 3 && !custom.includeImage)
    }

    @Test func isAnAppTool() {
        #expect(ToolCatalog.bridgeToolNames.contains(ToolCatalog.captureScrolling))
        #expect(ToolCatalog.tools.contains { $0.name == ToolCatalog.captureScrolling })
    }
}

@Suite struct LongImageSlicingTests {
    @Test func slicesCoverTheImageWithOverlapsAndStayReadable() {
        let slices = LongImageSlicing.slices(width: 2_400, height: 30_000, sliceWidth: 1_280)
        #expect(slices.first?.y == 0)
        #expect(slices.last.map { $0.y + $0.height } == 30_000)
        for (a, b) in zip(slices, slices.dropFirst()) {
            #expect(b.y < a.y + a.height, "slices overlap")
            #expect(a.y + a.height - b.y >= 48)
        }
        #expect(slices.allSatisfy { $0.returnedWidth == 1_280 && $0.returnedHeight <= LongImageSlicing.maxSliceHeight })
        // 2 940 source rows each (1 568 returned), 90 of them shared with the next slice.
        #expect(slices.count == 11)
    }

    @Test func narrowImagesAreNotScaledUp() {
        let slices = LongImageSlicing.slices(width: 800, height: 1_000, sliceWidth: 1_280)
        #expect(slices == [LongImageSlicing.Slice(y: 0, height: 1_000, returnedWidth: 800, returnedHeight: 1_000)])
    }

    @Test func slicePixels() throws {
        let context = CGContext(data: nil, width: 400, height: 4_000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 4_000))
        let image = context.makeImage()!
        let slices = LongImageSlicing.slices(width: 400, height: 4_000, sliceWidth: 200)
        let first = try LongImageSlicing.image(slices[0], of: image)
        #expect(first.width == 200 && first.height == slices[0].returnedHeight)
    }
}

/// `capture_scrolling` against a fake app that writes a long image and returns its path.
@Suite(.serialized) struct ScrollingToolHandlerTests {
    private func longPNG(width: Int, height: Int) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scroll-\(UUID().uuidString).png")
        try ImageUtilities.pngData(context.makeImage()!).write(to: url)
        return url
    }

    @Test func savesTheImageAndReturnsSlices() async throws {
        let source = try longPNG(width: 1_000, height: 6_000)
        let ocr = OCRResult(imageWidth: 1_000, imageHeight: 6_000, languages: ["en-US"], lines: [
            RecognizedText(text: "Top of the page", confidence: 1, normalizedBox: Rect(x: 0, y: 0, width: 0.5, height: 0.01),
                           pixelBox: Rect(x: 0, y: 0, width: 500, height: 60), screenBox: nil),
        ])
        let app = try FakeApp { method, _ in
            #expect(method == "capture_scrolling")
            return try! BridgeJSON.line(BridgeResponse.success(id: "", CaptureScrollingResult(
                path: source.path, frame: Rect(x: 100, y: 100, width: 500, height: 400), scale: 2, pixelWidth: 1_000, pixelHeight: 6_000,
                endedBy: .bottom, ocr: ocr, privacy: PrivacyReport(redactedEmails: 2))))
        }
        defer { app.stop() }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("scroll-out-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let tools = InkpaneTools(store: CaptureStore(directory: output), bridge: BridgeClient(location: app.location))
        let result = await tools.call(name: ToolCatalog.captureScrolling, arguments: [
            "x": 100, "y": 100, "width": 500, "height": 400, "include_ocr": true, "max_slices": 1, "slice_width": 500,
        ])
        #expect(result.isError != true)
        guard case .text(let summary, _, _)? = result.content.first else { Issue.record("no summary"); return }
        #expect(summary.contains("1000×6000 px"))
        #expect(summary.contains("scrolled to the end"))
        #expect(summary.contains("\"redacted_emails\":2"))
        // 3 136 rows a slice at half size: two slices, one returned.
        #expect(summary.contains("first 1 of 2 slices"))
        let images = result.content.filter { if case .image = $0 { true } else { false } }
        #expect(images.count == 1)
        guard case .text(let text, _, _)? = result.content.last else { Issue.record("no text"); return }
        #expect(text.contains("Top of the page"))
        // The app's file was taken over.
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let saved = try FileManager.default.contentsOfDirectory(atPath: output.path)
        #expect(saved.count == 1 && saved[0].contains("scrolling"))
    }

    @Test func explainsAnOldApp() async throws {
        let app = try FakeApp { _, _ in
            try! BridgeJSON.line(BridgeErrorPayload(.unknownMethod, "Unknown method capture_scrolling.").response(id: ""))
        }
        defer { app.stop() }
        let tools = InkpaneTools(bridge: BridgeClient(location: app.location))
        let result = await tools.call(name: ToolCatalog.captureScrolling, arguments: ["window_id": 7])
        #expect(result.isError == true)
        guard case .text(let text, _, _)? = result.content.first else { return }
        #expect(text.contains("too old"))
    }
}
