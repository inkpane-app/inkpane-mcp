import Foundation
@preconcurrency import Network

// The smallest HTTP/1.1 server `inkpane-mcp --http` needs: one request per connection
// (`Connection: close`), bodies delimited by Content-Length (no chunked uploads), responses
// either a complete body or a stream (Server-Sent Events) that ends when the connection closes.
// The MCP Swift SDK provides the Streamable HTTP *transport* (sessions, SSE framing, JSON-RPC
// routing) but no listener, so this file is the socket side and `MCPHTTPServer` the policy.

/// A parsed request, before any MCP handling.
struct HTTPRequestHead: Sendable {
    var method: String
    /// The path without the query string.
    var path: String
    /// Lowercased names. Repeated headers are joined with ", ".
    var headers: [String: String]
    /// Names that appeared more than once.
    var repeated: Set<String>
    var body: Data
}

/// A response to write. `stream` responses are written chunk by chunk until the stream ends.
enum HTTPReply: Sendable {
    case full(status: Int, headers: [String: String], body: Data)
    case stream(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, any Error>)

    static func json(_ status: Int, _ message: String, headers: [String: String] = [:]) -> HTTPReply {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": message]]
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .full(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: body)
    }
}

enum HTTPParseError: Error, Equatable {
    case headersTooLarge
    case malformed(String)
    case bodyTooLarge
    case unsupportedTransferEncoding
}

/// Incremental request parser.
struct HTTPRequestParser {
    static let maxHeaderBytes = 32 * 1024
    var maxBodyBytes: Int
    private var buffer = Data()
    private var head: (method: String, path: String, headers: [String: String], repeated: Set<String>, length: Int)?

    init(maxBodyBytes: Int) {
        self.maxBodyBytes = maxBodyBytes
    }

    /// Adds bytes; returns the request once it is complete.
    mutating func append(_ data: Data) throws(HTTPParseError) -> HTTPRequestHead? {
        buffer.append(data)
        if head == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.maxHeaderBytes { throw .headersTooLarge }
                return nil
            }
            guard end.lowerBound <= Self.maxHeaderBytes else { throw .headersTooLarge }
            let text = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            buffer = Data(buffer[end.upperBound...])
            head = try Self.parseHead(text, maxBodyBytes: maxBodyBytes)
        }
        guard let head, buffer.count >= head.length else { return nil }
        return HTTPRequestHead(
            method: head.method, path: head.path, headers: head.headers, repeated: head.repeated, body: Data(buffer.prefix(head.length)))
    }

    static func parseHead(_ text: String, maxBodyBytes: Int) throws(HTTPParseError)
        -> (method: String, path: String, headers: [String: String], repeated: Set<String>, length: Int)
    {
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), !requestLine[0].isEmpty,
              requestLine[0].allSatisfy({ $0.isASCII && $0.isUppercase })
        else { throw .malformed("bad request line") }
        var headers: [String: String] = [:]
        var repeated: Set<String> = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed("bad header line") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { throw .malformed("bad header name") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                repeated.insert(name)
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        if headers["transfer-encoding"] != nil { throw .unsupportedTransferEncoding }
        var length = 0
        if let value = headers["content-length"] {
            guard !repeated.contains("content-length"), let parsed = Int(value), parsed >= 0 else { throw .malformed("bad Content-Length") }
            guard parsed <= maxBodyBytes else { throw .bodyTooLarge }
            length = parsed
        }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return (String(requestLine[0]), path, headers, repeated, length)
    }
}

/// One accepted connection: reads a request, asks `handle` for the reply, writes it, closes.
final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handle: @Sendable (HTTPRequestHead) async -> HTTPReply
    private let onClose: @Sendable () -> Void
    // Touched on `queue` only.
    private var parser: HTTPRequestParser
    /// Set once a reply is on its way; later input is ignored.
    private var replying = false
    private var task: Task<Void, Never>?
    private var finished = false

    init(
        _ connection: NWConnection, queue: DispatchQueue, maxBodyBytes: Int, onClose: @escaping @Sendable () -> Void,
        handle: @escaping @Sendable (HTTPRequestHead) async -> HTTPReply
    ) {
        self.connection = connection
        self.queue = queue
        self.handle = handle
        self.onClose = onClose
        parser = HTTPRequestParser(maxBodyBytes: maxBodyBytes)
    }

    /// Call on `queue`. The connection keeps itself alive until it closes.
    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
        // A client that never finishes its request doesn't keep the connection forever.
        queue.asyncAfter(deadline: .now() + 30) { [self] in
            guard !replying, !finished else { return }
            reply(.json(408, "Request timeout"))
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            guard !finished, !replying else { return }
            if let data, !data.isEmpty {
                do throws(HTTPParseError) {
                    if let request = try parser.append(data) {
                        replying = true
                        let handle = self.handle
                        task = Task { [self] in
                            let answer = await handle(request)
                            queue.async { self.write(answer) }
                        }
                        return
                    }
                } catch {
                    reply(Self.reply(for: error))
                    return
                }
            }
            if isComplete || error != nil {
                close()
                return
            }
            receive()
        }
    }

    static func reply(for error: HTTPParseError) -> HTTPReply {
        switch error {
        case .headersTooLarge: .json(431, "Request headers too large")
        case .bodyTooLarge: .json(413, "Request body too large")
        case .unsupportedTransferEncoding: .json(501, "Transfer-Encoding is not supported; send a Content-Length")
        case .malformed(let detail): .json(400, "Malformed request: \(detail)")
        }
    }

    private func reply(_ answer: HTTPReply) {
        replying = true
        write(answer)
    }

    /// On `queue`.
    private func write(_ reply: HTTPReply) {
        guard !finished else { return }
        switch reply {
        case .full(let status, let headers, let body):
            var all = headers
            all["Content-Length"] = String(body.count)
            var data = Self.head(status: status, headers: all)
            data.append(body)
            connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
                close()
            })
        case .stream(let status, let headers, let body):
            connection.send(content: Self.head(status: status, headers: headers), completion: .contentProcessed { _ in })
            let connection = self.connection
            task = Task { [self] in
                do {
                    for try await chunk in body {
                        if Task.isCancelled { break }
                        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                            connection.send(content: chunk, completion: .contentProcessed { _ in done.resume() })
                        }
                    }
                } catch {}
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
                    close()
                })
            }
        }
    }

    /// Safe from any thread.
    private func close() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            task?.cancel()
            task = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            onClose()
        }
    }

    static func head(status: Int, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        var all = headers
        all["Connection"] = "close"
        all["Cache-Control"] = all["Cache-Control"] ?? "no-store"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) {
            // Header values come from this process, but never let one split the response.
            let safe = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            text += "\(name): \(safe)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 421: "Misdirected Request"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status \(status)"
        }
    }
}
