import Darwin
import Foundation
import MCP
import InkpaneKit
import Testing
@testable import InkpaneMCP

/// `inkpane-mcp --http` on an ephemeral loopback port. Every test stops its server.
@Suite(.serialized) struct HTTPTransportTests {
    static let token = String(repeating: "ab", count: 32)

    private func withServer(_ body: (MCPHTTPServer, URL) async throws -> Void) async throws {
        let nowhere = BridgeLocation(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sbnone-\(UUID().uuidString.prefix(8))"))
        let tools = InkpaneTools(
            store: CaptureStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sbhttp-\(UUID().uuidString.prefix(8))")),
            bridge: BridgeClient(location: nowhere, timeout: 5), uiTreeReading: FakeUITreeReader().reading)
        let server = MCPHTTPServer(configuration: .init(port: 0, token: Self.token), tools: tools)
        let port = try await server.start()
        #expect(port > 0)
        do {
            try await body(server, server.url)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private let session = URLSession(configuration: .ephemeral)

    private func post(_ url: URL, _ body: String, headers: [String: String]) async throws -> (Int, [String: String], String) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (Int, [String: String], String) {
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        return (http.statusCode, headers, String(decoding: data, as: UTF8.self))
    }

    private static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl-test","version":"1"}}}"#

    @Test func refusesRequestsWithoutTheToken() async throws {
        try await withServer { _, url in
            let (status, headers, _) = try await post(url, Self.initialize, headers: [:])
            #expect(status == 401)
            #expect(headers["www-authenticate"]?.hasPrefix("Bearer") == true)
            let (wrong, _, _) = try await post(url, Self.initialize, headers: ["Authorization": "Bearer nope"])
            #expect(wrong == 401)
            let (basic, _, _) = try await post(url, Self.initialize, headers: ["Authorization": "Basic \(Self.token)"])
            #expect(basic == 401)
        }
    }

    @Test func refusesForeignOrigins() async throws {
        try await withServer { _, url in
            let auth = "Bearer \(Self.token)"
            for origin in ["http://evil.example", "https://localhost.evil.example", "null", "http://127.0.0.1.nip.io:3000"] {
                let (status, _, _) = try await post(url, Self.initialize, headers: ["Authorization": auth, "Origin": origin])
                #expect(status == 403, "\(origin)")
            }
            let (local, headers, body) = try await post(url, Self.initialize, headers: ["Authorization": auth, "Origin": "http://localhost:5173"])
            #expect(local == 200, "loopback origins are fine: \(body)")
            #expect(headers["access-control-allow-origin"] == nil, "no CORS")
        }
    }

    @Test func checksHostPathMethodAndSession() async throws {
        try await withServer { server, url in
            let port = server.port
            let auth = "Bearer \(Self.token)"
            func head(_ headers: [String: String], path: String = "/mcp", method: String = "POST") -> HTTPRequestHead {
                HTTPRequestHead(method: method, path: path, headers: headers, repeated: [], body: Data())
            }
            // DNS rebinding: the attacker's page sends its own host name.
            #expect(MCPHTTPServer.refusal(for: head(["host": "evil.example:\(port)", "authorization": auth]), port: port, token: Self.token) != nil)
            #expect(MCPHTTPServer.refusal(for: head(["authorization": auth]), port: port, token: Self.token) != nil)
            #expect(MCPHTTPServer.refusal(for: head(["host": "127.0.0.1:\(port)", "authorization": auth]), port: port, token: Self.token) == nil)
            #expect(MCPHTTPServer.refusal(for: head(["host": "localhost:\(port)", "authorization": auth], path: "/other"), port: port, token: Self.token) != nil)
            var twice = head(["host": "127.0.0.1:\(port)", "authorization": auth])
            twice.repeated = ["authorization"]
            #expect(MCPHTTPServer.refusal(for: twice, port: port, token: Self.token) != nil)

            var get = URLRequest(url: url)
            get.setValue(auth, forHTTPHeaderField: "Authorization")
            get.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let getStatus = try await send(get).0
            #expect(getStatus == 405)

            let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
            let noSession = try await post(url, list, headers: ["Authorization": auth]).0
            #expect(noSession == 400, "only initialize may come without a session")
            let unknownSession = try await post(url, list, headers: ["Authorization": auth, "Mcp-Session-Id": "made-up"]).0
            #expect(unknownSession == 404)
            let otherPath = try await post(url.deletingLastPathComponent().appendingPathComponent("other"), list, headers: ["Authorization": auth]).0
            #expect(otherPath == 404)
        }
    }

    @Test func initializeReturnsASessionAndAnEventStream() async throws {
        try await withServer { _, url in
            let (status, headers, body) = try await post(url, Self.initialize, headers: ["Authorization": "Bearer \(Self.token)"])
            #expect(status == 200)
            #expect(headers["content-type"]?.hasPrefix("text/event-stream") == true)
            #expect(headers["mcp-session-id"]?.isEmpty == false)
            #expect(body.contains("\"serverInfo\""))
            #expect(body.contains("inkpane-mcp"))
            #expect(body.contains("\"prompts\""))
        }
    }

    @Test func roundTripWithTheSDKClient() async throws {
        try await withServer { _, url in
            let transport = HTTPClientTransport(
                endpoint: url, configuration: .ephemeral, streaming: true,
                requestModifier: { request in
                    var request = request
                    request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
                    return request
                })
            let client = Client(name: "http-test", version: "1.0")
            let initialized = try await client.connect(transport: transport)
            #expect(initialized.serverInfo.name == InkpaneServer.name)
            let tools = try await client.listTools().tools.map(\.name)
            #expect(tools == ToolCatalog.tools.map(\.name))
            #expect(try await client.listPrompts().prompts.count == PromptCatalog.prompts.count)
            // A tool call end to end (the UI tree comes from a fake reader, not the screen).
            let (content, isError) = try await client.callTool(name: ToolCatalog.getUITree, arguments: ["format": "outline"])
            #expect(isError != true)
            let texts = content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }
            #expect(texts.last?.contains("AXButton \"Save\"") == true)
            await client.disconnect()
        }
    }

    @Test func portInUseIsAClearError() async throws {
        try await withServer { server, _ in
            let other = MCPHTTPServer(configuration: .init(port: server.port, token: Self.token), tools: InkpaneTools())
            await #expect(throws: MCPHTTPServer.StartError.self) { try await other.start() }
            await other.stop()
        }
    }

    @Test func requestParserHandlesLimits() throws {
        var parser = HTTPRequestParser(maxBodyBytes: 10)
        #expect(try parser.append(Data("POST /mcp?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 4\r\n\r\nab".utf8)) == nil)
        let request = try #require(try parser.append(Data("cd".utf8)))
        #expect(request.path == "/mcp" && request.body == Data("abcd".utf8) && request.headers["host"] == "a")

        var big = HTTPRequestParser(maxBodyBytes: 10)
        #expect(throws: HTTPParseError.bodyTooLarge) { try big.append(Data("POST / HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8)) }
        var chunked = HTTPRequestParser(maxBodyBytes: 10)
        #expect(throws: HTTPParseError.unsupportedTransferEncoding) { try chunked.append(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) }
        var junk = HTTPRequestParser(maxBodyBytes: 10)
        #expect(throws: HTTPParseError.self) { try junk.append(Data("hello\r\n\r\n".utf8)) }
        var repeated = HTTPRequestParser(maxBodyBytes: 10)
        let twice = try #require(try repeated.append(Data("GET / HTTP/1.1\r\nOrigin: a\r\norigin: b\r\n\r\n".utf8)))
        #expect(twice.repeated == ["origin"])
    }

    @Test func serveOptions() {
        #expect(ServeOptions.parse([]) == ServeOptions())
        #expect(ServeOptions.parse(["--http"]) == ServeOptions(http: true))
        #expect(ServeOptions.parse(["--require-app", "--http", "--port", "9000"]) == ServeOptions(http: true, port: 9000, requireApp: true))
        #expect(ServeOptions.parse(["--http", "--port=9001"]) == ServeOptions(http: true, port: 9001))
        #expect(ServeOptions.parse(["--port", "9000"]) == nil, "--port only goes with --http")
        #expect(ServeOptions.parse(["--http", "--port", "0"]) == nil)
        #expect(ServeOptions.parse(["--http", "--port", "70000"]) == nil)
        #expect(ServeOptions.parse(["--bogus"]) == nil)
    }

    @Test func tokenFileIsPrivateAndStable() throws {
        let location = BridgeLocation(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sbtok-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let first = try MCPHTTPToken.loadOrCreate(in: location)
        #expect(first.created && first.token.count == 64)
        var info = stat()
        #expect(stat(MCPHTTPToken.url(in: location).path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        let second = try MCPHTTPToken.loadOrCreate(in: location)
        #expect(!second.created && second.token == first.token)
        #expect(MCPHTTPToken.read(in: location) == first.token)

        chmod(MCPHTTPToken.url(in: location).path, 0o644)
        #expect(throws: BridgeSocketError.self) { try MCPHTTPToken.loadOrCreate(in: location) }
    }
}
