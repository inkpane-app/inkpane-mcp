import Darwin
import Foundation

public enum BridgeClientError: Error, LocalizedError, Sendable, Equatable {
    /// No Inkpane app is listening at the socket.
    case appNotRunning(socketPath: String)
    /// The token file is missing or unreadable although the socket answers.
    case tokenUnavailable(path: String)
    /// The app answered with an error.
    case remote(BridgeErrorPayload)
    case timedOut(seconds: Double)
    case connectionClosed
    case invalidResponse(String)
    case transport(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .appNotRunning(let path):
            "The Inkpane app is not running (nothing is listening on \(path)). Start the Inkpane menu bar app and try again."
        case .tokenUnavailable(let path):
            "Could not read Inkpane's access token at \(path). Quit and reopen the Inkpane app."
        case .remote(let error):
            "Inkpane: \(error.message)"
        case .timedOut(let seconds):
            "Inkpane did not answer within \(Int(seconds.rounded())) s."
        case .connectionClosed:
            "Inkpane closed the connection before answering (did the app quit?)."
        case .invalidResponse(let detail):
            "Inkpane sent an invalid response: \(detail)"
        case .transport(let detail):
            "Could not talk to the Inkpane app: \(detail)"
        case .cancelled:
            "The request to Inkpane was cancelled."
        }
    }
}

/// Talks to the Inkpane app over its Unix socket. Each call opens its own connection, so
/// long calls (`waitForUserAnnotation`) never block short ones, and closing the connection
/// (for example when the calling task is cancelled) withdraws the request.
public struct BridgeClient: Sendable {
    public var location: BridgeLocation
    /// Time allowed for ordinary calls.
    public var timeout: TimeInterval
    /// Sent with every request so the app can tell the user who is asking.
    public var identity: BridgeClientIdentity
    /// How long to wait for the user to answer the app's permission prompt.
    public var authorizationTimeout: TimeInterval

    public init(
        location: BridgeLocation = .fromEnvironment(), timeout: TimeInterval = 10,
        identity: BridgeClientIdentity = BridgeClientIdentity(), authorizationTimeout: TimeInterval = 130
    ) {
        self.location = location
        self.timeout = timeout
        self.identity = identity
        self.authorizationTimeout = authorizationTimeout
    }

    // MARK: Methods

    public func hello() async throws -> HelloResult {
        try await call(.hello, BridgeEmpty(), as: HelloResult.self)
    }

    public func annotate(_ params: AnnotateParams) async throws -> AnnotateResult {
        try await call(.annotate, params, as: AnnotateResult.self)
    }

    public func clear(_ params: ClearParams = ClearParams()) async throws -> ClearResult {
        try await call(.clear, params, as: ClearResult.self)
    }

    /// Waits up to the request's timeout (plus a grace period for capture and OCR).
    public func waitForUserAnnotation(_ params: UserAnnotationParams) async throws -> UserAnnotationResult {
        try await call(.waitForUserAnnotation, params, as: UserAnnotationResult.self, timeout: params.effectiveTimeout + 30)
    }

    /// Asks the app to let this client in; the app may show the user a prompt.
    public func authorize(_ params: AuthorizeParams = AuthorizeParams()) async throws -> AuthorizeResult {
        try await send(.authorize, params, as: AuthorizeResult.self, timeout: authorizationTimeout)
    }

    /// Captures through the app (60 s allows for a large display, OCR and redaction).
    public func capture(_ params: CaptureParams) async throws -> CaptureResult {
        try await call(.capture, params, as: CaptureResult.self, timeout: max(timeout, 60), tool: params.tool)
    }

    public func listWindows(_ params: ListWindowsParams) async throws -> ListWindowsResult {
        try await call(.listWindows, params, as: ListWindowsResult.self, tool: params.tool)
    }

    public func recentAssets(_ params: RecentAssetsParams = RecentAssetsParams()) async throws -> RecentAssetsResult {
        try await call(.recentAssets, params, as: RecentAssetsResult.self)
    }

    public func asset(_ params: AssetParams) async throws -> AssetResult {
        try await call(.asset, params, as: AssetResult.self, timeout: max(timeout, 60))
    }

    public func recordStart(_ params: RecordStartParams) async throws -> RecordStartResult {
        try await call(.recordStart, params, as: RecordStartResult.self, timeout: max(timeout, 20))
    }

    /// Allows time for finishing the movie and, if asked, exporting the GIF.
    public func recordStop(_ params: RecordStopParams = RecordStopParams()) async throws -> RecordStopResult {
        try await call(.recordStop, params, as: RecordStopResult.self, timeout: params.gif == true ? 300 : 60)
    }

    public func recordStatus() async throws -> RecordStatusResult {
        try await call(.recordStatus, BridgeEmpty(), as: RecordStatusResult.self)
    }

    // MARK: Transport

    /// Sends one request and decodes its result. Throws `BridgeClientError`.
    ///
    /// When the app answers `authorization_required`, this asks for authorization (the user
    /// sees the app's prompt) and, if allowed, sends the request once more.
    public func call<Params: Codable & Sendable, Output: Codable & Sendable>(
        _ method: BridgeMethod, _ params: Params, as type: Output.Type, timeout: TimeInterval? = nil, tool: String? = nil
    ) async throws -> Output {
        do {
            return try await send(method, params, as: type, timeout: timeout)
        } catch BridgeClientError.remote(let error) where error.code == .authorizationRequired {
            let answer = try await authorize(AuthorizeParams(tool: tool ?? method.rawValue))
            guard answer.decision.isAllowed else {
                throw BridgeClientError.remote(BridgeErrorPayload(.denied, "The user did not allow this agent to use Inkpane."))
            }
            return try await send(method, params, as: type, timeout: timeout)
        }
    }

    /// One request, one response, no retries.
    public func send<Params: Codable & Sendable, Output: Codable & Sendable>(
        _ method: BridgeMethod, _ params: Params, as type: Output.Type, timeout: TimeInterval? = nil
    ) async throws -> Output {
        let id = UUID().uuidString
        let location = self.location
        let limit = timeout ?? self.timeout
        let client = identity.info
        let exchange = Exchange()
        let line: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Swift.Result {
                        try exchange.run(location: location, id: id, method: method, params: params, client: client, timeout: limit)
                    })
                }
            }
        } onCancel: {
            exchange.cancel()
        }
        return try Self.decodeResult(line, as: type)
    }

    /// Decodes a response line into its result, throwing `BridgeClientError.remote` for errors.
    public static func decodeResult<Output: Decodable>(_ line: Data, as type: Output.Type) throws -> Output {
        let decoder = BridgeJSON.decoder()
        let header: BridgeResponseHeader
        do {
            header = try decoder.decode(BridgeResponseHeader.self, from: line)
        } catch {
            throw BridgeClientError.invalidResponse(error.localizedDescription)
        }
        guard header.ok else {
            throw BridgeClientError.remote(header.error ?? BridgeErrorPayload(.failed, "Unknown error"))
        }
        do {
            guard let result = try decoder.decode(ResultOnly<Output>.self, from: line).result else {
                throw BridgeClientError.invalidResponse("missing result")
            }
            return result
        } catch let error as BridgeClientError {
            throw error
        } catch {
            throw BridgeClientError.invalidResponse(error.localizedDescription)
        }
    }

    private struct ResultOnly<R: Decodable>: Decodable {
        var result: R?
    }
}

/// One blocking request/response on a background thread; `cancel()` unblocks it from any thread.
private final class Exchange: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var isCancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    private func adopt(_ socket: Int32) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else {
            close(socket)
            throw BridgeClientError.cancelled
        }
        fd = socket
    }

    private func finish() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { close(fd) }
        fd = -1
    }

    private var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func run<Params: Codable & Sendable>(
        location: BridgeLocation, id: String, method: BridgeMethod, params: Params, client: BridgeClientInfo?, timeout: TimeInterval
    ) throws -> Data {
        let socket: Int32
        do {
            socket = try UnixSocket.connect(path: location.socketURL.path)
        } catch .notListening(let path) {
            throw BridgeClientError.appNotRunning(socketPath: path)
        } catch {
            throw BridgeClientError.transport(error.localizedDescription)
        }
        try adopt(socket)
        defer { finish() }

        // The app writes the token right after it starts listening; allow for that moment.
        var token = BridgeToken.read(from: location.tokenURL)
        for _ in 0..<10 where token == nil && !cancelled {
            usleep(50_000)
            token = BridgeToken.read(from: location.tokenURL)
        }
        guard let token else {
            throw BridgeClientError.tokenUnavailable(path: location.tokenURL.path)
        }
        let request = BridgeRequest(id: id, token: token, method: method, params: params, client: client)
        do {
            try UnixSocket.writeAll(socket, try BridgeJSON.line(request))
        } catch {
            if cancelled { throw BridgeClientError.cancelled }
            throw BridgeClientError.transport(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var lines = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        let decoder = BridgeJSON.decoder()
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw BridgeClientError.timedOut(seconds: timeout) }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
            if cancelled { throw BridgeClientError.cancelled }
            if ready < 0 {
                if errno == EINTR { continue }
                throw BridgeClientError.transport(String(cString: strerror(errno)))
            }
            if ready == 0 { continue }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                if cancelled { throw BridgeClientError.cancelled }
                throw BridgeClientError.transport(String(cString: strerror(errno)))
            }
            if count == 0 {
                throw cancelled ? BridgeClientError.cancelled : BridgeClientError.connectionClosed
            }
            let complete: [Data]
            do {
                complete = try lines.append(Data(chunk[0..<count]))
            } catch {
                throw BridgeClientError.invalidResponse(error.localizedDescription)
            }
            for line in complete {
                // Responses to other requests can't arrive on this private connection, but an
                // id-less error (e.g. an unparsable request) can.
                let header = try? decoder.decode(BridgeResponseHeader.self, from: line)
                if header?.id == id || header?.id == nil || header?.id == "" { return line }
            }
        }
    }
}
