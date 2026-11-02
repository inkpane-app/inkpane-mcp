import Darwin
import Foundation

public enum BridgeSocketError: Error, LocalizedError, Sendable, Equatable {
    /// Nothing is listening: the socket file is missing or refuses connections.
    case notListening(path: String)
    case pathTooLong(path: String)
    /// Another process is already listening on the socket.
    case addressInUse(path: String)
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .notListening(let path): "Nothing is listening on \(path)."
        case .pathTooLong(let path): "The socket path is too long for a Unix socket: \(path)"
        case .addressInUse(let path): "Another process is already listening on \(path)."
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Small POSIX helpers for stream Unix sockets, shared by the client and the app's server.
public enum UnixSocket {
    static func address(for path: String) throws(BridgeSocketError) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw .pathTooLong(path: path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func makeSocket() throws(BridgeSocketError) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system("socket", errno) }
        var on: Int32 = 1
        // Writing to a closed peer returns EPIPE instead of killing the process.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// Connects to a listening socket. Throws `.notListening` when the file is missing or stale.
    public static func connect(path: String) throws(BridgeSocketError) -> Int32 {
        var address = try address(for: path)
        let fd = try makeSocket()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            if [ENOENT, ECONNREFUSED, ENOTSOCK, ENOTDIR].contains(code) { throw .notListening(path: path) }
            throw .system("connect \(path)", code)
        }
        return fd
    }

    /// Binds and listens on `path`, owner-only (0600). A stale socket file left by a crashed
    /// process is replaced; a live one throws `.addressInUse`.
    public static func listen(path: String, backlog: Int32 = 16) throws(BridgeSocketError) -> Int32 {
        var address = try address(for: path)
        if FileManager.default.fileExists(atPath: path) {
            if let probe = try? connect(path: path) {
                close(probe)
                throw .addressInUse(path: path)
            }
            unlink(path)
        }
        let fd = try makeSocket()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw .system("bind \(path)", code)
        }
        // Restrict before listening: nobody can connect until listen() anyway.
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw .system("chmod \(path)", code)
        }
        guard Darwin.listen(fd, backlog) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw .system("listen \(path)", code)
        }
        return fd
    }

    /// The effective user id of the process on the other end of a connected socket.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// Writes all of `data`, retrying on short writes and EINTR.
    public static func writeAll(_ fd: Int32, _ data: Data) throws(BridgeSocketError) {
        var failure: BridgeSocketError?
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = .system("write", errno)
                    return
                }
                remaining -= written
                pointer += written
            }
        }
        if let failure { throw failure }
    }

    public static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}

/// Splits a byte stream into newline-terminated lines.
public struct LineBuffer: Sendable {
    private var buffer = Data()
    public let maxLineBytes: Int

    public init(maxLineBytes: Int = BridgeProtocol.maxMessageBytes) {
        self.maxLineBytes = maxLineBytes
    }

    /// Appends bytes and returns the complete lines they finish (without the newline; empty
    /// lines are skipped). Throws when a line grows past `maxLineBytes`.
    public mutating func append(_ data: Data) throws(BridgeSocketError) -> [Data] {
        // Only the new bytes can contain the next newline (large images arrive in many chunks).
        guard data.contains(0x0A) else {
            buffer.append(data)
            if buffer.count > maxLineBytes {
                buffer.removeAll()
                throw .system("message longer than \(maxLineBytes) bytes", EMSGSIZE)
            }
            return []
        }
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        if buffer.count > maxLineBytes {
            buffer.removeAll()
            throw .system("message longer than \(maxLineBytes) bytes", EMSGSIZE)
        }
        return lines
    }
}
