import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

struct DisconnectDiagnosticsTests {
    @Test(arguments: [false, true])
    func writerFailureSurvivesBlockedReader(partialMessage: Bool) throws {
        let fixture = try DiagnosticSession()
        defer { fixture.finish() }
        try fixture.initialize()
        try fixture.peer.writeAll([3, 0, 0, 0, 0, 0, 0, 2, 0, 1])
        try #require(fixture.screen.entered.wait(timeout: .now() + 2) == .success)
        if partialMessage {
            // Leave SetPixelFormat incomplete so shutdown interrupts a read of
            // its body, not just the next message type.
            try fixture.peer.writeAll([0])
            let deadline = Date().addingTimeInterval(2)
            var descriptor = pollfd(fd: fixture.server.fd, events: Int16(POLLIN), revents: 0)
            var pending: Int32 = 1
            repeat {
                pending = poll(&descriptor, 1, 0)
                try #require(pending >= 0)
                if pending == 0 { break }
                Thread.sleep(forTimeInterval: 0.005)
            } while Date() < deadline
            try #require(pending == 0)
        }
        fixture.screen.resume.signal()
        try #require(fixture.done.wait(timeout: .now() + 2) == .success)
        #expect(fixture.result.error as? DiagnosticFailure == .capture)
        let summary = try #require(fixture.logs.lines.last)
        #expect(summary.contains("source=framebuffer_writer"))
        #expect(summary.contains(DiagnosticFailure.capture.localizedDescription))
        #expect(summary.contains("last_client_message=\(partialMessage ? "0x00" : "0x03")"))
        #expect(summary.contains("duration_s=") && summary.contains("network_stalls=0"))
        #expect(!summary.contains("socket error: client disconnected"))
    }

    @Test func readerProtocolFailureRemainsTheReportedCause() throws {
        let fixture = try DiagnosticSession()
        defer { fixture.finish() }
        try fixture.initialize()
        try fixture.peer.writeAll([0xff])
        try #require(fixture.done.wait(timeout: .now() + 2) == .success)
        #expect(fixture.result.error?.localizedDescription == "protocol error: unsupported client message 255")
        let summary = try #require(fixture.logs.lines.last)
        #expect(summary.contains("source=reader"))
        #expect(summary.contains("last_client_message=0xff"))
    }

    @Test func connectionLogsDistinguishReusedDescriptorsAndIncludeUTC() throws {
        let fixture = try DiagnosticSession()
        defer { fixture.finish() }
        let logs = DiagnosticLog()
        let logger = ServerLogger(verbose: false, output: { logs.append($0) })
        let first = logger.forClient(fixture.server)
        let second = logger.forClient(fixture.server)
        first.info("connected")
        first.warning("disconnected")
        second.info("connected")
        let lines = logs.lines
        try #require(lines.count == 3)
        func field(_ name: String, in line: String) throws -> String {
            let value = try #require(line.components(separatedBy: "\(name)=").dropFirst().first)
            return String(value.prefix { $0 != " " && $0 != "]" })
        }
        let firstID = try field("client_id", in: lines[0])
        #expect(UUID(uuidString: firstID) != nil)
        #expect(try field("client_id", in: lines[1]) == firstID)
        #expect(try field("client_id", in: lines[2]) != firstID)
        let timestamp = try field("time", in: lines[0])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(timestamp.hasSuffix("Z") && formatter.date(from: timestamp) != nil)
        #expect(lines[0].contains("pid=\(getpid())") && lines[0].contains("peer=unix local=unix"))
    }
}

private enum DiagnosticFailure: Error, LocalizedError {
    case capture
    var errorDescription: String? { "diagnostic fixture capture failed" }
}

private final class DiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var lines: [String] { lock.withLock { messages } }
    func append(_ line: String) { lock.withLock { messages.append(line) } }
}

private final class DiagnosticResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    var error: Error? { lock.withLock { storedError } }
    func record(_ error: Error) { lock.withLock { storedError = error } }
}

private final class DiagnosticScreen: FramebufferSource, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private var initialized = false

    func capture() throws -> Framebuffer {
        if initialized {
            entered.signal()
            guard resume.wait(timeout: .now() + 5) == .success else {
                throw RFBError.captureFailed("diagnostic fixture gate timed out")
            }
            throw DiagnosticFailure.capture
        }
        initialized = true
        return Framebuffer(width: 2, height: 1, bgra: [0, 0, 0, 255, 0, 0, 0, 255],
            layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1))
    }
}

private struct DiagnosticInput: InputController {
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {}
    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {}
    func releaseKeys() {}
}

private final class DiagnosticSession {
    let server: ClientSocket
    let peer: ClientSocket
    let screen = DiagnosticScreen()
    let result = DiagnosticResult()
    let logs = DiagnosticLog()
    let done = DispatchGroup()

    init() throws {
        var fds = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        for fd in fds {
            var enabled: Int32 = 1
            try #require(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0)
        }
        server = try ClientSocket(fd: fds[0])
        peer = try ClientSocket(fd: fds[1])
        let logs = self.logs
        let logger = ServerLogger(verbose: false, output: { logs.append($0) }).forClient(server)
        let session = try RFBClientSession(socket: server, fps: 30, encodingPreference: .raw,
            capture: screen, input: DiagnosticInput(), clipboard: DisabledClipboard(), clipboardSync: false,
            adaptiveStreaming: false, adaptiveFrameRate: false, logger: logger)
        let admission = SessionAdmission(identity: ConsoleIdentity(uid: 501, auditID: 12345),
            version: "RFB 003.008\n", wrappingKey: [UInt8](repeating: 0, count: 16))
        done.enter()
        DispatchQueue.global().async { [done, result, server] in
            defer { server.shutdown(); done.leave() }
            do { try session.run(admission: admission) }
            catch { result.record(error) }
        }
    }

    func initialize() throws {
        try peer.writeAll([1])
        try peer.withReadTimeout(2, operation: "diagnostic fixture initialization") {
            #expect(try peer.readExact(4) == [0, 0, 0, 0])
            _ = try peer.readExact(20)
            let length = try peer.readExact(4)
            _ = try peer.readExact(Int(UInt32.be(length[0], length[1], length[2], length[3])))
        }
    }

    func finish() {
        screen.resume.signal()
        peer.shutdown()
        #expect(done.wait(timeout: .now() + 3) == .success)
    }
}
