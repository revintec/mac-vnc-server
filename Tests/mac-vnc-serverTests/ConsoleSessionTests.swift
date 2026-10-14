import CoreGraphics
import CVNCSession
import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

struct ConsoleSessionTests {
    @Test func consolePortConflictsAreDetectedBeforeCaptureAndListeningCanBeDeferred() throws {
        let listener = try ListeningSocket(bindAddress: "127.0.0.1", port: 0, startListening: false)
        var address = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        try #require(withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener.fd, $0, &size) }
        } == 0)
        func connectPeer() -> (Int32, Int32) {
            let peer = socket(AF_INET, SOCK_STREAM, 0)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(peer, $0, size) }
            }
            return (peer, result)
        }
        let (earlyPeer, earlyResult) = connectPeer()
        defer { close(earlyPeer) }
        #expect(earlyResult == -1) // Nothing accepts connections during capture startup.
        try listener.startListening()
        let port = UInt16(bigEndian: address.sin_port)
        #expect(throws: (any Error).self) {
            try ListeningSocket(bindAddress: "127.0.0.1", port: port, startListening: false)
        }
        let (readyPeer, readyResult) = connectPeer()
        defer { close(readyPeer) }
        try #require(readyResult == 0)
        let accepted = try #require(try listener.acceptClient(timeout: 1))
        try accepted.writeAll([82, 70, 66])
        var reply = [UInt8](repeating: 0, count: 3)
        #expect(Darwin.read(readyPeer, &reply, reply.count) == 3)
        #expect(reply == [82, 70, 66])
    }

    @Test func consoleOptionsDoNotChangeUserDefaultsOrService() throws {
        guard case .run(let user) = try CLI.parse(arguments: []),
              case .run(let console) = try CLI.parse(arguments: ["--session", "console", "--port", "5902"]),
              case .run(let resolved) = try CLI.parse(arguments: ["--session", "console"])
                .resolvingPassword(environment: ["VNC_PASSWORD": "testpass"]) else {
            Issue.record("expected server commands"); return
        }
        #expect(user.sessionTarget == .listener && user.clipboardSync && user.fileTransfer)
        #expect(console.sessionTarget == .console && !console.clipboardSync && !console.fileTransfer)
        #expect(console.port == 5902 && !console.allowEncryption)
        #expect(resolved.sessionTarget == .console && resolved.password == "testpass")
        #expect(throws: (any Error).self) { try CLI.parse(arguments: ["--session", "console", "--service"]) }
        #expect(throws: (any Error).self) { try CLI.parse(arguments: ["--session", "console", "--clipboard-sync"]) }
        #expect(throws: (any Error).self) { try CLI.parse(arguments: ["--session", "console", "--file-transfer"]) }
        #expect(throws: (any Error).self) { try CLI.parse(arguments: ["--session", "console", "--no-password", "--insecure-allow-no-auth"]) }
        #expect(throws: (any Error).self) { try CLI.parse(arguments: ["--session", "other"]) }
        #expect(throws: (any Error).self) { try CLI.parse(arguments: ["--console-capture-broker", "123"]) }
        guard case .service(let service, _) = try CLI.parse(arguments: ["--service"]) else {
            Issue.record("expected existing user service"); return
        }
        #expect(service.sessionTarget == .listener && service.fileTransfer && service.clipboardSync)
    }

    @Test func anonymousTransportPreservesFrameBytesAndGeometry() throws {
        let (first, second) = try pair()
        defer { first.shutdown(); second.shutdown() }
        let frame = exampleFrame(value: 81)
        try first.send(ConsoleMessage(kind: .frame, frame: ConsoleFrameInfo(frame)), pixels: frame.bgra)
        let (message, pixels) = try second.receive(timeout: 1)
        let decoded = try #require(message.frame).framebuffer(pixels: pixels, sequence: 19)
        #expect(decoded.bgra == frame.bgra)
        #expect(decoded.layout == frame.layout)
        #expect(decoded.sequence == 19)
        let id = UUID()
        try second.send(ConsoleMessage(kind: .key, client: id, down: true, keysym: 65, apple: true))
        let (key, payload) = try first.receive(timeout: 1)
        #expect(key.client == id && key.keysym == 65 && key.down == true && payload.isEmpty)
    }

    @Test func malformedIPCIsRejectedBeforeReadingOrAllocatingItsPayload() throws {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let receiver = try ConsoleTransport(fd: fds[0])
        let sender = try ClientSocket(fd: fds[1])
        defer { receiver.shutdown(); sender.shutdown() }
        // Metadata over the 64 KiB limit; no advertised payload is supplied.
        try sender.writeAll([67, 86, 78, 67, 0, 1, 0, 1, 255, 255, 255, 255])
        #expect(throws: (any Error).self) { try receiver.receive(timeout: 0.1) }
        let frame = exampleFrame(value: 0)
        #expect(throws: (any Error).self) { try ConsoleFrameInfo(frame).validate(pixelCount: 1) }
    }

    @Test func sessionChangeBlanksCachedFrameAndRejectsLateOldWorker() throws {
        let identity = IdentityBox()
        let desktop = ConsoleDesktop(fps: 60, identify: { identity.get() })
        let (old, oldPeer) = try pair()
        defer { desktop.invalidate(); oldPeer.shutdown() }
        let first = desktop.begin(identity.get()!, transport: old)
        let frame = exampleFrame(value: 99)
        try desktop.publish(ConsoleFrameInfo(frame), pixels: frame.bgra, generation: first)
        let oldSequence = try #require(try desktop.currentSequence())
        #expect(try desktop.capture().bgra.first == 99)
        identity.set(ConsoleIdentity(uid: 0, auditID: 200))
        #expect(try desktop.capture().bgra.allSatisfy { $0 == 0 })
        #expect(!desktop.hasReadyFrame)
        let (new, newPeer) = try pair()
        defer { newPeer.shutdown() }
        let second = desktop.begin(identity.get()!, transport: new)
        let newFrame = exampleFrame(value: 17)
        try desktop.publish(ConsoleFrameInfo(newFrame), pixels: newFrame.bgra, generation: second)
        try desktop.publish(ConsoleFrameInfo(frame), pixels: frame.bgra, generation: first)
        desktop.invalidate(generation: first) // late EOF from old worker
        #expect(desktop.hasReadyFrame)
        #expect(try desktop.capture().bgra.first == 17)
        #expect(try #require(try desktop.currentSequence()) > oldSequence)
    }

    @Test func heldInputCannotCarryIntoReplacementSession() throws {
        let identity = IdentityBox()
        let desktop = ConsoleDesktop(fps: 60, identify: { identity.get() })
        let (old, oldPeer) = try pair()
        defer { desktop.invalidate(); oldPeer.shutdown() }
        let frame = exampleFrame(value: 19)
        let first = desktop.begin(identity.get()!, transport: old)
        try desktop.publish(ConsoleFrameInfo(frame), pixels: frame.bgra, generation: first)
        let input = desktop.makeInput()
        input.key(down: true, keysym: 65, mapAltToCommand: false)
        input.pointer(buttonMask: 1, x: 2, y: 1, layout: frame.layout)
        #expect(try oldPeer.receive(timeout: 1).0.keysym == 65)
        #expect(try oldPeer.receive(timeout: 1).0.mask == 1)
        desktop.invalidate()
        // A key newly pressed while the console is unavailable is also blocked.
        input.key(down: true, keysym: 66, mapAltToCommand: false)
        identity.set(ConsoleIdentity(uid: 0, auditID: 200))
        let (new, newPeer) = try pair()
        defer { newPeer.shutdown() }
        let second = desktop.begin(identity.get()!, transport: new)
        try desktop.publish(ConsoleFrameInfo(frame), pixels: frame.bgra, generation: second)
        input.key(down: true, keysym: 65, mapAltToCommand: false)
        input.key(down: true, keysym: 66, mapAltToCommand: false)
        input.pointer(buttonMask: 1, x: 2, y: 1, layout: frame.layout)
        let event = try newPeer.receive(timeout: 1).0
        #expect(event.kind == .pointer && event.mask == 0)
        input.key(down: false, keysym: 65, mapAltToCommand: false)
        input.key(down: true, keysym: 65, mapAltToCommand: false)
        #expect(try newPeer.receive(timeout: 1).0.keysym == 65)
        input.pointer(buttonMask: 0, x: 2, y: 1, layout: frame.layout)
        input.pointer(buttonMask: 1, x: 2, y: 1, layout: frame.layout)
        #expect(try newPeer.receive(timeout: 1).0.mask == 0)
        #expect(try newPeer.receive(timeout: 1).0.mask == 1)
        input.releaseKeys()
        #expect(try newPeer.receive(timeout: 1).0.kind == .release)
    }

    @Test func closedWorkerInterruptsIPCAndUnavailableConsoleRejectsInput() throws {
        var brokenFDs: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &brokenFDs) == 0)
        let writer = try ConsoleTransport(fd: brokenFDs[0])
        close(brokenFDs[1])
        #expect(throws: (any Error).self) { try writer.send(ConsoleMessage(kind: .heartbeat)) }
        writer.shutdown()
        let identity = IdentityBox()
        let desktop = ConsoleDesktop(fps: 60, identify: { identity.get() })
        let (first, peer) = try pair()
        let token = desktop.begin(identity.get()!, transport: first)
        desktop.makeInput().key(down: true, keysym: 65, mapAltToCommand: false)
        #expect(throws: (any Error).self) { try peer.receive(timeout: 0.02) }
        desktop.invalidate(generation: token)
        #expect(throws: (any Error).self) { try peer.receive(timeout: 1) }
        peer.shutdown()
        if geteuid() != 0 {
            #expect(VNCConsolePrepare(VNCConsoleIdentity(uid: 0, audit_id: 1)) == EPERM)
        }
    }

    @Test func repeatedWorkerCrashesBackOffWithoutDelayingNewSessions() {
        var retry = ConsoleWorkerRetryPolicy()
        let login = ConsoleIdentity(uid: 0, auditID: 100)
        let delays = (0..<8).map { _ in retry.failed(identity: login, wasStable: false) }
        #expect(delays == [500, 1000, 2000, 4000, 8000, 8000, 8000, 8000].map { .milliseconds($0) })
        // A new audit ID with the same UID is a new session too.
        #expect(retry.failed(identity: ConsoleIdentity(uid: 0, auditID: 101), wasStable: false) == .milliseconds(500))
        #expect(retry.failed(identity: login, wasStable: false) == .milliseconds(500))
        #expect(retry.failed(identity: login, wasStable: false) == .seconds(1))
        #expect(retry.failed(identity: login, wasStable: true) == .milliseconds(500))
        _ = retry.failed(identity: login, wasStable: false)
        retry.reset() // console temporarily unavailable
        #expect(retry.failed(identity: login, wasStable: false) == .milliseconds(500))
    }

    @Test func workerStagesValidateOptionsAndCannotSkipIdentityChecks() throws {
        let options = ConsoleWorkerOptions(identity: ConsoleIdentity(uid: 0, auditID: 1),
            fps: 60, scale: 1, display: 0, verbose: false)
        let encoded = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        for attached in [false, true] {
            let flag = attached ? "--console-worker-attached" : "--console-worker"
            guard case .consoleWorker(let decoded, let actualStage) = try CLI.parse(arguments: [flag, encoded]) else {
                Issue.record("expected worker command"); return
            }
            #expect(decoded.identity == options.identity && attached == actualStage)
            #expect(throws: (any Error).self) { try CLI.parse(arguments: [flag]) }
            #expect(throws: (any Error).self) { try CLI.parse(arguments: [flag, encoded, "extra"]) }
        }
        // Neither an internal flag nor a root UID in JSON grants a session.
        #expect(VNCConsoleVerify(options.identity.native) != 0)
    }

    @Test func connectedVNCClientSurvivesBlankingAndWorkerReplacement() throws {
        let identity = IdentityBox()
        let desktop = ConsoleDesktop(fps: 60, identify: { identity.get() })
        let (firstWorker, firstPeer) = try pair()
        defer { desktop.invalidate(); firstPeer.shutdown() }
        let first = desktop.begin(identity.get()!, transport: firstWorker)
        let original = exampleFrame(value: 91)
        try desktop.publish(ConsoleFrameInfo(original), pixels: original.bgra, generation: first)
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let socket = try ClientSocket(fd: fds[0]), viewer = try ClientSocket(fd: fds[1])
        for fd in fds {
            var enabled: Int32 = 1
            try #require(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0)
        }
        let session = try RFBClientSession(socket: socket, password: nil, fps: 60, encodingPreference: .raw,
            capture: desktop, input: desktop.makeInput(), clipboard: ConsoleClipboard(), clipboardSync: false,
            adaptiveStreaming: false, adaptiveFrameRate: false, logger: ServerLogger(verbose: false), allowEncryption: false)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { completed.signal() }
            try? session.run()
        }
        defer {
            viewer.shutdown(); session.shutdown()
            #expect(completed.wait(timeout: .now() + 3) == .success)
        }
        try viewer.withReadTimeout(3, operation: "console test handshake") {
            _ = try viewer.readExact(12)
            try viewer.writeAll(Array("RFB 003.008\n".utf8))
            let count = Int(try viewer.readExact(1)[0])
            #expect(try viewer.readExact(count).contains(1))
            try viewer.writeAll([1])
            #expect(try viewer.readExact(4) == [0, 0, 0, 0])
            try viewer.writeAll([1])
            let header = try viewer.readExact(24)
            let length = header[20..<24].reduce(0) { $0 << 8 | Int($1) }
            _ = try viewer.readExact(length)
            try viewer.writeAll([2, 0, 0, 1, 0, 0, 0, 0]) // Raw encoding
        }
        func nextPixels() throws -> [UInt8] {
            try viewer.writeAll([3, 0, 0, 0, 0, 0, 0, 4, 0, 2])
            return try viewer.withReadTimeout(3, operation: "console test frame") {
                let update = try viewer.readExact(4)
                #expect(update == [0, 0, 0, 1])
                let rectangle = try viewer.readExact(12)
                #expect(Array(rectangle[8..<12]) == [0, 0, 0, 0])
                return try viewer.readExact(32)
            }
        }
        #expect(try nextPixels()[0] == 91)
        desktop.invalidate()
        #expect(try nextPixels()[0] == 0)
        identity.set(ConsoleIdentity(uid: 0, auditID: 200))
        let (secondWorker, secondPeer) = try pair()
        defer { secondPeer.shutdown() }
        let second = desktop.begin(identity.get()!, transport: secondWorker)
        let replacement = exampleFrame(value: 27)
        try desktop.publish(ConsoleFrameInfo(replacement), pixels: replacement.bgra, generation: second)
        #expect(try nextPixels()[0] == 27)
    }

    private func pair() throws -> (ConsoleTransport, ConsoleTransport) {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (try ConsoleTransport(fd: fds[0]), try ConsoleTransport(fd: fds[1]))
    }
    private func exampleFrame(value: UInt8) -> Framebuffer {
        let display = VirtualDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 4, height: 2), pixelWidth: 4, pixelHeight: 2)
        return Framebuffer(width: 4, height: 2, bgra: [UInt8](repeating: value, count: 32),
                           layout: VirtualDisplayLayout(displays: [display], scaleOverride: 1))
    }
}

private final class IdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: ConsoleIdentity? = ConsoleIdentity(uid: 501, auditID: 100)
    func get() -> ConsoleIdentity? { lock.withLock { identity } }
    func set(_ identity: ConsoleIdentity?) { lock.withLock { self.identity = identity } }
}
