import Foundation
import os
import MCP
@preconcurrency import Network
import InkpaneKit

/// `inkpane-mcp --http`: the same tools, resources and prompts as stdio, over MCP's Streamable
/// HTTP transport, for clients that connect to a URL instead of starting a process.
///
/// Security, because anything on the machine (including web pages in a browser) can try to
/// reach a local port:
/// * The listener binds to 127.0.0.1 only and accepts only local connections.
/// * Every request needs `Authorization: Bearer <token>` (compared in constant time). The token
///   lives in `mcp-http.token` (mode 0600) next to the Inkpane app's `agent.token`.
/// * DNS-rebinding protection: the `Host` header must name the loopback address and this port,
///   and an `Origin` header, when present, must be a loopback origin. No CORS headers are sent,
///   so browsers can't make credentialed cross-origin requests either.
///
/// Each MCP session (`Mcp-Session-Id`) gets its own `Server` and `StatefulHTTPServerTransport`
/// from the Swift SDK; POST responses are Server-Sent Event streams. The optional GET stream
/// for server-initiated messages isn't offered (405), since this server sends none.
public final class MCPHTTPServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = MCPHTTPToken.defaultPort
    public static let path = "/mcp"

    public struct Configuration: Sendable {
        /// 0 picks a free port (see `port` after `start()`).
        public var port: UInt16
        public var token: String
        public var maxSessions: Int
        /// Sessions unused for this long are closed (the client then starts a new one).
        public var idleTimeout: TimeInterval
        public var maxBodyBytes: Int

        public init(port: UInt16 = MCPHTTPServer.defaultPort, token: String, maxSessions: Int = 32, idleTimeout: TimeInterval = 4 * 3600, maxBodyBytes: Int = 8 * 1024 * 1024) {
            self.port = port
            self.token = token
            self.maxSessions = maxSessions
            self.idleTimeout = idleTimeout
            self.maxBodyBytes = maxBodyBytes
        }
    }

    public enum StartError: Error, LocalizedError {
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .failed(let detail): "Could not listen on 127.0.0.1: \(detail)"
            }
        }
    }

    private let configuration: Configuration
    private let tools: InkpaneTools
    private let queue = DispatchQueue(label: "inkpane-mcp.http")
    private let sessions: SessionStore
    private var listener: NWListener?
    private let boundPort = OSAllocatedUnfairLock<UInt16>(initialState: 0)

    public init(configuration: Configuration, tools: InkpaneTools) {
        self.configuration = configuration
        self.tools = tools
        sessions = SessionStore(maxSessions: configuration.maxSessions, idleTimeout: configuration.idleTimeout)
    }

    /// The port the server listens on (after `start()`).
    public var port: UInt16 { boundPort.withLock { $0 } }

    public var url: URL { URL(string: "http://127.0.0.1:\(port)\(Self.path)")! }

    /// Starts listening; returns once the port is bound.
    @discardableResult
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else { throw StartError.failed("invalid port") }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw StartError.failed(error.localizedDescription)
        }
        let maxBody = configuration.maxBodyBytes
        listener.newConnectionHandler = { [self] connection in
            let peer = HTTPConnection(connection, queue: queue, maxBodyBytes: maxBody, onClose: {}) { [self] request in
                await self.respond(to: request)
            }
            peer.start()
        }
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: StartError.failed(error.localizedDescription)) }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: StartError.failed("cancelled")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        queue.sync {
            self.listener = listener
            boundPort.withLock { $0 = bound }
        }
        return bound
    }

    /// Stops listening and closes every session.
    public func stop() async {
        let listener = queue.sync { () -> NWListener? in
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
        await sessions.closeAll()
    }

    // MARK: Requests

    func respond(to request: HTTPRequestHead) async -> HTTPReply {
        if let refusal = Self.refusal(for: request, port: port, token: configuration.token) { return refusal }
        switch request.method {
        case "POST", "DELETE":
            break
        case "GET":
            // No server-initiated messages, so no standalone SSE stream (allowed by the spec).
            return .json(405, "This server does not offer a GET event stream", headers: ["Allow": "POST, DELETE"])
        default:
            return .json(405, "Method not allowed", headers: ["Allow": "POST, DELETE"])
        }

        let sdkRequest = HTTPRequest(method: request.method, headers: request.headers, body: request.body, path: request.path)
        let transport: StatefulHTTPServerTransport
        if let id = request.headers["mcp-session-id"] {
            guard let session = await sessions.session(id) else {
                return .json(404, "Unknown or expired session; send a new initialize request")
            }
            transport = session
        } else {
            guard request.method == "POST", Self.isInitialize(request.body) else {
                return .json(400, "Missing Mcp-Session-Id header (only initialize may be sent without one)")
            }
            guard let created = await sessions.create(tools: tools) else {
                return .json(503, "Too many open sessions")
            }
            transport = created
        }
        let response = await transport.handleRequest(sdkRequest)
        if request.method == "DELETE", response.statusCode == 200, let id = request.headers["mcp-session-id"] {
            await sessions.remove(id)
        }
        return Self.reply(response)
    }

    /// The checks every request must pass before MCP sees it, or `nil`.
    static func refusal(for request: HTTPRequestHead, port: UInt16, token: String) -> HTTPReply? {
        guard request.path == path else { return .json(404, "Not found; the MCP endpoint is \(path)") }
        for name in ["host", "origin", "authorization", "mcp-session-id"] where request.repeated.contains(name) {
            return .json(400, "Repeated \(name) header")
        }
        // DNS rebinding: a page on evil.example resolving to 127.0.0.1 still sends its own Host.
        guard let host = request.headers["host"], allowedHosts(port: port).contains(host.lowercased()) else {
            return .json(421, "Host must be 127.0.0.1:\(port) or localhost:\(port)")
        }
        if let origin = request.headers["origin"], !isLoopbackOrigin(origin) {
            return .json(403, "Origin not allowed")
        }
        guard let authorization = request.headers["authorization"], authorization.count > 7,
              authorization.prefix(7).lowercased() == "bearer ",
              BridgeToken.matches(String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces), token)
        else {
            return .json(401, "Missing or wrong bearer token (see \(MCPHTTPToken.fileName))", headers: ["WWW-Authenticate": "Bearer realm=\"inkpane-mcp\""])
        }
        return nil
    }

    static func allowedHosts(port: UInt16) -> Set<String> {
        ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
    }

    /// `http://127.0.0.1[:port]`, `http://localhost[:port]` or `http://[::1][:port]`.
    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin), components.scheme == "http" || components.scheme == "https",
              let host = components.host?.lowercased(), components.path.isEmpty, components.user == nil
        else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    static func isInitialize(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return object["method"] as? String == "initialize" && object["id"] != nil
    }

    static func reply(_ response: HTTPResponse) -> HTTPReply {
        switch response {
        case .stream(let stream, let headers):
            return .stream(status: 200, headers: headers, body: stream)
        default:
            return .full(status: response.statusCode, headers: response.headers, body: response.bodyData ?? Data())
        }
    }
}

/// Open MCP sessions, each with its own server and transport.
private actor SessionStore {
    struct Session {
        var transport: StatefulHTTPServerTransport
        var server: Server
        var lastUsed: Date
    }

    private let maxSessions: Int
    private let idleTimeout: TimeInterval
    private var sessions: [String: Session] = [:]

    init(maxSessions: Int, idleTimeout: TimeInterval) {
        self.maxSessions = maxSessions
        self.idleTimeout = idleTimeout
    }

    func session(_ id: String) -> StatefulHTTPServerTransport? {
        guard var session = sessions[id] else { return nil }
        session.lastUsed = Date()
        sessions[id] = session
        return session.transport
    }

    /// A new session for an `initialize` request, or `nil` when there are too many.
    func create(tools: InkpaneTools) async -> StatefulHTTPServerTransport? {
        let now = Date()
        for (id, session) in sessions where now.timeIntervalSince(session.lastUsed) > idleTimeout {
            await close(id, session)
        }
        guard sessions.count < maxSessions else { return nil }

        let id = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionID(id: id),
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(),
                AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
                SessionValidator(),
            ]))
        // Each session tells the Inkpane app its own client name, and its id: the app's
        // "Allow Once" is per session, not per process.
        var tools = tools
        let identity = BridgeClientIdentity(session: id)
        tools.bridge.identity = identity
        let server = await InkpaneServer.makeServer(tools: tools)
        do {
            try await server.start(transport: transport) { info, _ in
                identity.info = InkpaneServer.clientInfo(info)
            }
        } catch {
            return nil
        }
        sessions[id] = Session(transport: transport, server: server, lastUsed: now)
        return transport
    }

    func remove(_ id: String) async {
        guard let session = sessions[id] else { return }
        await close(id, session)
    }

    func closeAll() async {
        for (id, session) in sessions { await close(id, session) }
    }

    private func close(_ id: String, _ session: Session) async {
        sessions.removeValue(forKey: id)
        await session.server.stop()
    }
}

/// Hands the transport the session id the store already registered.
private struct FixedSessionID: SessionIDGenerator {
    let id: String
    func generateSessionID() -> String { id }
}

/// Resumes a continuation once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
