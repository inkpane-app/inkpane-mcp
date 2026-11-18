import Foundation

// The wire protocol between `inkpane-mcp` and the Inkpane menu bar app.
//
// Transport: a Unix domain socket (see `BridgeLocation`). Each message is one JSON object on
// one line (newline-delimited JSON, UTF-8, keys in snake_case). A client may send several
// requests on one connection; every response carries the `id` of its request, and responses
// can arrive out of order.
//
//     → {"v":1,"id":"1","token":"…","method":"annotate","params":{"annotations":[…],"ttl":8}}
//     ← {"v":1,"id":"1","ok":true,"result":{"ids":["…"],"items":[…]}}
//     ← {"v":1,"id":"2","ok":false,"error":{"code":"unauthorized","message":"…"}}
//
// `token` is the per-launch secret the app writes next to the socket. Requests without the
// right token are rejected. Geometry is in global screen points (top-left origin of the main
// display, y down), the same space as every other InkpaneKit API.

public enum BridgeProtocol {
    /// Bumped on incompatible changes. The app rejects requests with a newer version.
    public static let version = 1
    /// Upper bound for one message, so a broken peer can't exhaust memory.
    public static let maxMessageBytes = 96 * 1024 * 1024
}

public enum BridgeMethod: String, Codable, Sendable, CaseIterable {
    /// Handshake: returns the app name, version and protocol version. Params: `{}`.
    case hello
    /// Draw agent annotations. Params: `AnnotateParams`; result: `AnnotateResult`.
    case annotate
    /// Remove agent annotations. Params: `ClearParams`; result: `ClearResult`.
    case clear
    /// Ask the user to select a region and wait. Params: `UserAnnotationParams`;
    /// result: `UserAnnotationResult`.
    case waitForUserAnnotation = "wait_for_user_annotation"
    /// Ask the user to let this client in (the app shows a prompt). Params: `AuthorizeParams`;
    /// result: `AuthorizeResult`. Sent after a request failed with `authorization_required`.
    case authorize
    /// Capture the screen, a window or a region, optionally with OCR, under the user's privacy
    /// settings. Params: `CaptureParams`; result: `CaptureResult`.
    case capture
    /// Windows and displays, without excluded apps. Params: `ListWindowsParams`; result:
    /// `ListWindowsResult`.
    case listWindows = "list_windows"
    /// The newest library assets. Params: `RecentAssetsParams`; result: `RecentAssetsResult`.
    case recentAssets = "recent_assets"
    /// One library asset with its image. Params: `AssetParams`; result: `AssetResult`.
    case asset
    /// Start a screen recording. Params: `RecordStartParams`; result: `RecordStartResult`
    /// (see `BridgeRecording.swift`).
    case recordStart = "record_start"
    /// Stop it and get the file. Params: `RecordStopParams`; result: `RecordStopResult`.
    case recordStop = "record_stop"
    /// Whether something is being recorded. Params: `{}`; result: `RecordStatusResult`.
    case recordStatus = "record_status"
    /// The accessibility tree of a window under the user's privacy settings. Params:
    /// `UITreeParams`; result: `UITreeBridgeResult` (see `BridgeUITree.swift`).
    case uiTree = "ui_tree"
    /// Scroll a window or region to the end and stitch it into one long image. Params:
    /// `CaptureScrollingParams`; result: `CaptureScrollingResult` (see `BridgeScrolling.swift`).
    case captureScrolling = "capture_scrolling"
}

// MARK: - Envelopes

public struct BridgeRequest<Params: Codable & Sendable>: Codable, Sendable {
    public var v: Int
    public var id: String
    public var token: String
    public var method: BridgeMethod
    public var params: Params
    /// The MCP client behind this request, shown to the user when the app asks for permission.
    public var client: BridgeClientInfo?

    public init(id: String, token: String, method: BridgeMethod, params: Params, client: BridgeClientInfo? = nil, version: Int = BridgeProtocol.version) {
        self.v = version
        self.id = id
        self.token = token
        self.method = method
        self.params = params
        self.client = client
    }
}

/// The fields every request has, decoded leniently so an error reply can still echo the id.
public struct BridgeRequestHeader: Decodable, Sendable {
    public var v: Int?
    public var id: String?
    public var token: String?
    public var method: String?
    public var client: BridgeClientInfo?

    private enum CodingKeys: String, CodingKey { case v, id, token, method, client }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try? container.decodeIfPresent(Int.self, forKey: .v)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        token = try? container.decodeIfPresent(String.self, forKey: .token)
        method = try? container.decodeIfPresent(String.self, forKey: .method)
        client = try? container.decodeIfPresent(BridgeClientInfo.self, forKey: .client)
    }
}

public struct BridgeResponse<Result: Codable & Sendable>: Codable, Sendable {
    public var v: Int
    public var id: String
    public var ok: Bool
    public var result: Result?
    public var error: BridgeErrorPayload?

    public static func success(id: String, _ result: Result) -> Self {
        Self(v: BridgeProtocol.version, id: id, ok: true, result: result, error: nil)
    }
}

/// A response's fields other than `result`.
public struct BridgeResponseHeader: Decodable, Sendable {
    public var v: Int?
    public var id: String?
    public var ok: Bool
    public var error: BridgeErrorPayload?
}

/// An empty result or params object (`{}`).
public struct BridgeEmpty: Codable, Sendable, Equatable {
    public init() {}
}

public struct BridgeErrorPayload: Codable, Sendable, Equatable, Error {
    public enum Code: String, Codable, Sendable {
        case unauthorized
        case unsupportedVersion = "unsupported_version"
        case invalidRequest = "invalid_request"
        case unknownMethod = "unknown_method"
        case failed
        /// This client hasn't been allowed yet: call `authorize`, then retry.
        case authorizationRequired = "authorization_required"
        /// The user denied this client, or the request.
        case denied
        /// The target belongs to an app on the user's exclusion list.
        case excluded
        /// The method needs a paid upgrade of the app that the user doesn't have.
        case proRequired = "pro_required"

        /// Unknown codes from a newer peer decode as `failed`.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Code(rawValue: raw) ?? .failed
        }
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    /// An error response (whose `result` is always absent).
    public func response(id: String) -> BridgeResponse<BridgeEmpty> {
        BridgeResponse(v: BridgeProtocol.version, id: id, ok: false, result: nil, error: self)
    }
}

// MARK: - Shared values

public struct BridgePoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - hello

public struct HelloResult: Codable, Sendable, Equatable {
    public var app: String
    public var appVersion: String
    public var protocolVersion: Int
    public var methods: [String]

    public init(app: String, appVersion: String, protocolVersion: Int = BridgeProtocol.version, methods: [String] = BridgeMethod.allCases.map(\.rawValue)) {
        self.app = app
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.methods = methods
    }
}

// MARK: - annotate

/// One mark an agent draws on the user's screen.
public struct BridgeAnnotation: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A rectangle outline around `rect`.
        case box
        /// An arrow from `from` to `to` (the head is at `to`).
        case arrow
        /// `text` with its top-left corner at `origin`.
        case text
        /// A translucent marker stroke filling `rect`.
        case highlight
        /// Dims the rest of the display(s) `rect` is on, leaving `rect` (or the ellipse in it,
        /// see `shape`) clear. Several spotlights share one dim layer with several holes.
        case spotlight
    }

    /// The shape of a spotlight's clear area.
    public enum SpotlightShape: String, Codable, Sendable, CaseIterable {
        case rectangle, ellipse
    }

    /// How dark a spotlight makes the rest of the screen, when `dimOpacity` is not given.
    public static let defaultDimOpacity = 0.55
    public static let dimOpacityRange: ClosedRange<Double> = 0.1...0.9

    public var kind: Kind
    public var rect: Rect?
    public var from: BridgePoint?
    public var to: BridgePoint?
    public var origin: BridgePoint?
    public var text: String?
    /// A caption drawn next to a box, arrow, highlight or spotlight.
    public var label: String?
    /// `#RRGGBB` or `#RRGGBBAA`.
    public var color: String?
    public var lineWidth: Double?
    public var fontSize: Double?
    /// Seconds before it fades out; `0` keeps it until cleared; `nil` uses the request's `ttl`.
    public var ttl: Double?
    /// Spotlight only: the clear area's shape (default `rectangle`).
    public var shape: SpotlightShape?
    /// Spotlight only: opacity of the dimming, within `dimOpacityRange` (default 0.55).
    public var dimOpacity: Double?

    public init(
        kind: Kind, rect: Rect? = nil, from: BridgePoint? = nil, to: BridgePoint? = nil, origin: BridgePoint? = nil,
        text: String? = nil, label: String? = nil, color: String? = nil, lineWidth: Double? = nil,
        fontSize: Double? = nil, ttl: Double? = nil, shape: SpotlightShape? = nil, dimOpacity: Double? = nil
    ) {
        self.kind = kind
        self.rect = rect
        self.from = from
        self.to = to
        self.origin = origin
        self.text = text
        self.label = label
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.ttl = ttl
        self.shape = shape
        self.dimOpacity = dimOpacity
    }

    public static func box(_ rect: Rect, label: String? = nil, color: String? = nil) -> Self {
        Self(kind: .box, rect: rect, label: label, color: color)
    }

    public static func arrow(from: BridgePoint, to: BridgePoint, label: String? = nil, color: String? = nil) -> Self {
        Self(kind: .arrow, from: from, to: to, label: label, color: color)
    }

    public static func text(_ text: String, at origin: BridgePoint, color: String? = nil) -> Self {
        Self(kind: .text, origin: origin, text: text, color: color)
    }

    public static func highlight(_ rect: Rect, label: String? = nil, color: String? = nil) -> Self {
        Self(kind: .highlight, rect: rect, label: label, color: color)
    }

    public static func spotlight(
        _ rect: Rect, shape: SpotlightShape? = nil, dimOpacity: Double? = nil, label: String? = nil
    ) -> Self {
        Self(kind: .spotlight, rect: rect, label: label, shape: shape, dimOpacity: dimOpacity)
    }

    /// Checks that the fields this kind needs are present and sane.
    public func validate() throws(BridgeErrorPayload) {
        func fail(_ message: String) -> BridgeErrorPayload { BridgeErrorPayload(.invalidRequest, message) }
        func finite(_ values: Double...) -> Bool { values.allSatisfy(\.isFinite) }
        switch kind {
        case .box, .highlight, .spotlight:
            guard let rect else { throw fail("A \(kind.rawValue) needs a rect.") }
            guard finite(rect.x, rect.y, rect.width, rect.height), rect.width > 0, rect.height > 0 else {
                throw fail("A \(kind.rawValue) needs a finite rect with positive width and height.")
            }
        case .arrow:
            guard let from, let to else { throw fail("An arrow needs from and to.") }
            guard finite(from.x, from.y, to.x, to.y) else { throw fail("Arrow points must be finite.") }
            guard hypot(to.x - from.x, to.y - from.y) >= 1 else { throw fail("An arrow's from and to must differ.") }
        case .text:
            guard let origin, finite(origin.x, origin.y) else { throw fail("A text annotation needs an origin.") }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw fail("A text annotation needs non-empty text.")
            }
        }
        if let color, BridgeColor.normalizedHex(color) == nil {
            throw fail("Invalid color \(color); use #RRGGBB, #RRGGBBAA or a name (\(BridgeColor.names.keys.sorted().joined(separator: ", "))).")
        }
        if let lineWidth, !(lineWidth.isFinite && lineWidth > 0 && lineWidth <= 64) {
            throw fail("line_width must be between 0 and 64.")
        }
        if let fontSize, !(fontSize.isFinite && fontSize >= 6 && fontSize <= 200) {
            throw fail("font_size must be between 6 and 200.")
        }
        if let ttl, !AnnotateParams.isValidTTL(ttl) { throw fail(AnnotateParams.ttlError) }
        if kind != .spotlight, shape != nil || dimOpacity != nil {
            throw fail("shape and dim_opacity only apply to a spotlight.")
        }
        if let dimOpacity, !(dimOpacity.isFinite && Self.dimOpacityRange.contains(dimOpacity)) {
            throw fail("dim_opacity must be between \(Self.dimOpacityRange.lowerBound) and \(Self.dimOpacityRange.upperBound).")
        }
    }
}

public struct AnnotateParams: Codable, Sendable, Equatable {
    public static let defaultTTL: Double = 10
    /// The longest a mark may last before it fades (a day); `0` keeps it until cleared.
    public static let maxTTL: Double = 86_400
    public static let maxAnnotations = 100

    static func isValidTTL(_ ttl: Double) -> Bool { ttl.isFinite && ttl >= 0 && ttl <= maxTTL }
    static var ttlError: String { "ttl must be between 0 and \(Int(maxTTL)) seconds (0 keeps marks until cleared)." }

    public var annotations: [BridgeAnnotation]
    /// Default lifetime for annotations without their own `ttl`. `0` keeps them until cleared.
    public var ttl: Double?
    /// Remove the agent's previous annotations first.
    public var replace: Bool?
    /// Pin the marks to this window (an id from `list_windows`). Their coordinates are then
    /// relative to the top-left corner of the window's frame, and they follow the window when
    /// it moves, hide while it is minimized, on another Space or covered, and go when it
    /// closes. The app refuses windows that don't exist or belong to an excluded app.
    public var windowId: UInt32?

    public init(annotations: [BridgeAnnotation], ttl: Double? = nil, replace: Bool? = nil, windowId: UInt32? = nil) {
        self.annotations = annotations
        self.ttl = ttl
        self.replace = replace
        self.windowId = windowId
    }

    public func validate() throws(BridgeErrorPayload) {
        guard !annotations.isEmpty else { throw BridgeErrorPayload(.invalidRequest, "annotations is empty.") }
        guard annotations.count <= Self.maxAnnotations else {
            throw BridgeErrorPayload(.invalidRequest, "At most \(Self.maxAnnotations) annotations per call.")
        }
        if let ttl, !Self.isValidTTL(ttl) { throw BridgeErrorPayload(.invalidRequest, Self.ttlError) }
        if windowId == 0 { throw BridgeErrorPayload(.invalidRequest, "window_id must be a window id from list_windows.") }
        for annotation in annotations { try annotation.validate() }
    }
}

public struct AnnotateResult: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        /// Pass to `clear` to remove it (its label goes with it).
        public var id: String
        /// The separate text annotation drawn for `label`, if any.
        public var labelId: String?
        /// Seconds until it disappears; `nil` when it stays until cleared.
        public var ttl: Double?

        public init(id: String, labelId: String? = nil, ttl: Double? = nil) {
            self.id = id
            self.labelId = labelId
            self.ttl = ttl
        }
    }

    /// The window the marks were pinned to (`window_id`).
    public struct Window: Codable, Sendable, Equatable {
        public var windowId: UInt32
        public var appName: String?
        public var title: String?
        /// Its frame now, in global points. The marks' coordinates are relative to its top-left.
        public var frame: Rect
        /// `false` while it is minimized, hidden or on another Space: the marks show once it is back.
        public var isOnScreen: Bool

        public init(windowId: UInt32, appName: String? = nil, title: String? = nil, frame: Rect, isOnScreen: Bool) {
            self.windowId = windowId
            self.appName = appName
            self.title = title
            self.frame = frame
            self.isOnScreen = isOnScreen
        }
    }

    /// One id per requested annotation, in request order.
    public var ids: [String]
    public var items: [Item]
    /// Set when the marks follow a window.
    public var window: Window?

    public init(items: [Item], window: Window? = nil) {
        self.ids = items.map(\.id)
        self.items = items
        self.window = window
    }
}

// MARK: - clear

public struct ClearParams: Codable, Sendable, Equatable {
    /// Only these annotations (and their labels). `nil` or empty clears every agent annotation.
    public var ids: [String]?
    /// With no ids: also remove the user's own drawings.
    public var includeUser: Bool?

    public init(ids: [String]? = nil, includeUser: Bool? = nil) {
        self.ids = ids
        self.includeUser = includeUser
    }
}

public struct ClearResult: Codable, Sendable, Equatable {
    public var removed: Int
    public init(removed: Int) { self.removed = removed }
}

// MARK: - wait_for_user_annotation

public enum SelectionShape: String, Codable, Sendable, CaseIterable {
    case rectangle
    case freehand
}

public struct UserAnnotationParams: Codable, Sendable, Equatable {
    public static let defaultTimeout: Double = 120
    public static let maxTimeout: Double = 3600

    /// Shown to the user in a banner, e.g. "Circle the broken button".
    public var prompt: String
    /// The tool the user starts with; they can switch in the banner.
    public var shape: SelectionShape?
    /// Seconds to wait before giving up with `timed_out`.
    public var timeout: Double?
    /// Capture the selected region (default true).
    public var includeImage: Bool?
    /// Recognize text in the selected region (default true; needs the image).
    public var includeOcr: Bool?
    /// Vision language codes for OCR, in priority order.
    public var languages: [String]?

    public init(
        prompt: String, shape: SelectionShape? = nil, timeout: Double? = nil, includeImage: Bool? = nil,
        includeOcr: Bool? = nil, languages: [String]? = nil
    ) {
        self.prompt = prompt
        self.shape = shape
        self.timeout = timeout
        self.includeImage = includeImage
        self.includeOcr = includeOcr
        self.languages = languages
    }

    public var effectiveTimeout: Double { timeout ?? Self.defaultTimeout }

    public func validate() throws(BridgeErrorPayload) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeErrorPayload(.invalidRequest, "prompt is empty.")
        }
        guard prompt.count <= 500 else { throw BridgeErrorPayload(.invalidRequest, "prompt is longer than 500 characters.") }
        if let timeout, !(timeout.isFinite && timeout > 0 && timeout <= Self.maxTimeout) {
            throw BridgeErrorPayload(.invalidRequest, "timeout must be between 0 and \(Int(Self.maxTimeout)) seconds.")
        }
    }
}

public struct UserAnnotationResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case selected
        case cancelled
        case timedOut = "timed_out"
    }

    public struct Region: Codable, Sendable, Equatable {
        public var shape: SelectionShape
        /// Bounding box in global screen points.
        public var bbox: Rect
        /// The freehand outline in global screen points (absent for rectangles).
        public var points: [BridgePoint]?
        /// Index into `DisplayInfo.all()` of the display the region is on.
        public var displayIndex: Int?

        public init(shape: SelectionShape, bbox: Rect, points: [BridgePoint]? = nil, displayIndex: Int? = nil) {
            self.shape = shape
            self.bbox = bbox
            self.points = points
            self.displayIndex = displayIndex
        }
    }

    public struct Image: Codable, Sendable, Equatable {
        /// Full-resolution PNG of the region (without Inkpane's own overlay windows).
        public var pngBase64: String
        /// The global frame the image covers: `bbox` clipped to its display.
        public var frame: Rect
        public var scale: Double
        public var pixelWidth: Int
        public var pixelHeight: Int

        public init(pngBase64: String, frame: Rect, scale: Double, pixelWidth: Int, pixelHeight: Int) {
            self.pngBase64 = pngBase64
            self.frame = frame
            self.scale = scale
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    public struct OCRLine: Codable, Sendable, Equatable {
        public var text: String
        public var confidence: Double
        public var screenBox: Rect?

        public init(text: String, confidence: Double, screenBox: Rect?) {
            self.text = text
            self.confidence = confidence
            self.screenBox = screenBox
        }
    }

    public struct OCR: Codable, Sendable, Equatable {
        public var text: String
        public var languages: [String]
        public var lines: [OCRLine]

        public init(text: String, languages: [String], lines: [OCRLine]) {
            self.text = text
            self.languages = languages
            self.lines = lines
        }
    }

    public var status: Status
    /// Why it ended without a selection: `user`, `timeout`, `dismissed`, `superseded` or `disconnected`.
    public var reason: String?
    public var region: Region?
    public var image: Image?
    public var ocr: OCR?
    /// Set when the region was selected but capturing or OCR failed.
    public var captureError: String?
    /// With `captureError`: the privacy rules a caller must apply if it captures the region
    /// itself. Older apps don't send it.
    public var policy: CapturePolicy?
    /// What was left out or blacked out of `image`.
    public var privacy: PrivacyReport?

    public init(
        status: Status, reason: String? = nil, region: Region? = nil, image: Image? = nil, ocr: OCR? = nil,
        captureError: String? = nil, policy: CapturePolicy? = nil, privacy: PrivacyReport? = nil
    ) {
        self.status = status
        self.reason = reason
        self.region = region
        self.image = image
        self.ocr = ocr
        self.captureError = captureError
        self.policy = policy
        self.privacy = privacy
    }
}

// MARK: - Colors

public enum BridgeColor {
    /// Named colours agents may use instead of hex.
    public static let names: [String: String] = [
        "red": "#FF3B30", "orange": "#FF9500", "yellow": "#FFD60A", "green": "#34C759",
        "blue": "#0A84FF", "purple": "#AF52DE", "pink": "#FF2D55", "white": "#FFFFFF", "black": "#000000",
    ]

    /// `#RRGGBB` / `#RRGGBBAA` (any case, `#` optional) or a name → uppercase `#RRGGBB[AA]`.
    public static func normalizedHex(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let named = names[trimmed.lowercased()] { return named }
        var hex = trimmed
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + hex.uppercased()
    }
}

// MARK: - JSON

public enum BridgeJSON {
    /// Set in the bridge encoder's `userInfo`: also write fields that were renamed, for peers
    /// that still expect the old names (`BridgeAsset.pinned`).
    public static let legacyFieldsKey = CodingUserInfoKey(rawValue: "inkpane.legacyFields")!

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.userInfo[legacyFieldsKey] = true
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// Encodes `value` as one protocol line, newline included.
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder().encode(value)
        data.append(0x0A)
        return data
    }
}
