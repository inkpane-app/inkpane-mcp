import Darwin
import Foundation

/// Where the Inkpane app listens: a Unix socket plus a per-launch token file, both mode 0600,
/// in the app's Application Support folder:
///
///     ~/Library/Application Support/app.inkpane.Inkpane/agent.sock
///     ~/Library/Application Support/app.inkpane.Inkpane/agent.token
///
/// `INKPANE_APP_DIR` overrides the folder (for tests or a custom build).
public struct BridgeLocation: Sendable, Equatable, CustomStringConvertible {
    /// The app's bundle identifier, which names its Application Support folder.
    public static let appSupportFolderName = "app.inkpane.Inkpane"
    public static let socketFileName = "agent.sock"
    public static let tokenFileName = "agent.token"
    public static let environmentKey = "INKPANE_APP_DIR"

    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var socketURL: URL { directory.appendingPathComponent(Self.socketFileName, isDirectory: false) }
    public var tokenURL: URL { directory.appendingPathComponent(Self.tokenFileName, isDirectory: false) }

    /// `~/Library/Application Support/app.inkpane.Inkpane`.
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
