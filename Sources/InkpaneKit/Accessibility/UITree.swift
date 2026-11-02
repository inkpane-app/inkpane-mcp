import Foundation

// The Accessibility (AX) tree of a window, for `get_ui_tree`: roles, labels, values, state and
// frames, so an agent can name a control exactly ("the AXButton with identifier `save`") instead
// of guessing from pixels.
//
// The walk is bounded (depth, node count, time) because every AX read is a call into another
// process. Password fields never return their value, and when redaction is on, email addresses
// and phone numbers in titles, labels and values are replaced like in OCR text.

/// Which window to read.
public enum UITreeTarget: Sendable, Hashable {
    /// The frontmost normal window (Inkpane's own windows are skipped).
    case frontmost
    /// A window by window-server id (see `WindowList`).
    case window(id: UInt32)
    /// The frontmost window of an app, matched by app name or bundle id, optionally narrowed by
    /// a case-insensitive title substring.
    case app(String, titleContains: String?)
}

/// Limits and filters for a UI tree read.
public struct UITreeOptions: Codable, Sendable, Hashable {
    public static let defaultMaxDepth = 15
    public static let maxDepthLimit = 60
    public static let defaultMaxNodes = 500
    public static let maxNodesLimit = 5000
    public static let defaultMaxTextLength = 200
    public static let maxTextLengthLimit = 2000
    public static let defaultTimeLimit: Double = 3
    public static let maxTimeLimit: Double = 15

    /// Levels below the window (the window itself is depth 0).
    public var maxDepth: Int?
    /// Nodes read, at most (breadth first, so the top of the tree is complete).
    public var maxNodes: Int?
    /// Longer titles, labels and values are cut to this many characters.
    public var maxTextLength: Int?
    /// Only return nodes with one of these roles or subroles (`AXButton`, or just `button`).
    public var roles: [String]?
    /// Only return nodes whose title, label, value, help, placeholder or identifier contains
    /// this text (case-insensitive).
    public var text: String?
    /// Seconds to spend walking the tree.
    public var timeLimit: Double?

    public init(
        maxDepth: Int? = nil, maxNodes: Int? = nil, maxTextLength: Int? = nil, roles: [String]? = nil, text: String? = nil,
        timeLimit: Double? = nil
    ) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxTextLength = maxTextLength
        self.roles = roles
        self.text = text
        self.timeLimit = timeLimit
    }

    public var effectiveMaxDepth: Int { min(max(maxDepth ?? Self.defaultMaxDepth, 0), Self.maxDepthLimit) }
    public var effectiveMaxNodes: Int { min(max(maxNodes ?? Self.defaultMaxNodes, 1), Self.maxNodesLimit) }
    public var effectiveMaxTextLength: Int { min(max(maxTextLength ?? Self.defaultMaxTextLength, 8), Self.maxTextLengthLimit) }
    public var effectiveTimeLimit: Double { min(max(timeLimit ?? Self.defaultTimeLimit, 0.1), Self.maxTimeLimit) }

    /// Whether a filter is set, so the result is a flat list of matches instead of a tree.
    public var isFiltered: Bool { !(roles ?? []).isEmpty || !(text ?? "").isEmpty }
}

/// One element of the tree.
public struct UINode: Codable, Sendable, Hashable {
    /// `AXButton`, `AXTextField`, `AXStaticText`, …
    public var role: String
    public var subrole: String?
    public var title: String?
    /// `AXDescription`: the accessibility label, often the only name an icon button has.
    public var label: String?
    /// The value as text (field contents, checkbox state `0`/`1`, slider position, …). Never set
    /// for password fields.
    public var value: String?
    public var help: String?
    public var placeholder: String?
    /// `AXIdentifier`, set by the developer (stable across launches and languages).
    public var identifier: String?
    public var enabled: Bool?
    public var focused: Bool?
    public var selected: Bool?
    /// A password field: its value is withheld.
    public var secure: Bool?
    /// Global screen points (top-left origin of the main display, y down).
    public var frame: Rect?
    public var children: [UINode]?
    /// Children that weren't read because of the depth, node or time limit.
    public var omittedChildren: Int?
    /// In filtered results: the ancestors, e.g. `AXWindow "Settings" > AXGroup > AXTabGroup`.
    public var path: String?

    public init(role: String) {
        self.role = role
    }
}

/// The raw attributes of one element, before limits and redaction.
public struct UIElementAttributes: Sendable, Hashable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var label: String?
    public var value: String?
    public var help: String?
    public var placeholder: String?
    public var identifier: String?
    public var enabled: Bool?
    public var focused: Bool?
    public var selected: Bool?
    public var frame: Rect?

    public init(
        role: String? = nil, subrole: String? = nil, title: String? = nil, label: String? = nil, value: String? = nil,
        help: String? = nil, placeholder: String? = nil, identifier: String? = nil, enabled: Bool? = nil, focused: Bool? = nil,
        selected: Bool? = nil, frame: Rect? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.value = value
        self.help = help
        self.placeholder = placeholder
        self.identifier = identifier
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.frame = frame
    }
}

/// An element of an accessibility tree, abstracted so the walk can be tested without AX.
public protocol UIElement {
    func attributes() -> UIElementAttributes
    func children() -> [any UIElement]
    /// How many children there are, without reading them.
    func childCount() -> Int
}

extension UIElement {
    public func childCount() -> Int { children().count }
}

/// What a read returns: the tree (or the matches of a filter) and what limits and privacy did.
public struct UITreeResult: Codable, Sendable, Hashable {
    /// The window that was read.
    public var window: WindowInfo
    /// The tree, starting at the window. `nil` when a filter was given.
    public var root: UINode?
    /// With a filter: the matching nodes, without children, each with its `path`.
    public var matches: [UINode]?
    /// Nodes read.
    public var nodeCount: Int
    /// Whether a limit stopped the walk before the whole tree was read.
    public var truncated: Bool
    /// The limits that were hit: `max_depth`, `max_nodes`, `time_limit`.
    public var limitsHit: [String]?
    /// Email addresses and phone numbers replaced in text.
    public var privacy: PrivacyReport?
    /// Password fields whose value was withheld.
    public var secureFields: Int

    public init(
        window: WindowInfo, root: UINode? = nil, matches: [UINode]? = nil, nodeCount: Int, truncated: Bool, limitsHit: [String]? = nil,
        privacy: PrivacyReport? = nil, secureFields: Int = 0
    ) {
        self.window = window
        self.root = root
        self.matches = matches
        self.nodeCount = nodeCount
        self.truncated = truncated
        self.limitsHit = limitsHit
        self.privacy = privacy
        self.secureFields = secureFields
    }
}

/// Walks an element tree breadth first under `UITreeOptions` and a redaction policy.
public struct UITreeBuilder {
    public var options: UITreeOptions
    public var redaction: RedactionOptions
    /// When the walk stops; defaults to now + `options.effectiveTimeLimit`.
    public var deadline: Date?
    /// For tests: the clock the deadline is checked against.
    public var now: () -> Date = Date.init

    public init(options: UITreeOptions = .init(), redaction: RedactionOptions = .off, deadline: Date? = nil) {
        self.options = options
        self.redaction = redaction
        self.deadline = deadline
    }

    public static let secureRole = "AXSecureTextField"

    /// Reads `root` (a window) into a result for `window`.
    public func build(_ root: any UIElement, window: WindowInfo) -> UITreeResult {
        let deadline = self.deadline ?? now().addingTimeInterval(options.effectiveTimeLimit)
        let maxDepth = options.effectiveMaxDepth
        let maxNodes = options.effectiveMaxNodes
        let detector = SensitiveTextDetector(redaction)
        var report = PrivacyReport()
        var secureFields = 0
        var limits: [String] = []
        func hit(_ limit: String) { if !limits.contains(limit) { limits.append(limit) } }

        struct Pending { var element: any UIElement; var depth: Int; var parent: Int }
        struct Read { var node: UINode; var parent: Int; var depth: Int; var children: [Int] = [] }
        var queue: [Pending] = [Pending(element: root, depth: 0, parent: -1)]
        var head = 0
        var read: [Read] = []

        while head < queue.count {
            let item = queue[head]
            head += 1
            if read.count >= maxNodes || now() >= deadline {
                hit(read.count >= maxNodes ? "max_nodes" : "time_limit")
                if item.parent >= 0 { read[item.parent].node.omittedChildren = (read[item.parent].node.omittedChildren ?? 0) + 1 }
                continue
            }
            let attributes = item.element.attributes()
            var node = makeNode(attributes, detector: detector, report: &report, secureFields: &secureFields)
            let index = read.count
            if item.depth < maxDepth {
                for child in item.element.children() { queue.append(Pending(element: child, depth: item.depth + 1, parent: index)) }
            } else {
                let count = item.element.childCount()
                if count > 0 {
                    node.omittedChildren = count
                    hit("max_depth")
                }
            }
            read.append(Read(node: node, parent: item.parent, depth: item.depth))
            if item.parent >= 0 { read[item.parent].children.append(index) }
        }

        var result = UITreeResult(
            window: window, nodeCount: read.count, truncated: !limits.isEmpty, limitsHit: limits.isEmpty ? nil : limits,
            privacy: report.isEmpty ? nil : report, secureFields: secureFields)
        guard !read.isEmpty else { return result }

        if options.isFiltered {
            var matches: [UINode] = []
            let links = read.map { (node: $0.node, parent: $0.parent) }
            for index in read.indices where matchesFilter(read[index].node) {
                var node = read[index].node
                node.omittedChildren = nil
                node.path = path(to: read[index].parent, in: links)
                matches.append(node)
            }
            result.matches = matches
        } else {
            func assemble(_ index: Int) -> UINode {
                var node = read[index].node
                let children = read[index].children.map(assemble)
                if !children.isEmpty { node.children = children }
                return node
            }
            result.root = assemble(0)
        }
        return result
    }

    // MARK: Nodes

    private func makeNode(
        _ attributes: UIElementAttributes, detector: SensitiveTextDetector, report: inout PrivacyReport, secureFields: inout Int
    ) -> UINode {
        let limit = options.effectiveMaxTextLength
        func clean(_ text: String?) -> String? {
            guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            if detector.isEnabled {
                let found = detector.matches(in: text)
                if !found.isEmpty {
                    report.redactedEmails += found.filter { $0.kind == .email }.count
                    report.redactedPhoneNumbers += found.filter { $0.kind == .phoneNumber }.count
                    text = detector.redact(text)
                }
            }
            if text.count > limit { text = String(text.prefix(limit)) + "…" }
            return text
        }

        var node = UINode(role: attributes.role ?? "AXUnknown")
        node.subrole = attributes.subrole.flatMap { $0.isEmpty ? nil : $0 }
        let isSecure = node.role == Self.secureRole || node.subrole == Self.secureRole
        node.title = clean(attributes.title)
        node.label = clean(attributes.label)
        node.help = clean(attributes.help)
        node.placeholder = clean(attributes.placeholder)
        node.identifier = clean(attributes.identifier)
        if isSecure {
            // Never returned, whatever the redaction settings say.
            node.secure = true
            secureFields += 1
        } else {
            node.value = clean(attributes.value)
        }
        node.enabled = attributes.enabled
        // Only interesting when true; leaving out `false` keeps the output short.
        node.focused = attributes.focused == true ? true : nil
        node.selected = attributes.selected == true ? true : nil
        node.frame = attributes.frame?.rounded(places: 1)
        return node
    }

    // MARK: Filters

    /// `button` → `axbutton`, `AXButton` → `axbutton`.
    static func normalizedRole(_ role: String) -> String {
        let lowered = role.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("ax") ? lowered : "ax" + lowered
    }

    func matchesFilter(_ node: UINode) -> Bool {
        if let roles = options.roles, !roles.isEmpty {
            let wanted = Set(roles.map(Self.normalizedRole))
            let own = [node.role, node.subrole].compactMap { $0 }.map(Self.normalizedRole)
            guard own.contains(where: wanted.contains) else { return false }
        }
        if let text = options.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            // Matched against the redacted, truncated text: a filter can't probe for hidden data.
            let fields = [node.title, node.label, node.value, node.help, node.placeholder, node.identifier].compactMap { $0 }
            guard fields.contains(where: { $0.localizedCaseInsensitiveContains(text) }) else { return false }
        }
        return true
    }

    private func path(to parent: Int, in nodes: [(node: UINode, parent: Int)]) -> String? {
        var parts: [String] = []
        var index = parent
        while index >= 0 {
            let node = nodes[index].node
            let name = node.title ?? node.label ?? node.identifier
            parts.append(name.map { "\(node.role) \"\($0.count > 40 ? String($0.prefix(40)) + "…" : $0)\"" } ?? node.role)
            index = nodes[index].parent
        }
        return parts.isEmpty ? nil : parts.reversed().joined(separator: " > ")
    }
}

/// Picks the window a `UITreeTarget` means, under the exclusion list.
public enum UITreeWindowResolver {
    /// `windows` should include off-screen windows for `.window(id:)` targets.
    public static func resolve(_ target: UITreeTarget, windows: [WindowInfo], exclusions: CaptureExclusions) throws -> WindowInfo {
        func refuseIfExcluded(_ window: WindowInfo) throws -> WindowInfo {
            guard exclusions.excludes(window) else { return window }
            throw InkpaneError.excludedApp(name: window.appName ?? window.bundleID ?? "This app")
        }
        switch target {
        case .frontmost:
            // Inkpane's own windows (excluded by pid) aren't "the frontmost window" an agent means.
            let candidates = windows.filter { WindowList.isUserFacing($0) && !exclusions.processIDs.contains($0.pid) }
            guard let front = candidates.min(by: { $0.zOrder < $1.zOrder }) else {
                throw InkpaneError.captureFailed("No on-screen window found. Call list_windows to see what is available.")
            }
            return try refuseIfExcluded(front)
        case .window(let id):
            guard let window = windows.first(where: { $0.windowID == id }) else { throw InkpaneError.windowNotFound(id: id) }
            return try refuseIfExcluded(window)
        case .app(let query, let title):
            if exclusions.excludes(bundleID: query) {
                throw InkpaneError.excludedApp(name: DefaultExclusions.name(for: query) ?? query)
            }
            if let known = DefaultExclusions.entries.first(where: { $0.name.lowercased() == query.lowercased() }),
               exclusions.excludes(bundleID: known.bundleID) {
                throw InkpaneError.excludedApp(name: known.name)
            }
            guard let window = WindowList.bestWindow(forApp: query, titleContains: title, in: windows) else {
                throw InkpaneError.appWindowNotFound(app: query, title: title)
            }
            return try refuseIfExcluded(window)
        }
    }
}
