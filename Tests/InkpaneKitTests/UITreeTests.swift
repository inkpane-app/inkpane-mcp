import Foundation
import Testing
@testable import InkpaneKit

/// An element tree without Accessibility.
struct FakeElement: UIElement {
    var attrs: UIElementAttributes
    var kids: [FakeElement] = []

    init(_ role: String, title: String? = nil, label: String? = nil, value: String? = nil, identifier: String? = nil,
         subrole: String? = nil, enabled: Bool? = true, focused: Bool? = nil, frame: Rect? = nil, _ kids: [FakeElement] = []) {
        attrs = UIElementAttributes(
            role: role, subrole: subrole, title: title, label: label, value: value, identifier: identifier, enabled: enabled, focused: focused,
            frame: frame)
        self.kids = kids
    }

    func attributes() -> UIElementAttributes { attrs }
    func children() -> [any UIElement] { kids }
}

private let window = WindowInfo(
    windowID: 42, appName: "Fixture", bundleID: "dev.example.fixture", pid: 900, title: "Settings",
    frame: Rect(x: 100, y: 50, width: 600, height: 400), layer: 0, isOnScreen: true, zOrder: 0, alpha: 1, displayIndex: 0)

private func settingsWindow() -> FakeElement {
    FakeElement("AXWindow", title: "Settings", frame: Rect(x: 100, y: 50, width: 600, height: 400), [
        FakeElement("AXGroup", [
            FakeElement("AXStaticText", value: "Signed in as ann@example.com", frame: Rect(x: 120, y: 80, width: 300, height: 20)),
            FakeElement("AXTextField", label: "Name", value: "Ann", identifier: "name-field", focused: true,
                        frame: Rect(x: 120, y: 110, width: 200, height: 22.25)),
            FakeElement("AXTextField", label: "Password", value: "hunter2", subrole: "AXSecureTextField", frame: Rect(x: 120, y: 140, width: 200, height: 22)),
            FakeElement("AXStaticText", value: "Call +1 (415) 555-0132"),
        ]),
        FakeElement("AXButton", title: "Save", identifier: "save", enabled: false, frame: Rect(x: 600, y: 400, width: 80, height: 30)),
        FakeElement("AXButton", title: "Cancel", frame: Rect(x: 500, y: 400, width: 80, height: 30)),
    ])
}

@Suite struct UITreeBuilderTests {
    @Test func serializesTheTreeWithStateAndFrames() throws {
        let result = UITreeBuilder().build(settingsWindow(), window: window)
        #expect(result.nodeCount == 8)
        #expect(!result.truncated)
        let root = try #require(result.root)
        #expect(root.role == "AXWindow" && root.title == "Settings")
        #expect(root.children?.map(\.role) == ["AXGroup", "AXButton", "AXButton"])
        let save = try #require(root.children?[1])
        #expect(save.identifier == "save" && save.enabled == false && save.frame == Rect(x: 600, y: 400, width: 80, height: 30))
        let name = try #require(root.children?[0].children?[1])
        #expect(name.label == "Name" && name.value == "Ann" && name.focused == true)
        #expect(name.frame == Rect(x: 120, y: 110, width: 200, height: 22.3), "frames are rounded to 0.1 pt")
        #expect(save.focused == nil, "false flags are left out")

        // snake_case JSON, as agents see it.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = String(decoding: try encoder.encode(result), as: UTF8.self)
        #expect(json.contains("\"node_count\":8"))
        #expect(json.contains("\"window_id\":42"))
    }

    @Test func passwordValuesAreNeverReturned() throws {
        for redaction in [RedactionOptions.off, .all] {
            let result = UITreeBuilder(redaction: redaction).build(settingsWindow(), window: window)
            let field = try #require(result.root?.children?[0].children?[2])
            #expect(field.secure == true)
            #expect(field.value == nil)
            #expect(field.label == "Password", "the label stays")
            #expect(result.secureFields == 1)
            let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            #expect(!json.contains("hunter2"))
        }
        // Not even through a text filter.
        let probe = UITreeBuilder(options: UITreeOptions(text: "hunter2")).build(settingsWindow(), window: window)
        #expect(probe.matches == [])
    }

    @Test func redactsEmailsAndPhoneNumbersWhenAsked() throws {
        let plain = UITreeBuilder().build(settingsWindow(), window: window)
        #expect(plain.root?.children?[0].children?[0].value == "Signed in as ann@example.com")
        #expect(plain.privacy == nil)

        let redacted = UITreeBuilder(redaction: RedactionOptions(emails: true, phoneNumbers: true)).build(settingsWindow(), window: window)
        let group = try #require(redacted.root?.children?[0].children)
        #expect(group[0].value == "Signed in as [email]")
        #expect(group[3].value == "Call [phone]")
        #expect(redacted.privacy == PrivacyReport(redactedEmails: 1, redactedPhoneNumbers: 1))
        // A filter can't find the hidden address either.
        let probe = UITreeBuilder(options: UITreeOptions(text: "ann@example"), redaction: .all).build(settingsWindow(), window: window)
        #expect(probe.matches == [])
    }

    @Test func truncatesLongText() throws {
        let long = String(repeating: "word ", count: 100)
        let tree = FakeElement("AXWindow", [FakeElement("AXStaticText", value: long)])
        let result = UITreeBuilder(options: UITreeOptions(maxTextLength: 20)).build(tree, window: window)
        let value = try #require(result.root?.children?.first?.value)
        #expect(value.count == 21 && value.hasSuffix("…"))
    }

    @Test func depthLimitCountsWhatWasNotRead() throws {
        let result = UITreeBuilder(options: UITreeOptions(maxDepth: 1)).build(settingsWindow(), window: window)
        #expect(result.nodeCount == 4)
        #expect(result.truncated && result.limitsHit == ["max_depth"])
        #expect(result.root?.children?[0].omittedChildren == 4)
        #expect(result.root?.children?[0].children == nil)
    }

    @Test func nodeLimitIsBreadthFirst() throws {
        let result = UITreeBuilder(options: UITreeOptions(maxNodes: 4)).build(settingsWindow(), window: window)
        #expect(result.nodeCount == 4)
        #expect(result.limitsHit == ["max_nodes"])
        // The window and its three children are complete; the group's children aren't.
        #expect(result.root?.children?.map(\.role) == ["AXGroup", "AXButton", "AXButton"])
        #expect(result.root?.children?[0].omittedChildren == 4)
    }

    @Test func timeLimitStopsTheWalk() {
        nonisolated(unsafe) var ticks = 0.0
        var builder = UITreeBuilder(deadline: Date(timeIntervalSince1970: 3))
        builder.now = {
            ticks += 1
            return Date(timeIntervalSince1970: ticks)
        }
        let result = builder.build(settingsWindow(), window: window)
        #expect(result.limitsHit == ["time_limit"])
        #expect(result.nodeCount < 8)
    }

    @Test func roleAndTextFiltersReturnMatchesWithTheirPath() throws {
        let buttons = UITreeBuilder(options: UITreeOptions(roles: ["button"])).build(settingsWindow(), window: window)
        #expect(buttons.root == nil)
        #expect(buttons.matches?.map(\.title) == ["Save", "Cancel"])
        #expect(buttons.matches?.first?.path == "AXWindow \"Settings\"")

        let byText = UITreeBuilder(options: UITreeOptions(text: "NAME")).build(settingsWindow(), window: window)
        #expect(byText.matches?.map(\.identifier) == ["name-field"])
        #expect(byText.matches?.first?.path == "AXWindow \"Settings\" > AXGroup")

        let subrole = UITreeBuilder(options: UITreeOptions(roles: ["AXSecureTextField"])).build(settingsWindow(), window: window)
        #expect(subrole.matches?.count == 1)
        let both = UITreeBuilder(options: UITreeOptions(roles: ["AXButton"], text: "can")).build(settingsWindow(), window: window)
        #expect(both.matches?.map(\.title) == ["Cancel"])
    }

    @Test func optionsAreClamped() {
        let options = UITreeOptions(maxDepth: 1000, maxNodes: 0, maxTextLength: 1, timeLimit: 99)
        #expect(options.effectiveMaxDepth == UITreeOptions.maxDepthLimit)
        #expect(options.effectiveMaxNodes == 1)
        #expect(options.effectiveMaxTextLength == 8)
        #expect(options.effectiveTimeLimit == UITreeOptions.maxTimeLimit)
        #expect(!UITreeOptions(roles: [], text: "").isFiltered)
    }
}

@Suite struct UITreeWindowResolverTests {
    private func window(_ id: UInt32, bundle: String, name: String, pid: Int32 = 500, z: Int) -> WindowInfo {
        WindowInfo(windowID: id, appName: name, bundleID: bundle, pid: pid, title: "\(name) window",
                   frame: Rect(x: 0, y: 0, width: 400, height: 300), layer: 0, isOnScreen: true, zOrder: z, alpha: 1, displayIndex: 0)
    }

    @Test func frontmostSkipsInkpaneButRefusesExcludedApps() throws {
        let windows = [
            window(1, bundle: "app.inkpane.Inkpane", name: "Inkpane", pid: 77, z: 0),
            window(2, bundle: "com.tinyspeck.slackmacgap", name: "Slack", z: 1),
            window(3, bundle: "com.apple.dt.Xcode", name: "Xcode", z: 2),
        ]
        let exclusions = CaptureExclusions(bundleIDs: DefaultExclusions.bundleIDs, processIDs: [77])
        #expect(throws: InkpaneError.excludedApp(name: "Slack")) {
            try UITreeWindowResolver.resolve(.frontmost, windows: windows, exclusions: exclusions)
        }
        #expect(try UITreeWindowResolver.resolve(.frontmost, windows: Array(windows.dropFirst(2)), exclusions: exclusions).windowID == 3)
        #expect(try UITreeWindowResolver.resolve(.frontmost, windows: windows, exclusions: .none).windowID == 1)
    }

    @Test func explicitTargetsOfExcludedAppsAreRefused() throws {
        let windows = [window(2, bundle: "com.1password.1password", name: "1Password", z: 0), window(3, bundle: "com.apple.dt.Xcode", name: "Xcode", z: 1)]
        let exclusions = CaptureExclusions(bundleIDs: DefaultExclusions.bundleIDs)
        for target in [UITreeTarget.window(id: 2), .app("1Password", titleContains: nil), .app("com.1password.1password", titleContains: nil), .app("Messages", titleContains: nil)] {
            #expect(throws: InkpaneError.self, "\(target)") { try UITreeWindowResolver.resolve(target, windows: windows, exclusions: exclusions) }
        }
        #expect(try UITreeWindowResolver.resolve(.app("Xcode", titleContains: nil), windows: windows, exclusions: exclusions).windowID == 3)
        #expect(throws: InkpaneError.windowNotFound(id: 9)) { try UITreeWindowResolver.resolve(.window(id: 9), windows: windows, exclusions: exclusions) }
    }

    @Test func bridgeTargetsRoundTrip() throws {
        for target in [UITreeTarget.frontmost, .window(id: 7), .app("Safari", titleContains: "Docs")] {
            let data = try BridgeJSON.encoder().encode(UITreeParams(target: target, options: UITreeOptions(maxNodes: 9, roles: ["AXButton"])))
            let decoded = try BridgeJSON.decoder().decode(UITreeParams.self, from: data)
            #expect(try decoded.target.target() == target)
            #expect(decoded.options.maxNodes == 9 && decoded.options.roles == ["AXButton"])
        }
        #expect(throws: BridgeErrorPayload.self) { try BridgeUITreeTarget(kind: .app).target() }
    }
}

private extension BridgeUITreeTarget {
    init(kind: Kind) {
        self.init(.frontmost)
        self.kind = kind
    }
}
