import Foundation
import MCP
import InkpaneKit
import Testing
@testable import InkpaneMCP

/// Records what the local reader was asked, and answers with a canned tree (no real AX).
final class FakeUITreeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(target: UITreeTarget, options: UITreeOptions, policy: CapturePolicy)] = []
    var error: (any Error)?

    var requests: [(target: UITreeTarget, options: UITreeOptions, policy: CapturePolicy)] { lock.withLock { calls } }

    var reading: UITreeReading {
        UITreeReading { [self] target, options, policy in
            lock.withLock { calls.append((target, options, policy)) }
            if let error { throw error }
            return UITreeToolTests.sampleTree
        }
    }
}

@Suite(.serialized) struct UITreeToolTests {
    static let window = WindowInfo(
        windowID: 42, appName: "Fixture", bundleID: "dev.example.fixture", pid: 900, title: "Settings",
        frame: Rect(x: 100, y: 50, width: 600, height: 400), layer: 0, isOnScreen: true, zOrder: 0, alpha: 1, displayIndex: 0)

    static var sampleTree: UITreeResult {
        var root = UINode(role: "AXWindow")
        root.title = "Settings"
        var save = UINode(role: "AXButton")
        save.title = "Save"
        save.identifier = "save"
        save.enabled = false
        save.frame = Rect(x: 600, y: 400, width: 80, height: 30)
        var password = UINode(role: "AXTextField")
        password.subrole = "AXSecureTextField"
        password.secure = true
        root.children = [save, password]
        root.omittedChildren = 3
        return UITreeResult(
            window: window, root: root, nodeCount: 3, truncated: true, limitsHit: ["max_nodes"],
            privacy: PrivacyReport(redactedEmails: 2), secureFields: 1)
    }

    private func tools(_ location: BridgeLocation, reader: FakeUITreeReader = FakeUITreeReader(), requirement: AppRequirement = .optional,
                       exclusions: CaptureExclusions = .none) -> InkpaneTools {
        let bridge = BridgeClient(location: location, timeout: 5, identity: BridgeClientIdentity(BridgeClientInfo(name: "test-client")))
        return InkpaneTools(capturer: ScreenCapturer(exclusions: exclusions), bridge: bridge, requirement: requirement, uiTreeReading: reader.reading)
    }

    private var nowhere: BridgeLocation {
        BridgeLocation(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sbnone-\(UUID().uuidString.prefix(8))"))
    }

    private func texts(_ result: CallTool.Result) -> [String] {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }
    }

    @Test func goesThroughTheAppWithTheTargetAndLimits() async throws {
        let app = try FakeApp { _, _ in FakeApp.success(UITreeBridgeResult(tree: Self.sampleTree)) }
        defer { app.stop() }
        let reader = FakeUITreeReader()
        let result = await tools(app.location, reader: reader).call(
            name: ToolCatalog.getUITree, arguments: ["app": "Fixture", "title": "Sett", "max_nodes": 3, "roles": "AXButton, text"])
        #expect(result.isError == false)
        let summary = try #require(texts(result).first)
        #expect(summary.contains("window 42 \"Settings\" of Fixture"))
        #expect(summary.contains("Stopped early (max_nodes)"))
        #expect(summary.contains("1 password field(s)"))
        #expect(summary.contains("2 email address(es) replaced"))
        let json = try #require(texts(result).last)
        #expect(json.contains("\"identifier\":\"save\""))
        #expect(json.contains("\"omitted_children\":3"))
        #expect(reader.requests.isEmpty, "the app read it")

        #expect(app.methods == ["ui_tree"])
        let params = try BridgeJSON.decoder().decode(UITreeEnvelope.self, from: try #require(app.lines.first)).params
        #expect(try params.target.target() == .app("Fixture", titleContains: "Sett"))
        #expect(params.options.maxNodes == 3)
        #expect(params.options.roles == ["AXButton", "text"])
        #expect(params.tool == ToolCatalog.getUITree)
    }

    @Test func outlineIsCompact() async throws {
        let app = try FakeApp { _, _ in FakeApp.success(UITreeBridgeResult(tree: Self.sampleTree)) }
        defer { app.stop() }
        let result = await tools(app.location).call(name: ToolCatalog.getUITree, arguments: ["format": "outline"])
        let outline = try #require(texts(result).last)
        #expect(outline == """
            - AXWindow "Settings" (+3 not read)
              - AXButton "Save" id=save [disabled] @600,400 80x30
              - AXTextField/AXSecureTextField [password, value withheld]
            """)
    }

    @Test func excludedAppsAreRefusedByTheApp() async throws {
        let app = try FakeApp { _, _ in
            FakeApp.failure(.excluded, InkpaneError.excludedApp(name: "1Password").localizedDescription)
        }
        defer { app.stop() }
        let reader = FakeUITreeReader()
        let result = await tools(app.location, reader: reader).call(name: ToolCatalog.getUITree, arguments: ["app": "1Password"])
        #expect(result.isError == true)
        #expect(texts(result).first?.contains("privacy exclusion list") == true)
        #expect(reader.requests.isEmpty, "a refusal is final: no local retry")
    }

    @Test func withoutTheAppItReadsLocallyUnderTheStandaloneExclusions() async throws {
        let reader = FakeUITreeReader()
        let exclusions = CaptureExclusions(bundleIDs: ["com.tinyspeck.slackmacgap"])
        let result = await tools(nowhere, reader: reader, exclusions: exclusions).call(name: ToolCatalog.getUITree, arguments: [:])
        #expect(result.isError == false)
        let request = try #require(reader.requests.first)
        #expect(request.target == .frontmost)
        #expect(request.policy == CapturePolicy(exclusions: exclusions))

        let required = await tools(nowhere, reader: reader, requirement: .required).call(name: ToolCatalog.getUITree, arguments: [:])
        #expect(required.isError == true)
        #expect(texts(required).first?.contains("--require-app") == true)
        #expect(reader.requests.count == 1)
    }

    @Test func appWithoutAccessibilityHandsBackItsPolicy() async throws {
        let policy = CapturePolicy(exclusions: CaptureExclusions(bundleIDs: DefaultExclusions.bundleIDs, processIDs: [77]), redaction: .all)
        let app = try FakeApp { _, _ in
            FakeApp.success(UITreeBridgeResult(fallback: BridgeCaptureFallback(reason: "Inkpane doesn't have Accessibility permission.", policy: policy)))
        }
        defer { app.stop() }
        let reader = FakeUITreeReader()
        let result = await tools(app.location, reader: reader).call(name: ToolCatalog.getUITree, arguments: ["window_id": 42])
        #expect(result.isError == false)
        #expect(reader.requests.first?.policy == policy)
        #expect(reader.requests.first?.target == .window(id: 42))
        #expect(texts(result).first?.contains("under Inkpane's privacy settings") == true)

        reader.error = InkpaneError.accessibilityPermissionDenied(hostApp: HostApp(name: "Terminal", bundlePath: "/System/Applications/Utilities/Terminal.app", bundleID: nil))
        let denied = await tools(app.location, reader: reader).call(name: ToolCatalog.getUITree, arguments: [:])
        #expect(denied.isError == true)
        let message = try #require(texts(denied).first)
        #expect(message.contains("Inkpane doesn't have Accessibility permission") && message.contains("\"Terminal\""))
    }

    @Test func argumentsAreChecked() {
        #expect(throws: ArgumentError.self) { try ArgumentParsing.getUITree(ToolArguments(["max_depth": 99])) }
        #expect(throws: ArgumentError.self) { try ArgumentParsing.getUITree(ToolArguments(["max_nodes": 0])) }
        #expect(throws: ArgumentError.self) { try ArgumentParsing.getUITree(ToolArguments(["time_limit_seconds": 60])) }
        #expect(throws: ArgumentError.self) { try ArgumentParsing.getUITree(ToolArguments(["format": "xml"])) }
        #expect(throws: ArgumentError.self) { try ArgumentParsing.getUITree(ToolArguments(["window_id": 3, "app": "Xcode"])) }
        #expect(throws: ArgumentError.self) { try ArgumentParsing.getUITree(ToolArguments(["display": 0])) }
        let parsed = try? ArgumentParsing.getUITree(ToolArguments(["text": "Save", "time_limit_seconds": 1.5]))
        #expect(parsed?.options == UITreeOptions(text: "Save", timeLimit: 1.5))
        #expect(parsed?.target == .frontmost)
    }

    @Test func accessibilityErrorNamesTheHostApp() {
        let message = InkpaneError.accessibilityPermissionDenied(hostApp: HostApp(name: "iTerm2", bundlePath: "/Applications/iTerm.app", bundleID: nil))
            .localizedDescription
        #expect(message.contains("Enable \"iTerm2\" in System Settings → Privacy & Security → Accessibility"))
    }
}

private struct UITreeEnvelope: Decodable {
    var params: UITreeParams
}
