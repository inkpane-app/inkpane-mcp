import Darwin
import Foundation

/// Where the Inkpane app listens: a Unix socket plus a per-launch token file, both mode 0600,
/// in the app's Application Support folder:
///
///     ~/Library/Application Support/app.inkpane.Inkpane/agent.sock
///     ~/Library/Application Support/app.inkpane.Inkpane/agent.token
///
/// A differently identified build of the app (the `app.inkpane.Inkpane.debug` development
/// build) uses its own folder, and so does the `inkpane-mcp` inside it (see
/// `appSupportFolderName`). `INKPANE_APP_DIR` overrides the folder (for tests or a custom build).
public struct BridgeLocation: Sendable, Equatable, CustomStringConvertible {
    /// The released app's bundle identifier.
    public static let releaseBundleIdentifier = "app.inkpane.Inkpane"

    /// The app's bundle identifier, which names its Application Support folder: the Inkpane
    /// app this code runs in (`Bundle.main`) or ships inside (`inkpane-mcp` in its
    /// `Contents/Helpers`), else the released app's.
    public static var appSupportFolderName: String {
        hostAppBundleIdentifier(bundleURL: Bundle.main.bundleURL, executableURL: Bundle.main.executableURL) ?? releaseBundleIdentifier
    }

    /// The identifier of the Inkpane app at `bundleURL`, or of the app whose `Contents/Helpers`
    /// holds `executableURL`. Only identifiers of the Inkpane family count, so other hosts get
    /// the released app's folder.
    static func hostAppBundleIdentifier(bundleURL: URL, executableURL: URL?) -> String? {
        var appURL: URL? = bundleURL.pathExtension == "app" ? bundleURL : nil
        if appURL == nil, let executable = executableURL?.resolvingSymlinksInPath() {
            let helpers = executable.deletingLastPathComponent()
            let contents = helpers.deletingLastPathComponent()
            let app = contents.deletingLastPathComponent()
            if helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents", app.pathExtension == "app" {
                appURL = app
            }
        }
        guard let appURL, let identifier = Bundle(url: appURL)?.bundleIdentifier,
              identifier == releaseBundleIdentifier || identifier.hasPrefix(releaseBundleIdentifier + ".") else { return nil }
        return identifier
    }

    public static let socketFileName = "agent.sock"
    public static let tokenFileName = "agent.token"
    public static let environmentKey = "INKPANE_APP_DIR"

    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var socketURL: URL { directory.appendingPathComponent(Self.socketFileName, isDirectory: false) }
    public var tokenURL: URL { directory.appendingPathComponent(Self.tokenFileName, isDirectory: false) }

    /// `~/Library/Application Support/<appSupportFolderName>`.
    public static var `default`: BridgeLocation {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BridgeLocation(directory: support.appendingPathComponent(appSupportFolderName, isDirectory: true))
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> BridgeLocation {
        if let dir = environment[environmentKey], !dir.isEmpty {
            return BridgeLocation(directory: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true))
        }
        return .default
    }

    public var description: String { socketURL.path }
}

/// The per-launch shared secret. Anyone who can read the token file (only the same user, given
/// its 0600 mode) may talk to the app.
public enum BridgeToken {
    /// 32 random bytes as lowercase hex.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// Writes the token readable by the owner only, replacing any previous file atomically.
    public static func write(_ token: String, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        unlink(temp.path)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BridgeSocketError.system("open \(temp.path)", errno) }
        let data = Data(token.utf8)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let writeErrno = errno
        close(fd)
        guard written == data.count else {
            unlink(temp.path)
            throw BridgeSocketError.system("write \(temp.path)", writeErrno)
        }
        guard rename(temp.path, url.path) == 0 else {
            let renameErrno = errno
            unlink(temp.path)
            throw BridgeSocketError.system("rename to \(url.path)", renameErrno)
        }
    }

    public static func read(from url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Compares without an early exit, so timing doesn't reveal how much of a guess matched.
    public static func matches(_ candidate: String?, _ expected: String) -> Bool {
        guard let candidate else { return false }
        let a = Array(candidate.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
