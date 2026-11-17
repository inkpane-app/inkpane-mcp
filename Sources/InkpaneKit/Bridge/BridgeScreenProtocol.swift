import Foundation
import os

// Bridge methods for client authorization, screen reads (capture, OCR, window lists) and the
// asset library. With the Inkpane app running, `inkpane-mcp` sends screen reads here so
// the app can ask the user before an agent first looks, leave out excluded apps, redact, show
// its "agent is viewing" indicator and keep an audit log. See `BridgeProtocol.swift` for the
// framing.

// MARK: - Client identity

/// Who is asking, as reported by `inkpane-mcp`: the MCP client's `clientInfo` from the MCP
/// `initialize` request. The app adds what it can verify itself (the peer's pid and parent
/// process), so this is a label for the user, not proof of identity.
public struct BridgeClientInfo: Codable, Sendable, Hashable {
    /// MCP `clientInfo.name`, e.g. `claude-code`.
    public var name: String
    public var title: String?
    public var version: String?
    /// The bridge client itself, e.g. `inkpane-mcp 0.9.0`.
    public var via: String?

    public init(name: String, title: String? = nil, version: String? = nil, via: String? = nil) {
        self.name = name
        self.title = title
        self.version = version
        self.via = via
    }
}

/// A thread-safe slot for the client info, filled in once the MCP client has initialized.
public final class BridgeClientIdentity: Sendable {
    private let state = OSAllocatedUnfairLock<BridgeClientInfo?>(initialState: nil)

    public init(_ info: BridgeClientInfo? = nil) {
        state.withLock { $0 = info }
    }

    public var info: BridgeClientInfo? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

// MARK: - authorize

public enum AuthorizationDecision: String, Codable, Sendable, Hashable {
    /// For this client process only (until `inkpane-mcp` exits).
    case allowedOnce = "allowed_once"
    /// Remembered; revocable in Inkpane Settings → Privacy.
    case allowedAlways = "allowed_always"
    case denied

    public var isAllowed: Bool { self != .denied }
}

public struct AuthorizeParams: Codable, Sendable, Equatable {
    /// The tool that needs access, shown in the prompt (e.g. `capture_screen`).
    public var tool: String?
    public init(tool: String? = nil) { self.tool = tool }
}

public struct AuthorizeResult: Codable, Sendable, Equatable {
    public var decision: AuthorizationDecision
    public init(decision: AuthorizationDecision) { self.decision = decision }
}

// MARK: - capture

/// `CaptureTarget` on the wire.
public struct BridgeCaptureTarget: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case display, window, app, region }

    public var kind: Kind
    public var display: Int?
    public var windowId: UInt32?
    public var app: String?
    public var title: String?
    public var rect: Rect?

    public init(_ target: CaptureTarget) {
        switch target {
        case .display(let index): self.init(kind: .display, display: index)
        case .window(let id): self.init(kind: .window, windowId: id)
        case .app(let app, let title): self.init(kind: .app, app: app, title: title)
        case .region(let rect): self.init(kind: .region, rect: rect)
        }
    }

    public init(kind: Kind, display: Int? = nil, windowId: UInt32? = nil, app: String? = nil, title: String? = nil, rect: Rect? = nil) {
        self.kind = kind
        self.display = display
        self.windowId = windowId
        self.app = app
        self.title = title
        self.rect = rect
    }

    public func target() throws(BridgeErrorPayload) -> CaptureTarget {
        switch kind {
        case .display: return .display(index: display ?? 0)
        case .window:
            guard let windowId else { throw BridgeErrorPayload(.invalidRequest, "A window target needs window_id.") }
            return .window(id: windowId)
        case .app:
            guard let app, !app.isEmpty else { throw BridgeErrorPayload(.invalidRequest, "An app target needs app.") }
            return .app(app, titleContains: title)
        case .region:
            guard let rect, rect.width > 0, rect.height > 0, rect.x.isFinite, rect.y.isFinite else {
                throw BridgeErrorPayload(.invalidRequest, "A region target needs a rect with positive width and height.")
            }
            return .region(rect)
        }
    }
}

/// OCR settings for a capture (`TextRecognizer` on the wire).
public struct BridgeOCROptions: Codable, Sendable, Hashable {
    public var languages: [String]?
    public var level: TextRecognizer.Level?
    public var minConfidence: Double?
    public var languageCorrection: Bool?

    public init(_ recognizer: TextRecognizer) {
        languages = recognizer.languages
        level = recognizer.level
        minConfidence = recognizer.minimumConfidence
        languageCorrection = recognizer.usesLanguageCorrection
    }

    public var recognizer: TextRecognizer {
        TextRecognizer(
            languages: languages ?? TextRecognizer.defaultLanguages, level: level ?? .accurate,
            usesLanguageCorrection: languageCorrection ?? true, minimumConfidence: minConfidence ?? 0)
    }
}

public struct CaptureParams: Codable, Sendable, Hashable {
    public var target: BridgeCaptureTarget
    /// Also recognize text (for `read_screen_ocr`).
    public var ocr: BridgeOCROptions?
    /// The MCP tool this is for, for the audit log.
    public var tool: String?

    public init(target: CaptureTarget, ocr: TextRecognizer? = nil, tool: String? = nil) {
        self.target = BridgeCaptureTarget(target)
        self.ocr = ocr.map(BridgeOCROptions.init)
        self.tool = tool
    }
}

/// A `Capture` on the wire: full-resolution PNG plus its geometry.
public struct BridgeCapturedImage: Codable, Sendable, Equatable {
    public var pngBase64: String
    public var kind: Capture.Kind
    public var frame: Rect
    public var scale: Double
    public var display: DisplayInfo?
    public var window: WindowInfo?
    public var requestedRegion: Rect?

    public init(pngBase64: String, kind: Capture.Kind, frame: Rect, scale: Double, display: DisplayInfo?, window: WindowInfo?, requestedRegion: Rect?) {
        self.pngBase64 = pngBase64
        self.kind = kind
        self.frame = frame
        self.scale = scale
        self.display = display
        self.window = window
        self.requestedRegion = requestedRegion
    }

    public init(_ capture: Capture) throws {
        self.init(
            pngBase64: try ImageUtilities.pngData(capture.image).base64EncodedString(), kind: capture.kind,
            frame: capture.frame, scale: capture.scale, display: capture.display, window: capture.window,
            requestedRegion: capture.requestedRegion)
    }

    public func capture(excludedApps: [String] = []) throws -> Capture {
        guard let data = Data(base64Encoded: pngBase64), let image = ImageUtilities.decodeImage(data) else {
            throw BridgeClientError.invalidResponse("capture image is not a valid PNG")
        }
        return Capture(
            image: image, kind: kind, frame: frame, scale: scale, display: display, window: window,
            requestedRegion: requestedRegion, capturedAt: Date(), excludedApps: excludedApps)
    }
}

/// The app could not capture (for example it lacks Screen Recording permission). The caller
/// may capture itself, but only under `policy`.
public struct BridgeCaptureFallback: Codable, Sendable, Equatable {
    public var reason: String
    public var policy: CapturePolicy

    public init(reason: String, policy: CapturePolicy) {
        self.reason = reason
        self.policy = policy
    }
}

public struct CaptureResult: Codable, Sendable, Equatable {
    /// Present unless `fallback` is.
    public var capture: BridgeCapturedImage?
    /// Present when OCR was requested.
    public var ocr: OCRResult?
    public var privacy: PrivacyReport?
    public var fallback: BridgeCaptureFallback?

    public init(capture: BridgeCapturedImage? = nil, ocr: OCRResult? = nil, privacy: PrivacyReport? = nil, fallback: BridgeCaptureFallback? = nil) {
        self.capture = capture
        self.ocr = ocr
        self.privacy = privacy
        self.fallback = fallback
    }
}

// MARK: - list_windows

public struct ListWindowsParams: Codable, Sendable, Hashable {
    public var includeOffscreen: Bool?
    public var includeSystem: Bool?
    public var app: String?
    public var tool: String?

    public init(_ options: WindowListOptions, tool: String? = nil) {
        includeOffscreen = options.includeOffscreen
        includeSystem = options.includeSystemLayers
        app = options.app
        self.tool = tool
    }

    public var options: WindowListOptions {
        WindowListOptions(includeOffscreen: includeOffscreen ?? false, includeSystemLayers: includeSystem ?? false, app: app)
    }
}

public struct ListWindowsResult: Codable, Sendable, Equatable {
    /// Whether the app may read window titles (it has Screen Recording permission).
    public var screenRecordingPermission: Bool
    public var displays: [DisplayInfo]
    public var frontmostWindowId: UInt32?
    public var windows: [WindowInfo]
    /// Windows left out because their app is excluded.
    public var hiddenCount: Int

    public init(screenRecordingPermission: Bool, displays: [DisplayInfo], frontmostWindowId: UInt32?, windows: [WindowInfo], hiddenCount: Int) {
        self.screenRecordingPermission = screenRecordingPermission
        self.displays = displays
        self.frontmostWindowId = frontmostWindowId
        self.windows = windows
        self.hiddenCount = hiddenCount
    }
}

// MARK: - recent_assets / asset

/// One capture in the Inkpane library.
public struct BridgeAsset: Codable, Sendable, Equatable {
    public var id: Int64
    public var path: String
    public var kind: String
    /// ISO 8601.
    public var created: String
    public var appName: String?
    public var bundleId: String?
    public var windowTitle: String?
    public var url: String?
    /// Whether the capture is never cleaned up automatically: it is in a group, or kept forever
    /// (by a rule, or because it was pinned before Inkpane removed pinning). Older apps sent
    /// `pinned` instead, which decodes into this.
    public var keptForever: Bool
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// The start of the recognized text (redacted like everything else agents get).
    public var ocrSnippet: String?
    /// The Git project (or editor folder) the capture was taken in, when the app recorded one
    /// from an editor or terminal window. Added after the first release; older apps omit these.
    public var project: String?
    public var branch: String?
    /// The `origin` remote URL, without credentials.
    public var repo: String?
    /// The repository root on this Mac.
    public var repoPath: String?

    public init(
        id: Int64, path: String, kind: String, created: String, appName: String?, bundleId: String?, windowTitle: String?,
        url: String?, keptForever: Bool, pixelWidth: Int, pixelHeight: Int, ocrSnippet: String?,
        project: String? = nil, branch: String? = nil, repo: String? = nil, repoPath: String? = nil
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.created = created
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.url = url
        self.keptForever = keptForever
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.ocrSnippet = ocrSnippet
        self.project = project
        self.branch = branch
        self.repo = repo
        self.repoPath = repoPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, kind, created, appName, bundleId, windowTitle, url, keptForever, pixelWidth, pixelHeight, ocrSnippet,
             project, branch, repo, repoPath
        /// What `keptForever` was called before; still sent on the bridge for older servers.
        case pinned
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        kind = try c.decode(String.self, forKey: .kind)
        created = try c.decode(String.self, forKey: .created)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        keptForever = try c.decodeIfPresent(Bool.self, forKey: .keptForever)
            ?? c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        pixelWidth = try c.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decode(Int.self, forKey: .pixelHeight)
        ocrSnippet = try c.decodeIfPresent(String.self, forKey: .ocrSnippet)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(kind, forKey: .kind)
        try c.encode(created, forKey: .created)
        try c.encodeIfPresent(appName, forKey: .appName)
        try c.encodeIfPresent(bundleId, forKey: .bundleId)
        try c.encodeIfPresent(windowTitle, forKey: .windowTitle)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encode(keptForever, forKey: .keptForever)
        // Servers from before `kept_forever` require `pinned`; only the bridge sends it, so
        // agents see just `kept_forever`.
        if encoder.userInfo[BridgeJSON.legacyFieldsKey] as? Bool == true { try c.encode(keptForever, forKey: .pinned) }
        try c.encode(pixelWidth, forKey: .pixelWidth)
        try c.encode(pixelHeight, forKey: .pixelHeight)
        try c.encodeIfPresent(ocrSnippet, forKey: .ocrSnippet)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(repo, forKey: .repo)
        try c.encodeIfPresent(repoPath, forKey: .repoPath)
    }
}

public struct RecentAssetsParams: Codable, Sendable, Hashable {
    public static let defaultLimit = 20
    public static let maxLimit = 100
    public var limit: Int?
    public init(limit: Int? = nil) { self.limit = limit }
}

public struct RecentAssetsResult: Codable, Sendable, Equatable {
    public var assets: [BridgeAsset]
    /// Recent assets left out because their app is excluded.
    public var hiddenCount: Int
    public init(assets: [BridgeAsset], hiddenCount: Int) {
        self.assets = assets
        self.hiddenCount = hiddenCount
    }
}

public struct AssetParams: Codable, Sendable, Hashable {
    public var id: Int64
    public init(id: Int64) { self.id = id }
}

public struct AssetResult: Codable, Sendable, Equatable {
    public var asset: BridgeAsset
    public var pngBase64: String
    public var privacy: PrivacyReport?
    public init(asset: BridgeAsset, pngBase64: String, privacy: PrivacyReport? = nil) {
        self.asset = asset
        self.pngBase64 = pngBase64
        self.privacy = privacy
    }
}
