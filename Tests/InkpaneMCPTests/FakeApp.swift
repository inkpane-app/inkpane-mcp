import Darwin
import Foundation
import InkpaneKit

/// A stand-in for the Inkpane app: listens on a temporary socket and answers each request
/// with `respond(method, line)`. Records what it received.
final class FakeApp: @unchecked Sendable {
    let location: BridgeLocation
    private let fd: Int32
    private let lock = NSLock()
    private var received: [(method: String, line: Data)] = []
    private let respond: @Sendable (String, Data) -> Data

    init(respond: @escaping @Sendable (_ method: String, _ line: Data) -> Data) throws {
        location = BridgeLocation(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sbfake-\(UUID().uuidString.prefix(8))"))
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        try BridgeToken.write("tok", to: location.tokenURL)
        fd = try UnixSocket.listen(path: location.socketURL.path)
        self.respond = respond
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    var methods: [String] { lock.withLock { received.map(\.method) } }
    var lines: [Data] { lock.withLock { received.map(\.line) } }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
        try? FileManager.default.removeItem(at: location.directory)
    }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            Thread { [weak self] in self?.serve(client) }.start()
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var buffer = LineBuffer()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(client, &bytes, bytes.count)
            guard n > 0 else { return }
            guard let lines = try? buffer.append(Data(bytes[0..<n])) else { return }
            for line in lines {
                let header = try? BridgeJSON.decoder().decode(BridgeRequestHeader.self, from: line)
                let method = header?.method ?? "?"
                lock.withLock { received.append((method, line)) }
                var reply = respond(method, line)
                // Echo the request id.
                if let id = header?.id, var object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] {
                    object["id"] = id
                    reply = (try? JSONSerialization.data(withJSONObject: object)) ?? reply
                }
                reply.append(0x0A)
                try? UnixSocket.writeAll(client, reply)
            }
        }
    }

    // MARK: Canned replies

    static func success<R: Codable & Sendable>(_ result: R) -> Data {
        try! BridgeJSON.encoder().encode(BridgeResponse.success(id: "", result))
    }

    static func failure(_ code: BridgeErrorPayload.Code, _ message: String) -> Data {
        try! BridgeJSON.encoder().encode(BridgeErrorPayload(code, message).response(id: ""))
    }
}
