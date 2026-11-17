import Darwin
import Foundation
import Testing
@testable import InkpaneMCP

/// `BlockingStdioTransport` over pipes standing in for stdin/stdout.
@Suite struct BlockingStdioTransportTests {
    private struct Pipe {
        let read: Int32
        let write: Int32
        init() {
            var fds: [Int32] = [0, 0]
            precondition(pipe(&fds) == 0)
            (read, write) = (fds[0], fds[1])
        }
        func send(_ text: String) {
            let bytes = Array(text.utf8)
            precondition(Darwin.write(write, bytes, bytes.count) == bytes.count)
        }
    }

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> [String] {
        var lines: [String] = []
        for try await message in stream { lines.append(String(decoding: message, as: UTF8.self)) }
        return lines
    }

    @Test func splitsLinesAcrossAndWithinReadsAndFinishesAtEOF() async throws {
        let input = Pipe(), output = Pipe()
        let transport = BlockingStdioTransport(input: input.read, output: output.write)
        try await transport.connect()
        let messages = Task { try await collect(await transport.receive()) }
        input.send("{\"a\":1}\n{\"b\"")
        try await Task.sleep(for: .milliseconds(50))
        input.send(":2}\n\n{\"c\":3}\n{\"partial\"")
        close(input.write)  // EOF: the unterminated tail is dropped, like the SDK transport
        #expect(try await messages.value == ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
        close(input.read); close(output.read); close(output.write)
    }

    @Test func waitsInsteadOfFailingOnANonBlockingDescriptor() async throws {
        let input = Pipe(), output = Pipe()
        _ = fcntl(input.read, F_SETFL, fcntl(input.read, F_GETFL) | O_NONBLOCK)
        let transport = BlockingStdioTransport(input: input.read, output: output.write)
        try await transport.connect()
        let messages = Task { try await collect(await transport.receive()) }
        try await Task.sleep(for: .milliseconds(100))  // reader hits EAGAIN and parks in poll
        input.send("{\"late\":true}\n")
        close(input.write)
        #expect(try await messages.value == ["{\"late\":true}"])
        close(input.read); close(output.read); close(output.write)
    }

    @Test func sendWritesOneLinePerMessage() async throws {
        let input = Pipe(), output = Pipe()
        let transport = BlockingStdioTransport(input: input.read, output: output.write)
        try await transport.connect()
        try await transport.send(Data("{\"id\":1}".utf8))
        try await transport.send(Data("{\"id\":2}".utf8))
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(output.read, &buffer, buffer.count)
        #expect(String(decoding: buffer[..<count], as: UTF8.self) == "{\"id\":1}\n{\"id\":2}\n")
        await transport.disconnect()
        await #expect(throws: (any Error).self) { try await transport.send(Data("x".utf8)) }
        close(input.write); close(input.read); close(output.read); close(output.write)
    }

    /// The reason this transport exists: the SDK's polls stdin every 10 ms. A connected but idle
    /// transport must not burn CPU (measured on the whole binary: 0.00 s over 60 s, against
    /// ~0.2 s per 30 s with the SDK's `StdioTransport`).
    @Test func idleReaderUsesNoCPU() async throws {
        let input = Pipe(), output = Pipe()
        let transport = BlockingStdioTransport(input: input.read, output: output.write)
        try await transport.connect()
        try await Task.sleep(for: .milliseconds(50))
        let reader = try #require(Self.thread(named: "inkpane-mcp stdin"))
        let before = Self.cpuTime(of: reader)
        try await Task.sleep(for: .seconds(1))
        let used = Self.cpuTime(of: reader) - before
        #expect(used < 0.002, "idle stdin reader used \(used) s of CPU in 1 s")
        close(input.write)
        for try await _ in await transport.receive() {}
        close(input.read); close(output.read); close(output.write)
    }

    // MARK: Per-thread CPU time via Mach

    private static func threads() -> [thread_act_t] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        }
        return (0..<Int(count)).map { list[$0] }
    }

    private static func thread(named name: String) -> thread_act_t? {
        threads().first { thread in
            guard let pthread = pthread_from_mach_thread_np(thread) else { return false }
            var buffer = [CChar](repeating: 0, count: 64)
            pthread_getname_np(pthread, &buffer, buffer.count)
            return String(cString: buffer) == name
        }
    }

    private static func cpuTime(of thread: thread_act_t) -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        return user + system
    }
}
