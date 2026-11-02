import Foundation
import MCP
import InkpaneKit

// `get_ui_tree`: a window's accessibility tree. Routed like the other screen reads (see
// `ScreenRouting.swift`): through the Inkpane app when it runs, which applies its exclusion
// list and redaction (or hands back its policy when it lacks Accessibility permission), and
// standalone otherwise.

extension ToolCatalog {
    public static let getUITree = "get_ui_tree"

    static let uiTreeTool = Tool(
        name: getUITree,
        title: "Read a window's UI tree (Accessibility)",
        description: """
            The accessibility tree of a window: each element's role (AXButton, AXTextField, …), \
            subrole, title, label, value, identifier, enabled/focused/selected state and frame in \
            global screen points (\(coordinateNote)). Defaults to the frontmost window; pass \
            window_id, or app (+ title). Use roles and/or text to get a flat list of matching \
            elements (with their ancestor path) instead of the whole tree. The walk is breadth \
            first and bounded by max_depth, max_nodes and time_limit_seconds; the result says \
            which limits were hit. Password fields never return their value. Needs Accessibility \
            permission (for the Inkpane app when it runs, otherwise for the terminal or client \
            that launched this server). \(privacyNote)
            """,
        inputSchema: .object([
            "type": "object",
            "additionalProperties": false,
            "properties": .object([
                "window_id": .object(["type": "integer", "minimum": 1, "description": "Window id from list_windows."]),
                "app": .object(["type": "string", "description": "App name (e.g. \"Safari\") or bundle id; reads its frontmost window."]),
                "title": .object(["type": "string", "description": "With app: only windows whose title contains this text (case-insensitive)."]),
                "max_depth": .object([
                    "type": "integer", "minimum": 0, "maximum": .int(UITreeOptions.maxDepthLimit),
                    "description": .string("Levels below the window to read. Default \(UITreeOptions.defaultMaxDepth)."),
                ]),
                "max_nodes": .object([
                    "type": "integer", "minimum": 1, "maximum": .int(UITreeOptions.maxNodesLimit),
                    "description": .string("Elements to read at most (breadth first). Default \(UITreeOptions.defaultMaxNodes). Raise it to search more of a large window with a filter."),
                ]),
                "max_text_length": .object([
                    "type": "integer", "minimum": 8, "maximum": .int(UITreeOptions.maxTextLengthLimit),
                    "description": .string("Longer titles, labels and values are cut to this many characters. Default \(UITreeOptions.defaultMaxTextLength)."),
                ]),
                "roles": .object([
                    "type": "array", "items": .object(["type": "string"]),
                    "description": "Only elements with one of these roles or subroles, e.g. [\"AXButton\", \"AXTextField\"] (the AX prefix is optional).",
                ]),
                "text": .object(["type": "string", "description": "Only elements whose title, label, value, help, placeholder or identifier contains this text (case-insensitive)."]),
                "time_limit_seconds": .object([
                    "type": "number", "minimum": 0.1, "maximum": .double(UITreeOptions.maxTimeLimit),
                    "description": .string("Stop reading after this long. Default \(Int(UITreeOptions.defaultTimeLimit))."),
                ]),
                "format": .object([
                    "type": "string", "enum": ["json", "outline"],
                    "description": "json (default): nested objects. outline: one indented line per element, much shorter.",
                ]),
            ]),
        ]),
        annotations: Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false))
}

/// How `inkpane-mcp` reads UI trees by itself (standalone, or under the app's policy when the
/// app can't). Injectable so tests never read the real screen.
public struct UITreeReading: Sendable {
    public var read: @Sendable (UITreeTarget, UITreeOptions, CapturePolicy) throws -> UITreeResult

    public init(read: @escaping @Sendable (UITreeTarget, UITreeOptions, CapturePolicy) throws -> UITreeResult) {
        self.read = read
    }

    /// Accessibility through `UITreeReader` (shows the system prompt once when permission is missing).
    public static let live = UITreeReading { target, options, policy in
        try UITreeReader(policy: policy).read(target, options: options)
    }
}

extension ArgumentParsing {
    public enum UITreeFormat: String, Sendable { case json, outline }

    public struct UITreeRequest: Sendable, Equatable {
        public var target: UITreeTarget
        public var options: UITreeOptions
        public var format: UITreeFormat
    }

    public static func getUITree(_ args: ToolArguments) throws -> UITreeRequest {
        try args.rejectUnknown(allowed: windowKeys + [
            "max_depth", "max_nodes", "max_text_length", "roles", "text", "time_limit_seconds", "format",
        ])
        let target: UITreeTarget
        switch try windowTarget(args) {
        case .window(let id)?: target = .window(id: id)
        case .app(let app, let title)?: target = .app(app, titleContains: title)
        default: target = .frontmost
        }
        func ranged(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
            guard let value = try args.int(key) else { return nil }
            guard range.contains(value) else { throw ArgumentError("\(key) must be between \(range.lowerBound) and \(range.upperBound).") }
            return value
        }
        var options = UITreeOptions(
            maxDepth: try ranged("max_depth", 0...UITreeOptions.maxDepthLimit),
            maxNodes: try ranged("max_nodes", 1...UITreeOptions.maxNodesLimit),
            maxTextLength: try ranged("max_text_length", 8...UITreeOptions.maxTextLengthLimit),
            roles: try args.stringArray("roles"), text: try args.string("text"))
        if let limit = try args.double("time_limit_seconds") {
            guard limit >= 0.1, limit <= UITreeOptions.maxTimeLimit else {
                throw ArgumentError("time_limit_seconds must be between 0.1 and \(Int(UITreeOptions.maxTimeLimit)).")
            }
            options.timeLimit = limit
        }
        var format = UITreeFormat.json
        if let name = try args.string("format") {
            guard let parsed = UITreeFormat(rawValue: name.lowercased()) else { throw ArgumentError("format must be json or outline.") }
            format = parsed
        }
        return UITreeRequest(target: target, options: options, format: format)
    }
}

extension InkpaneTools {
    struct UITreeMetadata: Encodable {
        var window: WindowInfo
        var nodeCount: Int
        var truncated: Bool
        var limitsHit: [String]?
        var secureFields: Int?
        var privacy: PrivacyReport?
        var note: String?
        var root: UINode?
        var matches: [UINode]?
    }

    func getUITree(_ request: ArgumentParsing.UITreeRequest) async throws -> CallTool.Result {
        let (tree, note) = try await obtainUITree(request.target, options: request.options)
        let window = tree.window
        let title = window.title.map { " \"\($0)\"" } ?? ""
        var lines: [String] = []
        if let matches = tree.matches {
            lines.append("\(matches.count) matching element(s) in window \(window.windowID)\(title) of \(window.appName ?? "unknown app") (\(tree.nodeCount) read).")
        } else {
            lines.append("UI tree of window \(window.windowID)\(title) of \(window.appName ?? "unknown app"): \(tree.nodeCount) element(s).")
        }
        if let limits = tree.limitsHit {
            lines.append("Stopped early (\(limits.joined(separator: ", "))): the tree is incomplete; omitted_children counts what wasn't read. Narrow it with roles/text or raise the limits.")
        }
        if tree.secureFields > 0 { lines.append("\(tree.secureFields) password field(s): their values are never returned.") }
        if let privacy = tree.privacy?.summary { lines.append(privacy.replacingOccurrences(of: "blacked out", with: "replaced")) }
        if let note { lines.append(note) }

        var content: [Tool.Content] = [Self.text(lines.joined(separator: "\n"))]
        switch request.format {
        case .json:
            let metadata = UITreeMetadata(
                window: window, nodeCount: tree.nodeCount, truncated: tree.truncated, limitsHit: tree.limitsHit,
                secureFields: tree.secureFields > 0 ? tree.secureFields : nil, privacy: tree.privacy.flatMap { $0.isEmpty ? nil : $0 },
                note: note, root: tree.root, matches: tree.matches)
            content.append(Self.text(JSON.encode(metadata)))
        case .outline:
            content.append(Self.text(UITreeOutline.render(tree)))
        }
        return CallTool.Result(content: content, isError: false)
    }

    /// Reads a UI tree through the app when it is running, else in this process.
    func obtainUITree(_ target: UITreeTarget, options: UITreeOptions) async throws -> (UITreeResult, String?) {
        let result: UITreeBridgeResult
        do {
            result = try await bridge.uiTree(UITreeParams(target: target, options: options, tool: ToolCatalog.getUITree))
        } catch {
            guard let reason = Self.meansNoApp(error) else { throw error }
            guard requirement == .optional else { throw ArgumentError(Self.requiredAppMessage(reason)) }
            return (try await readUITreeLocally(target, options: options, policy: CapturePolicy(exclusions: capturer.exclusions)), nil)
        }
        if let tree = result.tree { return (tree, nil) }
        guard let fallback = result.fallback else { throw BridgeClientError.invalidResponse("ui_tree without a tree or a fallback") }
        do {
            let tree = try await readUITreeLocally(target, options: options, policy: fallback.policy)
            return (tree, "Read by inkpane-mcp under Inkpane's privacy settings, because the app could not: \(fallback.reason)")
        } catch let error as InkpaneError {
            guard case .accessibilityPermissionDenied = error else { throw error }
            throw ArgumentError("\(fallback.reason) \(error.localizedDescription) Either one is enough.")
        }
    }

    func readUITreeLocally(_ target: UITreeTarget, options: UITreeOptions, policy: CapturePolicy) async throws -> UITreeResult {
        let read = uiTreeReading.read
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Swift.Result { try read(target, options, policy) })
            }
        }
    }
}

/// One line per element, indented by depth: much shorter than JSON for large trees.
enum UITreeOutline {
    static func render(_ tree: UITreeResult) -> String {
        var lines: [String] = []
        if let matches = tree.matches {
            for node in matches {
                lines.append(line(node))
                if let path = node.path { lines.append("    in " + path) }
            }
        } else if let root = tree.root {
            func visit(_ node: UINode, depth: Int) {
                lines.append(String(repeating: "  ", count: depth) + line(node))
                for child in node.children ?? [] { visit(child, depth: depth + 1) }
            }
            visit(root, depth: 0)
        }
        return lines.isEmpty ? "(no elements)" : lines.joined(separator: "\n")
    }

    static func line(_ node: UINode) -> String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var parts = [node.subrole.map { "\(node.role)/\($0)" } ?? node.role]
        if let title = node.title { parts.append(quoted(title)) }
        if let label = node.label, label != node.title { parts.append("label=" + quoted(label)) }
        if let value = node.value { parts.append("value=" + quoted(value)) }
        if let placeholder = node.placeholder { parts.append("placeholder=" + quoted(placeholder)) }
        if let identifier = node.identifier { parts.append("id=" + identifier) }
        var flags: [String] = []
        if node.enabled == false { flags.append("disabled") }
        if node.focused == true { flags.append("focused") }
        if node.selected == true { flags.append("selected") }
        if node.secure == true { flags.append("password, value withheld") }
        if !flags.isEmpty { parts.append("[" + flags.joined(separator: ", ") + "]") }
        if let frame = node.frame {
            func n(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v) }
            parts.append("@\(n(frame.x)),\(n(frame.y)) \(n(frame.width))x\(n(frame.height))")
        }
        if let omitted = node.omittedChildren { parts.append("(+\(omitted) not read)") }
        return "- " + parts.joined(separator: " ")
    }
}
