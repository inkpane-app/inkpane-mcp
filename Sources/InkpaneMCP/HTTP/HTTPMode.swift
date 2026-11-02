import Foundation
import InkpaneKit

/// How to serve, from the command line: `[--http [--port N]] [--require-app]`, in any order.
public struct ServeOptions: Equatable, Sendable {
    public var http = false
    public var port = MCPHTTPServer.defaultPort
    public var requireApp = false

    public init(http: Bool = false, port: UInt16 = MCPHTTPServer.defaultPort, requireApp: Bool = false) {
        self.http = http
        self.port = port
        self.requireApp = requireApp
    }

    /// `nil` when `arguments` aren't serve options (the caller prints usage).
    public static func parse(_ arguments: [String]) -> ServeOptions? {
        var options = ServeOptions()
        var portGiven = false
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--http": options.http = true
            case "--require-app": options.requireApp = true
            case "--port":
                guard let value = rest.popFirst(), let port = UInt16(value), port > 0 else { return nil }
                options.port = port
                portGiven = true
            default:
                if argument.hasPrefix("--port="), let port = UInt16(argument.dropFirst(7)), port > 0 {
                    options.port = port
                    portGiven = true
                } else {
                    return nil
                }
            }
        }
        if portGiven && !options.http { return nil }
        return options
    }
}

extension InkpaneServer {
    /// Serves MCP over Streamable HTTP on 127.0.0.1 until the process is stopped. `log` gets the
    /// startup lines (URL, where the token is, and the token itself the first time).
    public static func runHTTP(port: UInt16, requirement: AppRequirement? = nil, log: @Sendable (String) -> Void) async throws {
        var tools = InkpaneTools.fromEnvironment()
        if let requirement { tools.requirement = requirement }
        let location = tools.bridge.location
        let (token, created) = try MCPHTTPToken.loadOrCreate(in: location)
        let server = MCPHTTPServer(configuration: .init(port: port, token: token), tools: tools)
        try await server.start()
        log("inkpane-mcp \(version): serving MCP over HTTP at \(server.url) (127.0.0.1 only).")
        if created {
            log("Created a bearer token in \(MCPHTTPToken.url(in: location).path) (mode 0600): \(token)")
        } else {
            log("Bearer token: \(MCPHTTPToken.url(in: location).path) (delete the file to make a new one).")
        }
        log("Clients send \"Authorization: Bearer <token>\". Stop with Ctrl-C.")
        // Serve until killed.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        await server.stop()
    }
}
