import Darwin
import Foundation

/// The bearer token for `inkpane-mcp --http`: random, created on first use and kept (mode
/// 0600) in `mcp-http.token` next to the bridge's `agent.token`, so client configurations stay
/// valid across restarts. Delete the file to rotate it.
public enum MCPHTTPToken {
    public static let fileName = "mcp-http.token"
    /// The port `inkpane-mcp --http` listens on unless `--port` says otherwise.
    public static let defaultPort: UInt16 = 47823

    /// `http://127.0.0.1:<port>/mcp`.
    public static func endpoint(port: UInt16 = defaultPort) -> String { "http://127.0.0.1:\(port)/mcp" }

    public static func url(in location: BridgeLocation) -> URL {
        location.directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The stored token, if any.
    public static func read(in location: BridgeLocation) -> String? {
        BridgeToken.read(from: url(in: location))
    }

    /// The stored token, creating it (and the folder, mode 0700) when missing. `created` says
    /// whether it is new. A token file readable by others is refused.
    public static func loadOrCreate(in location: BridgeLocation) throws -> (token: String, created: Bool) {
        let file = url(in: location)
        var info = stat()
        if lstat(file.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw BridgeSocketError.system("\(file.path) is not a regular file", EINVAL)
            }
            guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                throw BridgeSocketError.system("\(file.path) must belong to you and have mode 0600 (chmod 600 it, or delete it to make a new token)", EPERM)
            }
            if let token = BridgeToken.read(from: file), token.count >= 32 { return (token, false) }
        }
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let token = BridgeToken.generate()
        try BridgeToken.write(token, to: file)
        return (token, true)
    }
}
