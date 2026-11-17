import Darwin
import Foundation
import Logging
import MCP

/// MCP over stdin/stdout that sleeps in the kernel while no message is coming.
///
/// The SDK's `StdioTransport` (0.12.1, and its `main` as of 2026-11) switches stdin to
/// non-blocking mode and retries `read` every 10 ms when there is nothing to read. An idle
/// `inkpane-mcp` therefore woke about 100 times a second and used ~0.5% of a core per process
/// (0.15–0.2 s of CPU every 30 s), which adds up with several agent sessions open and costs
/// battery. This transport reads on a dedicated thread that blocks in `read(2)` (or in
/// `poll(2)` with no timeout, should another process have made the shared descriptor
/// non-blocking), so an idle server uses no CPU at all.
///
/// Framing is the same as the SDK's: one JSON-RPC message per line, `\n`-delimited.
public actor BlockingStdioTransport: Transport {
    public nonisolated let logger: Logger

    private let input: Int32
    private let output: Int32
    private var isConnected = false
    private let messages: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    public init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, logger: Logger? = nil) {
        self.input = input
        self.output = output
        self.logger = logger ?? Logger(label: "inkpane.transport.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
        (messages, continuation) = AsyncThrowingStream.makeStream()
    }

    public func connect() async throws {
        guard !isConnected else { return }
        isConnected = true
        let input = input, continuation = continuation, logger = logger
        let reader = Thread {
            Self.readLines(from: input, into: continuation, logger: logger)
        }
        reader.name = "inkpane-mcp stdin"
        reader.stackSize = 256 * 1024
        reader.start()
    }

    /// Finishes the message stream. A reader blocked in `read` stays parked until stdin
    /// closes or the process exits; it uses no CPU meanwhile.
    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        guard isConnected else { throw MCPError.transportError(POSIXError(.ENOTCONN)) }
        var line = data
        line.append(0x0A)
        try line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(output, buffer.baseAddress! + offset, buffer.count - offset)
                if written >= 0 {
                    offset += written
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN {
                    Self.wait(for: output, events: Int16(POLLOUT))
                } else {
                    throw MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                }
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> { messages }

    /// Runs on the reader thread until end of file or a read error.
    private static func readLines(
        from fd: Int32, into continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation, logger: Logger
    ) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                pending.append(contentsOf: buffer[..<count])
                var start = pending.startIndex
                while let newline = pending[start...].firstIndex(of: 0x0A) {
                    let message = pending[start..<newline]
                    start = newline + 1
                    if !message.isEmpty { continuation.yield(Data(message)) }
                }
                pending = Data(pending[start...])
            } else if count == 0 {
                logger.notice("EOF received")
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                // Someone else set O_NONBLOCK on the (shared) descriptor: wait without a timeout
                // instead of spinning.
                wait(for: fd, events: Int16(POLLIN))
            } else {
                logger.error("Read error", metadata: ["errno": "\(errno)"])
                break
            }
        }
        continuation.finish()
    }

    /// Blocks until `fd` is ready for `events` (or hangs up / errors, which the next
    /// read or write then reports).
    private static func wait(for fd: Int32, events: Int16) {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while poll(&descriptor, 1, -1) < 0, errno == EINTR {}
    }
}
