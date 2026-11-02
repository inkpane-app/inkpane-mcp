import Darwin
import Foundation
import Testing

@testable import InkpaneKit

@Suite struct BridgeProtocolTests {
    @Test func requestsUseSnakeCaseAndCarryVersionAndID() throws {
        let request = BridgeRequest(
            id: "7", token: "t", method: .waitForUserAnnotation,
            params: UserAnnotationParams(prompt: "Circle it", shape: .freehand, includeOcr: false))
        let json = String(decoding: try BridgeJSON.encoder().encode(request), as: UTF8.self)
        #expect(json.contains(#""v":1"#))
        #expect(json.contains(#""id":"7""#))
        #expect(json.contains(#""method":"wait_for_user_annotation""#))
        #expect(json.contains(#""include_ocr":false"#))
        let decoded = try BridgeJSON.decoder().decode(BridgeRequest<UserAnnotationParams>.self, from: Data(json.utf8))
        #expect(decoded.params == request.params)
    }

    @Test func resultsRoundTrip() throws {
        let result = UserAnnotationResult(
            status: .selected,
            region: .init(shape: .rectangle, bbox: Rect(x: 1, y: 2, width: 3, height: 4), displayIndex: 0),
            image: .init(pngBase64: "AA==", frame: Rect(x: 1, y: 2, width: 3, height: 4), scale: 2, pixelWidth: 6, pixelHeight: 8),
            ocr: .init(text: "OK", languages: ["en-US"], lines: [.init(text: "OK", confidence: 1, screenBox: nil)]))
        let line = try BridgeJSON.line(BridgeResponse.success(id: "1", result))
        #expect(line.last == 0x0A)
        let json = String(decoding: line, as: UTF8.self)
        #expect(json.contains(#""png_base64":"AA==""#))
        #expect(json.contains(#""display_index":0"#))
        #expect(try BridgeClient.decodeResult(line.dropLast(), as: UserAnnotationResult.self) == result)
    }

    @Test func errorResponsesBecomeRemoteErrors() throws {
        let line = try BridgeJSON.encoder().encode(BridgeErrorPayload(.unauthorized, "no").response(id: "1"))
        #expect(throws: BridgeClientError.remote(BridgeErrorPayload(.unauthorized, "no"))) {
            try BridgeClient.decodeResult(line, as: HelloResult.self)
        }
    }

    @Test func annotationValidation() {
        #expect(throws: BridgeErrorPayload.self) { try BridgeAnnotation(kind: .box).validate() }
        #expect(throws: BridgeErrorPayload.self) { try BridgeAnnotation.box(Rect(x: 0, y: 0, width: -1, height: 5)).validate() }
        #expect(throws: BridgeErrorPayload.self) { try BridgeAnnotation.arrow(from: .init(x: 1, y: 1), to: .init(x: 1, y: 1)).validate() }
        #expect(throws: BridgeErrorPayload.self) { try BridgeAnnotation.text("  ", at: .init(x: 0, y: 0)).validate() }
        #expect(throws: BridgeErrorPayload.self) { try BridgeAnnotation.box(Rect(x: 0, y: 0, width: 5, height: 5), color: "teal-ish").validate() }
        #expect(throws: Never.self) { try BridgeAnnotation.highlight(Rect(x: 0, y: 0, width: 5, height: 5), color: "#ffcc00").validate() }
        #expect(throws: BridgeErrorPayload.self) { try AnnotateParams(annotations: []).validate() }
        #expect(throws: BridgeErrorPayload.self) { try UserAnnotationParams(prompt: "x", timeout: 0).validate() }
    }

    @Test func spotlightValidationAndWireFormat() throws {
        let rect = Rect(x: 10, y: 20, width: 300, height: 200)
        #expect(throws: Never.self) { try BridgeAnnotation.spotlight(rect).validate() }
        #expect(throws: Never.self) { try BridgeAnnotation.spotlight(rect, shape: .ellipse, dimOpacity: 0.9, label: "Here").validate() }
        #expect(throws: BridgeErrorPayload.self) { try BridgeAnnotation(kind: .spotlight).validate() }
        #expect(throws: BridgeErrorPayload.self) { try BridgeAnnotation.spotlight(Rect(x: 0, y: 0, width: 0, height: 5)).validate() }
        #expect(throws: BridgeErrorPayload.self) { try BridgeAnnotation.spotlight(rect, dimOpacity: 0.95).validate() }
        #expect(throws: BridgeErrorPayload.self) { try BridgeAnnotation.spotlight(rect, dimOpacity: .nan).validate() }
        // Spotlight options on other kinds are mistakes, not silently ignored.
        var box = BridgeAnnotation.box(rect)
        box.dimOpacity = 0.5
        #expect(throws: BridgeErrorPayload.self) { try box.validate() }

        // Additive on the wire: snake_case keys, and absent when unused.
        let params = AnnotateParams(annotations: [.spotlight(rect, shape: .ellipse, dimOpacity: 0.7), .box(rect)])
        let request = BridgeRequest(id: "1", token: "t", method: .annotate, params: params)
        let json = try #require(String(data: BridgeJSON.encoder().encode(request), encoding: .utf8))
        #expect(json.contains(#""kind":"spotlight""#) && json.contains(#""shape":"ellipse""#) && json.contains(#""dim_opacity":0.7"#))
        #expect(json.components(separatedBy: "dim_opacity").count == 2)
        let decoded = try BridgeJSON.decoder().decode(BridgeRequest<AnnotateParams>.self, from: Data(json.utf8))
        #expect(decoded.params == params)
        #expect(BridgeProtocol.version == 1)
    }

    @Test func colors() {
        #expect(BridgeColor.normalizedHex("Blue") == "#0A84FF")
        #expect(BridgeColor.normalizedHex("ff3b30") == "#FF3B30")
        #expect(BridgeColor.normalizedHex("#ff3b3080") == "#FF3B3080")
        #expect(BridgeColor.normalizedHex("#ff3") == nil)
    }

    @Test func lineBufferSplitsAcrossChunks() throws {
        var buffer = LineBuffer(maxLineBytes: 16)
        #expect(try buffer.append(Data("ab".utf8)).isEmpty)
        #expect(try buffer.append(Data("c\n\nde\nf".utf8)) == [Data("abc".utf8), Data("de".utf8)])
        #expect(try buffer.append(Data("g\n".utf8)) == [Data("fg".utf8)])
        #expect(throws: BridgeSocketError.self) { try buffer.append(Data(repeating: 0x41, count: 32)) }
    }

    @Test func tokens() throws {
        let a = BridgeToken.generate()
        #expect(a.count == 64)
        #expect(a != BridgeToken.generate())
        #expect(BridgeToken.matches(a, a))
        #expect(!BridgeToken.matches(nil, a))
        #expect(!BridgeToken.matches(String(a.dropLast()) + "x", a))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agent.token")
        try BridgeToken.write(a, to: url)
        try BridgeToken.write("second", to: url)
        #expect(BridgeToken.read(from: url) == "second")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func locationFromEnvironment() {
        #expect(BridgeLocation.fromEnvironment([:]) == .default)
        #expect(BridgeLocation.default.socketURL.path.hasSuffix("Application Support/app.inkpane.Inkpane/agent.sock"))
        let custom = BridgeLocation.fromEnvironment(["INKPANE_APP_DIR": "/tmp/x"])
        #expect(custom.socketURL.path == "/tmp/x/agent.sock")
        #expect(custom.tokenURL.path == "/tmp/x/agent.token")
    }
}

/// The client against a minimal fake app speaking the protocol.
@Suite(.serialized) struct BridgeClientTests {
    private static func location() -> BridgeLocation {
        BridgeLocation(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sbc-\(UUID().uuidString.prefix(8))"))
    }

    @Test func reportsAppNotRunningWhenNothingListens() async throws {
        let location = Self.location()
        await #expect(throws: BridgeClientError.appNotRunning(socketPath: location.socketURL.path)) {
            try await BridgeClient(location: location).hello()
        }
        // A stale socket file left by a crashed app is treated the same way.
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let fd = try UnixSocket.listen(path: location.socketURL.path)
        close(fd)
        #expect(FileManager.default.fileExists(atPath: location.socketURL.path))
        await #expect(throws: BridgeClientError.appNotRunning(socketPath: location.socketURL.path)) {
            try await BridgeClient(location: location).hello()
        }
    }

    @Test func sendsTokenAndDecodesTheMatchingResponse() async throws {
        let location = Self.location()
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try BridgeToken.write("tok", to: location.tokenURL)
        let fd = try UnixSocket.listen(path: location.socketURL.path)
        let mode = try FileManager.default.attributesOfItem(atPath: location.socketURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let server = Thread {
            let client = accept(fd, nil, nil)
            defer { close(client); close(fd) }
            #expect(UnixSocket.peerUID(client) == getuid())
            var buffer = LineBuffer()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(client, &bytes, bytes.count)
                guard n > 0 else { return }
                guard let line = try? buffer.append(Data(bytes[0..<n])).first else { continue }
                let request = try! BridgeJSON.decoder().decode(BridgeRequest<BridgeEmpty>.self, from: line)
                #expect(request.token == "tok")
                #expect(request.method == .hello)
                // An unrelated response first; the client must skip it.
                try! UnixSocket.writeAll(client, BridgeJSON.line(BridgeResponse.success(id: "other", HelloResult(app: "Wrong", appVersion: "0"))))
                try! UnixSocket.writeAll(client, BridgeJSON.line(BridgeResponse.success(id: request.id, HelloResult(app: "Fake", appVersion: "9.9"))))
                return
            }
        }
        server.start()
        let hello = try await BridgeClient(location: location).hello()
        #expect(hello.app == "Fake")
        #expect(hello.appVersion == "9.9")
    }

    @Test func listenRefusesALiveSocketAndReplacesAStaleOne() throws {
        let location = Self.location()
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let live = try UnixSocket.listen(path: location.socketURL.path)
        #expect(throws: BridgeSocketError.addressInUse(path: location.socketURL.path)) {
            try UnixSocket.listen(path: location.socketURL.path)
        }
        close(live)
        let replacement = try UnixSocket.listen(path: location.socketURL.path)
        close(replacement)
    }
}
