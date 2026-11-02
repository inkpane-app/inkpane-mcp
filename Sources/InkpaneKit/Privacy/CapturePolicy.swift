import Foundation

/// Apps and windows a capture must leave out.
///
/// Display and region captures filter excluded apps' windows out with ScreenCaptureKit (the
/// content behind them shows instead). Window captures of an excluded app are refused, and
/// window listings omit them.
public struct CaptureExclusions: Codable, Sendable, Hashable {
    /// Bundle identifiers, compared case-insensitively.
    public var bundleIDs: [String]
    /// Processes to leave out regardless of bundle id (e.g. the Inkpane app's own indicator).
    public var processIDs: [Int32]
    /// Windows of excluded processes that are kept anyway (e.g. Inkpane's annotation overlay,
    /// so agents can see their own marks).
    public var exceptWindowIDs: [UInt32]

    // Spelled so that snake_case JSON (`bundle_ids`, …) round-trips.
    private enum CodingKeys: String, CodingKey {
        case bundleIDs = "bundleIds", processIDs = "processIds", exceptWindowIDs = "exceptWindowIds"
    }

    public init(bundleIDs: [String] = [], processIDs: [Int32] = [], exceptWindowIDs: [UInt32] = []) {
        self.bundleIDs = bundleIDs
        self.processIDs = processIDs
        self.exceptWindowIDs = exceptWindowIDs
    }

    public static let none = CaptureExclusions()

    public var isEmpty: Bool { bundleIDs.isEmpty && processIDs.isEmpty }

    /// Whether `bundleID` is on the list (case-insensitive).
    public func excludes(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        let lowered = bundleID.lowercased()
        return bundleIDs.contains { $0.lowercased() == lowered }
    }

    /// Whether a window must not be shown to the agent.
    public func excludes(_ window: WindowInfo) -> Bool {
        if exceptWindowIDs.contains(window.windowID) { return false }
        return processIDs.contains(window.pid) || excludes(bundleID: window.bundleID)
    }

    /// `windows` without the excluded ones.
    public func filter(_ windows: [WindowInfo]) -> [WindowInfo] {
        windows.filter { !excludes($0) }
    }
}

/// What to black out in images (and text) returned to agents.
public struct RedactionOptions: Codable, Sendable, Hashable {
    /// Email addresses found by OCR.
    public var emails: Bool
    /// Phone numbers found by OCR.
    public var phoneNumbers: Bool
    /// Password fields (`AXSecureTextField`), located by the Inkpane app with Accessibility.
    public var secureFields: Bool

    public init(emails: Bool = false, phoneNumbers: Bool = false, secureFields: Bool = false) {
        self.emails = emails
        self.phoneNumbers = phoneNumbers
        self.secureFields = secureFields
    }

    public static let off = RedactionOptions()
    public static let all = RedactionOptions(emails: true, phoneNumbers: true, secureFields: true)

    /// Whether OCR has to run to find something to redact.
    public var needsOCR: Bool { emails || phoneNumbers }
    public var isEnabled: Bool { emails || phoneNumbers || secureFields }
}

/// The privacy rules for one capture: decided by the Inkpane app, applied by whichever
/// process captures (the app, or `inkpane-mcp` when the app can't capture itself).
public struct CapturePolicy: Codable, Sendable, Hashable {
    public var exclusions: CaptureExclusions
    public var redaction: RedactionOptions
    /// Password fields on screen right now, in global points (found by the app; empty when
    /// `redaction.secureFields` is off or Accessibility isn't granted).
    public var secureFieldRects: [Rect]

    public init(exclusions: CaptureExclusions = .none, redaction: RedactionOptions = .off, secureFieldRects: [Rect] = []) {
        self.exclusions = exclusions
        self.redaction = redaction
        self.secureFieldRects = secureFieldRects
    }

    /// No exclusions, no redaction: what standalone `inkpane-mcp` does by default.
    public static let unrestricted = CapturePolicy()
}

/// The bundle identifiers the Inkpane app excludes by default: password managers, banking
/// and finance apps, and messaging apps. Users can edit the list in the app.
public enum DefaultExclusions {
    public struct Entry: Sendable, Hashable {
        public var bundleID: String
        public var name: String
        public var category: Category
    }

    public enum Category: String, Sendable, Hashable, CaseIterable {
        case passwords, finance, messaging
    }

    public static let entries: [Entry] = [
        // Password managers
        Entry(bundleID: "com.1password.1password", name: "1Password", category: .passwords),
        Entry(bundleID: "com.agilebits.onepassword7", name: "1Password 7", category: .passwords),
        Entry(bundleID: "com.bitwarden.desktop", name: "Bitwarden", category: .passwords),
        Entry(bundleID: "com.apple.keychainaccess", name: "Keychain Access", category: .passwords),
        Entry(bundleID: "com.apple.Passwords", name: "Passwords", category: .passwords),
        Entry(bundleID: "com.dashlane.dashlanephonefinal", name: "Dashlane", category: .passwords),
        Entry(bundleID: "com.lastpass.LastPass", name: "LastPass", category: .passwords),
        Entry(bundleID: "in.sinew.Enpass-Desktop", name: "Enpass", category: .passwords),
        Entry(bundleID: "org.keepassxc.keepassxc", name: "KeePassXC", category: .passwords),
        // Banking and finance
        Entry(bundleID: "com.apple.stocks", name: "Stocks", category: .finance),
        Entry(bundleID: "com.moneymoney-app.retail", name: "MoneyMoney", category: .finance),
        Entry(bundleID: "com.ynab.YNAB", name: "YNAB", category: .finance),
        Entry(bundleID: "com.quicken.Quicken", name: "Quicken", category: .finance),
        Entry(bundleID: "com.alipay.mobile.client", name: "Alipay", category: .finance),
        Entry(bundleID: "com.paypal.PPClient", name: "PayPal", category: .finance),
        // Messaging
        Entry(bundleID: "com.apple.MobileSMS", name: "Messages", category: .messaging),
        Entry(bundleID: "com.tencent.xinWeChat", name: "WeChat", category: .messaging),
        Entry(bundleID: "ru.keepcoder.Telegram", name: "Telegram", category: .messaging),
        Entry(bundleID: "org.telegram.desktop", name: "Telegram Desktop", category: .messaging),
        Entry(bundleID: "org.whispersystems.signal-desktop", name: "Signal", category: .messaging),
        Entry(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", category: .messaging),
        Entry(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", category: .messaging),
        Entry(bundleID: "WhatsApp", name: "WhatsApp (legacy)", category: .messaging),
        Entry(bundleID: "com.tencent.qq", name: "QQ", category: .messaging),
    ]

    public static var bundleIDs: [String] { entries.map(\.bundleID) }

    /// A friendly name for a default entry, if `bundleID` is one.
    public static func name(for bundleID: String) -> String? {
        entries.first { $0.bundleID.lowercased() == bundleID.lowercased() }?.name
    }
}
