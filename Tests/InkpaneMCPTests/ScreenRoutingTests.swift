import CoreGraphics
import Foundation
import MCP
import InkpaneKit
import Testing
@testable import InkpaneMCP

/// Screen reads with and without the Inkpane app, against a fake app on a temporary socket.
@Suite(.serialized) struct ScreenRoutingTests {
    private func tools(_ location: BridgeLocation, requirement: AppRequirement = .optional) -> InkpaneTools {
        let store = CaptureStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sbstore-\(UUID().uuidString.prefix(8))"))
        let bridge = BridgeClient(location: location, timeout: 5, identity: BridgeClientIdentity(BridgeClientInfo(name: "test-client", version: "1.2")))
        return InkpaneTools(store: store, bridge: bridge, requirement: requirement)
    }

    private func texts(_ result: CallTool.Result) -> [String] {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }
    }

    private func hasImage(_ result: CallTool.Result) -> Bool {
        result.content.contains { if case .image = $0 { true } else { false } }
    }

    private static func window(_ id: UInt32) -> WindowInfo {
        WindowInfo(windowID: id, appName: "Xcode", bundleID: "com.apple.dt.Xcode", pid: 1, title: "Main.swift",
                   frame: Rect(x: 0, y: 0, width: 800, height: 600), layer: 0, isOnScreen: true, zOrder: 0, alpha: 1, displayIndex: 0)
    }

    private static func png(width: Int = 8, height: Int = 4) -> String {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return try! ImageUtilities.pngData(context.makeImage()!).base64EncodedString()
    }

    @Test func listWindowsGoesThroughTheAppAndSaysWhatWasHidden() async throws {
        let app = try FakeApp { method, _ in
            FakeApp.success(ListWindowsResult(screenRecordingPermission: true, displays: [], frontmostWindowId: 9, windows: [Self.window(9)], hiddenCount: 2))
        }
        defer { app.stop() }
        let result = await tools(app.location).call(name: ToolCatalog.listWindows, arguments: [:])
        #expect(result.isError == false)
        let json = try #require(texts(result).first)
        #expect(json.contains("Main.swift"))
        #expect(json.contains("2 window(s) of apps on the user's privacy exclusion list"))
        #expect(app.methods == ["list_windows"])
        let request = try #require(app.lines.first)
        let header = try BridgeJSON.decoder().decode(BridgeRequestHeader.self, from: request)
        #expect(header.client == BridgeClientInfo(name: "test-client", version: "1.2"))
    }

    @Test func captureUsesTheAppsImageAndReportsPrivacy() async throws {
        let app = try FakeApp { _, _ in
            FakeApp.success(CaptureResult(
                capture: BridgeCapturedImage(pngBase64: Self.png(), kind: .display, frame: Rect(x: 0, y: 0, width: 4, height: 2), scale: 2,
                                             display: nil, window: nil, requestedRegion: nil),
                privacy: PrivacyReport(excludedApps: ["Slack"], redactedEmails: 1)))
        }
        defer { app.stop() }
        let tools = tools(app.location)
        let result = await tools.call(name: ToolCatalog.captureScreen, arguments: ["display": 0])
        #expect(result.isError == false)
        #expect(hasImage(result))
        let text = try #require(texts(result).first)
        #expect(text.contains("Privacy: windows of Slack were left out"))
        #expect(text.contains("1 email address(es) blacked out"))
        #expect(text.contains(tools.store.directory.path))

        let params = try BridgeJSON.decoder().decode(Envelope<CaptureParams>.self, from: try #require(app.lines.first)).params
        #expect(params.target == BridgeCaptureTarget(.display(index: 0)))
        #expect(params.tool == ToolCatalog.captureScreen)
        #expect(params.ocr == nil)
    }

    @Test func ocrIsDoneByTheApp() async throws {
        let line = RecognizedText(text: "Hello [email]", confidence: 0.99, normalizedBox: Rect(x: 0, y: 0, width: 1, height: 1),
                                  pixelBox: Rect(x: 0, y: 0, width: 8, height: 4), screenBox: Rect(x: 10, y: 10, width: 4, height: 2))
        let app = try FakeApp { _, _ in
            FakeApp.success(CaptureResult(
                capture: BridgeCapturedImage(pngBase64: Self.png(), kind: .region, frame: Rect(x: 10, y: 10, width: 4, height: 2), scale: 2,
                                             display: nil, window: nil, requestedRegion: nil),
                ocr: OCRResult(imageWidth: 8, imageHeight: 4, languages: ["en-US"], lines: [line])))
        }
        defer { app.stop() }
        let result = await tools(app.location).call(name: ToolCatalog.readScreenOCR, arguments: ["x": 10, "y": 10, "width": 4, "height": 2, "languages": ["en-US"]])
        #expect(result.isError == false)
        #expect(texts(result).first?.contains("Hello [email]") == true)
        #expect(!hasImage(result))
        let params = try BridgeJSON.decoder().decode(Envelope<CaptureParams>.self, from: try #require(app.lines.first)).params
        #expect(params.ocr?.languages == ["en-US"])
        #expect(params.target.kind == .region)
    }

    @Test(arguments: [BridgeErrorPayload.Code.excluded, .denied, .failed])
    func refusalsFromTheAppAreFinal(code: BridgeErrorPayload.Code) async throws {
        let app = try FakeApp { _, _ in FakeApp.failure(code, "Not for agents.") }
        defer { app.stop() }
        let result = await tools(app.location).call(name: ToolCatalog.captureWindow, arguments: ["app": "Messages"])
        #expect(result.isError == true)
        #expect(texts(result).first == "Inkpane: Not for agents.")
        #expect(app.methods == ["capture"], "no second attempt, and no local capture")
    }

    @Test func asksForAuthorizationOnceAndRetries() async throws {
        let calls = Counter()
        let app = try FakeApp { method, _ in
            switch method {
            case "authorize": return FakeApp.success(AuthorizeResult(decision: .allowedOnce))
            default:
                if calls.next() == 0 { return FakeApp.failure(.authorizationRequired, "Ask first.") }
                return FakeApp.success(ListWindowsResult(screenRecordingPermission: false, displays: [], frontmostWindowId: nil, windows: [], hiddenCount: 0))
            }
        }
        defer { app.stop() }
        let result = await tools(app.location).call(name: ToolCatalog.listWindows, arguments: [:])
        #expect(result.isError == false)
        #expect(app.methods == ["list_windows", "authorize", "list_windows"])
        let authorize = try BridgeJSON.decoder().decode(Envelope<AuthorizeParams>.self, from: app.lines[1]).params
        #expect(authorize.tool == ToolCatalog.listWindows)
        #expect(texts(result).first?.contains("Window titles are hidden because the Inkpane app") == true)
    }

    @Test func aDeniedAuthorizationIsAnError() async throws {
        let app = try FakeApp { method, _ in
            method == "authorize" ? FakeApp.success(AuthorizeResult(decision: .denied)) : FakeApp.failure(.authorizationRequired, "Ask first.")
        }
        defer { app.stop() }
        let result = await tools(app.location).call(name: ToolCatalog.captureScreen, arguments: [:])
        #expect(result.isError == true)
        #expect(texts(result).first?.contains("did not allow") == true)
        #expect(app.methods == ["capture", "authorize"])
    }

    @Test func withoutTheAppScreenReadsRunStandaloneUnlessTheAppIsRequired() async throws {
        let nowhere = BridgeLocation(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sbnone-\(UUID().uuidString.prefix(8))"))
        let standalone = await tools(nowhere).call(name: ToolCatalog.listWindows, arguments: [:])
        #expect(standalone.isError == false)

        let required = await tools(nowhere, requirement: .required).call(name: ToolCatalog.listWindows, arguments: [:])
        #expect(required.isError == true)
        #expect(texts(required).first?.contains("--require-app") == true)
        let capture = await tools(nowhere, requirement: .required).call(name: ToolCatalog.captureScreen, arguments: [:])
        #expect(texts(capture).first?.contains("Inkpane app is required") == true)
    }

    @Test func anOlderAppMeansStandalone() async throws {
        let app = try FakeApp { _, _ in FakeApp.failure(.unknownMethod, "Unknown method list_windows.") }
        defer { app.stop() }
        let result = await tools(app.location).call(name: ToolCatalog.listWindows, arguments: [:])
        #expect(result.isError == false)
        #expect(app.methods == ["list_windows"])
    }

    @Test func standaloneExclusionsComeFromTheEnvironment() {
        let tools = InkpaneTools.fromEnvironment([StandaloneExclusions.environmentKey: "com.tinyspeck.slackmacgap, com.apple.MobileSMS", AppRequirement.environmentKey: "1"])
        #expect(tools.capturer.exclusions.bundleIDs == ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS"])
        #expect(tools.requirement == .required)
        #expect(InkpaneTools.fromEnvironment([:]).requirement == .optional)
        #expect(InkpaneTools.fromEnvironment([:]).capturer.exclusions.isEmpty)
    }

    // MARK: Assets

    @Test func assetResourcesComeFromTheApp() async throws {
        let asset = BridgeAsset(id: 5, path: "/tmp/a.png", kind: "image", created: "2026-10-30T10:00:00Z", appName: "Safari",
                                bundleId: "com.apple.Safari", windowTitle: "Docs", url: "https://example.com", keptForever: true,
                                pixelWidth: 8, pixelHeight: 4, ocrSnippet: "Hello")
        let app = try FakeApp { method, _ in
            method == "recent_assets"
                ? FakeApp.success(RecentAssetsResult(assets: [asset], hiddenCount: 1))
                : FakeApp.success(AssetResult(asset: asset, pngBase64: Self.png()))
        }
        defer { app.stop() }
        let tools = tools(app.location)
        let recent = try await tools.readResource(uri: ToolCatalog.recentAssetsURI)
        let json = try #require(recent.contents.first?.text)
        #expect(json.contains(#""window_title":"Docs""#))
        #expect(json.contains(#""kept_forever":true"#))
        #expect(!json.contains("pinned"))
        #expect(json.contains("1 capture(s) of apps on the user's privacy exclusion list"))

        let one = try await tools.readResource(uri: "screen://assets/5")
        #expect(one.contents.first?.mimeType == "image/png")
        #expect(one.contents.first?.blob != nil)
        #expect(one.contents.last?.text?.contains(#""id":5"#) == true)
        #expect(app.methods == ["recent_assets", "asset"])
        let params = try BridgeJSON.decoder().decode(Envelope<AssetParams>.self, from: app.lines[1]).params
        #expect(params.id == 5)

        await #expect(throws: MCPError.self) { try await tools.readResource(uri: "screen://assets/abc") }
    }

    @Test func recentAssetsCarryTheGitProject() async throws {
        let asset = BridgeAsset(id: 6, path: "/tmp/b.png", kind: "image", created: "2026-10-30T10:00:00Z", appName: "Cursor",
                                bundleId: nil, windowTitle: "Main.swift — widgets", url: nil, keptForever: false,
                                pixelWidth: 8, pixelHeight: 4, ocrSnippet: nil, project: "widgets", branch: "feature/login",
                                repo: "https://github.com/acme/widgets.git", repoPath: "/Users/me/code/widgets")
        let app = try FakeApp { _, _ in FakeApp.success(RecentAssetsResult(assets: [asset], hiddenCount: 0)) }
        defer { app.stop() }
        let json = try #require(try await tools(app.location).readResource(uri: ToolCatalog.recentAssetsURI).contents.first?.text)
        #expect(json.contains(#""project":"widgets""#))
        #expect(json.contains(#""branch":"feature/login""#))
        #expect(json.contains(#""repo":"https:"#))
        #expect(json.contains(#""repo_path":"#))
    }

    @Test func bridgeAssetsFromOlderAppsDecodeWithoutTheProject() throws {
        let old = #"{"id":1,"path":"/a.png","kind":"image","created":"2026-01-01T00:00:00Z","pinned":false,"pixel_width":1,"pixel_height":1}"#
        let asset = try BridgeJSON.decoder().decode(BridgeAsset.self, from: Data(old.utf8))
        #expect(asset.project == nil)
        #expect(asset.branch == nil)
        #expect(!asset.keptForever)
        // An older app's `pinned` becomes `kept_forever`.
        let pinned = old.replacingOccurrences(of: #""pinned":false"#, with: #""pinned":true"#)
        #expect(try BridgeJSON.decoder().decode(BridgeAsset.self, from: Data(pinned.utf8)).keptForever)
    }

    @Test func theBridgeStillSendsPinnedForOlderServers() throws {
        let asset = BridgeAsset(id: 1, path: "/a.png", kind: "image", created: "2026-01-01T00:00:00Z", appName: nil, bundleId: nil,
                                windowTitle: nil, url: nil, keptForever: true, pixelWidth: 1, pixelHeight: 1, ocrSnippet: nil)
        let wire = String(decoding: try BridgeJSON.encoder().encode(asset), as: UTF8.self)
        #expect(wire.contains(#""kept_forever":true"#) && wire.contains(#""pinned":true"#))
        #expect(try BridgeJSON.decoder().decode(BridgeAsset.self, from: Data(wire.utf8)) == asset)
    }

    @Test func assetResourcesNeedTheApp() async throws {
        let nowhere = BridgeLocation(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sbnone-\(UUID().uuidString.prefix(8))"))
        do {
            _ = try await tools(nowhere).readResource(uri: ToolCatalog.recentAssetsURI)
            Issue.record("expected an error")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("not running"))
        }
    }

    @Test func catalogListsTheAssetResources() {
        #expect(ToolCatalog.resources.map(\.uri).contains(ToolCatalog.recentAssetsURI))
        #expect(ToolCatalog.resources.map(\.uri).contains(ToolCatalog.activeWindowsURI))
        #expect(ToolCatalog.resourceTemplates.map(\.uriTemplate) == [ToolCatalog.assetURITemplate])
    }
}

private struct Envelope<P: Decodable>: Decodable {
    var params: P
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
