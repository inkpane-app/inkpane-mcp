import Foundation

// `ui_tree`: the accessibility tree of a window, read by the Inkpane app under the user's
// privacy settings (exclusion list, redaction). Like `capture`, an app that can't read it (it
// lacks Accessibility permission) answers with its policy, and the caller reads the tree itself
// under that policy. See `UITree.swift` for the tree itself.

/// `UITreeTarget` on the wire.
public struct BridgeUITreeTarget: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case frontmost, window, app }

    public var kind: Kind
    public var windowId: UInt32?
    public var app: String?
    public var title: String?

    public init(_ target: UITreeTarget) {
        switch target {
        case .frontmost:
            kind = .frontmost
        case .window(let id):
            kind = .window
            windowId = id
        case .app(let app, let title):
            kind = .app
            self.app = app
            self.title = title
        }
    }

    public func target() throws(BridgeErrorPayload) -> UITreeTarget {
        switch kind {
        case .frontmost: return .frontmost
        case .window:
            guard let windowId else { throw BridgeErrorPayload(.invalidRequest, "A window target needs window_id.") }
            return .window(id: windowId)
        case .app:
            guard let app, !app.isEmpty else { throw BridgeErrorPayload(.invalidRequest, "An app target needs app.") }
            return .app(app, titleContains: title)
        }
    }
}

public struct UITreeParams: Codable, Sendable, Hashable {
    public var target: BridgeUITreeTarget
    public var options: UITreeOptions
    /// The MCP tool this is for, for the audit log.
    public var tool: String?

    public init(target: UITreeTarget = .frontmost, options: UITreeOptions = .init(), tool: String? = nil) {
        self.target = BridgeUITreeTarget(target)
        self.options = options
        self.tool = tool
    }
}

public struct UITreeBridgeResult: Codable, Sendable, Equatable {
    /// Present unless `fallback` is.
    public var tree: UITreeResult?
    /// The app can't read accessibility trees; the caller may, under `fallback.policy`.
    public var fallback: BridgeCaptureFallback?

    public init(tree: UITreeResult? = nil, fallback: BridgeCaptureFallback? = nil) {
        self.tree = tree
        self.fallback = fallback
    }
}

extension BridgeClient {
    /// Reads a UI tree through the app (the walk itself is bounded by `options.timeLimit`).
    public func uiTree(_ params: UITreeParams) async throws -> UITreeBridgeResult {
        try await call(
            .uiTree, params, as: UITreeBridgeResult.self, timeout: max(timeout, params.options.effectiveTimeLimit + 20), tool: params.tool)
    }
}
