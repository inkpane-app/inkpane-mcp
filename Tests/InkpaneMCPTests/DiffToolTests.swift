import CoreGraphics
import Foundation
import MCP
import InkpaneKit
import Testing
@testable import InkpaneMCP

@Suite(.serialized) struct DiffToolTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sbdiff-\(UUID().uuidString.prefix(8))", isDirectory: true)

    /// A light image with an optional dark rectangle (top-left origin, pixels).
    private static func image(width: Int = 80, height: Int = 40, mark: CGRect? = nil) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let mark {
            context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: mark.minX, y: CGFloat(height) - mark.maxY, width: mark.width, height: mark.height))
        }
        return context.makeImage()!
    }

    private func file(_ name: String, _ image: CGImage) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try ImageUtilities.pngData(image).write(to: url)
        return url.path
    }

    private func tools(_ location: BridgeLocation) -> InkpaneTools {
        InkpaneTools(
            store: CaptureStore(directory: folder.appendingPathComponent("store")), bridge: BridgeClient(location: location, timeout: 5),
            uiTreeReading: FakeUITreeReader().reading)
    }

    private var nowhere: BridgeLocation {
        BridgeLocation(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sbnone-\(UUID().uuidString.prefix(8))"))
    }

    private func texts(_ result: CallTool.Result) -> [String] {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }
    }

    private func hasImage(_ result: CallTool.Result) -> Bool {
        result.content.contains { if case .image = $0 { true } else { false } }
    }

    private func metadata(_ result: CallTool.Result) throws -> [String: Any] {
        let text = try #require(texts(result).first)
        let json = try #require(text.split(separator: "\n").last)
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func comparesTwoFiles() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try file("before.png", Self.image())
        let after = try file("after.png", Self.image(mark: CGRect(x: 10, y: 8, width: 20, height: 10)))
        let result = await tools(nowhere).call(
            name: ToolCatalog.diffScreenshots, arguments: ["before": .string(before), "after": .string(after), "frame": ["x": 100, "y": 200, "width": 40, "height": 20]])
        #expect(result.isError == false)
        #expect(hasImage(result))
        let summary = try #require(texts(result).first)
        #expect(summary.hasPrefix("6.25% of the image changed, in 1 region(s), between before.png and after.png."))
        let json = try metadata(result)
        let regions = try #require(json["regions"] as? [[String: Any]])
        #expect(regions.count == 1)
        #expect(regions[0]["pixel_box"] as? [String: Double] == ["x": 10, "y": 8, "width": 20, "height": 10])
        #expect(regions[0]["screen_box"] as? [String: Double] == ["x": 105, "y": 204, "width": 10, "height": 5])
        let diffPath = try #require(json["diff_path"] as? String)
        #expect(FileManager.default.fileExists(atPath: diffPath))

        let same = await tools(nowhere).call(name: ToolCatalog.diffScreenshots, arguments: ["before": .string(before), "after": .string(before)])
        #expect(texts(same).first?.hasPrefix("No changes") == true)
        #expect(!hasImage(same))
    }

    @Test func mismatchedShapesAreAnError() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try file("a.png", Self.image(width: 80, height: 40))
        let after = try file("b.png", Self.image(width: 80, height: 60))
        let result = await tools(nowhere).call(name: ToolCatalog.diffScreenshots, arguments: ["before": .string(before), "after": .string(after)])
        #expect(result.isError == true)
        #expect(texts(result).first?.contains("different shapes") == true)
    }

    @Test func comparesWithACaptureTakenNowAndAnnotates() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try file("before.png", Self.image())
        let now = try ImageUtilities.pngData(Self.image(mark: CGRect(x: 40, y: 20, width: 20, height: 10))).base64EncodedString()
        let app = try FakeApp { method, _ in
            switch method {
            case "capture":
                FakeApp.success(CaptureResult(capture: BridgeCapturedImage(
                    pngBase64: now, kind: .region, frame: Rect(x: 0, y: 0, width: 40, height: 20), scale: 2, display: nil, window: nil, requestedRegion: nil)))
            default:
                FakeApp.success(AnnotateResult(items: [.init(id: "A1", ttl: 5)]))
            }
        }
        defer { app.stop() }
        let result = await tools(app.location).call(
            name: ToolCatalog.diffScreenshots,
            arguments: ["before": .string(before), "x": 0, "y": 0, "width": 40, "height": 20, "annotate": true, "ttl_seconds": 5])
        #expect(result.isError == false)
        #expect(app.methods == ["capture", "annotate"])
        let json = try metadata(result)
        #expect(json["annotation_ids"] as? [String] == ["A1"])
        #expect((json["note"] as? String)?.contains("same area as the capture taken now") == true)
        let regions = try #require(json["regions"] as? [[String: Any]])
        #expect(regions.first?["screen_box"] as? [String: Double] == ["x": 20, "y": 10, "width": 10, "height": 5])
        let after = try #require(json["after"] as? [String: Any])
        #expect((after["path"] as? String)?.hasPrefix(folder.path) == true, "the new capture is saved for the next comparison")

        let annotate = try BridgeJSON.decoder().decode(AnnotateEnvelope.self, from: app.lines[1]).params
        #expect(annotate.annotations.first?.rect == Rect(x: 20, y: 10, width: 10, height: 5))
        #expect(annotate.ttl == 5)
    }

    @Test func libraryCapturesComeFromTheApp() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = try ImageUtilities.pngData(Self.image()).base64EncodedString()
        let asset = BridgeAsset(id: 7, path: "/tmp/7.png", kind: "image", created: "2026-10-30T10:00:00Z", appName: nil, bundleId: nil,
                                windowTitle: nil, url: nil, pinned: false, pixelWidth: 80, pixelHeight: 40, ocrSnippet: nil)
        let app = try FakeApp { _, _ in FakeApp.success(AssetResult(asset: asset, pngBase64: png)) }
        defer { app.stop() }
        let after = try file("after.png", Self.image())
        let result = await tools(app.location).call(
            name: ToolCatalog.diffScreenshots, arguments: ["before": "screen://assets/7", "after": .string(after), "annotate": true])
        #expect(result.isError == false)
        #expect(texts(result).first?.contains("No changes between screen://assets/7 and after.png") == true)
        #expect(app.methods == ["asset"])

        let offline = await tools(nowhere).call(name: ToolCatalog.diffScreenshots, arguments: ["before": "screen://assets/7", "after": .string(after)])
        #expect(offline.isError == true)
        #expect(texts(offline).first?.contains("need the Inkpane app") == true)
    }

    @Test func annotateWithoutTheAppIsANoteNotAnError() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try file("before.png", Self.image())
        let after = try file("after.png", Self.image(mark: CGRect(x: 0, y: 0, width: 10, height: 10)))
        let result = await tools(nowhere).call(
            name: ToolCatalog.diffScreenshots,
            arguments: ["before": .string(before), "after": .string(after), "annotate": true, "frame": ["x": 0, "y": 0, "width": 80, "height": 40]])
        #expect(result.isError == false)
        #expect((try metadata(result)["note"] as? String)?.contains("needs the Inkpane app") == true)

        let noFrame = await tools(nowhere).call(name: ToolCatalog.diffScreenshots, arguments: ["before": .string(before), "after": .string(after), "annotate": true])
        #expect((try metadata(noFrame)["note"] as? String)?.contains("needs screen coordinates") == true)
    }

    @Test func argumentsAreChecked() {
        func parse(_ args: [String: Value]) throws -> ArgumentParsing.DiffRequest { try ArgumentParsing.diffScreenshots(ToolArguments(args)) }
        #expect(throws: ArgumentError.self) { try parse([:]) }
        #expect(throws: ArgumentError.self) { try parse(["before": "https://example.com/a.png"]) }
        #expect(throws: ArgumentError.self) { try parse(["before": "screen://assets/recent"]) }
        #expect(throws: ArgumentError.self) { try parse(["before": "/a.png", "after": "/b.png", "window_id": 3]) }
        #expect(throws: ArgumentError.self) { try parse(["before": "/a.png", "threshold": 2]) }
        #expect(throws: ArgumentError.self) { try parse(["before": "/a.png", "frame": ["x": 0, "y": 0]]) }
        #expect(throws: ArgumentError.self) { try parse(["before": "/a.png", "display": 0, "app": "Xcode"]) }
        let request = try? parse(["before": "~/a.png"])
        #expect(request?.after == .capture(.display(index: 0)))
        #expect(request?.before == .file(path: (("~/a.png") as NSString).expandingTildeInPath))
        #expect(request?.threshold == ImageDiffOptions.defaultThreshold)
        #expect((try? parse(["before": "screen://assets/12", "app": "Xcode"]))?.after == .capture(.app("Xcode", titleContains: nil)))
    }
}

private struct AnnotateEnvelope: Decodable {
    var params: AnnotateParams
}
