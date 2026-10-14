import CVNCSession
import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

struct AccountSessionTests {
    private let identity = ConsoleIdentity(uid: 501, auditID: 12345)

    @Test func listenerPrivilegesLimitAccountsAndRejectMixedCredentials() throws {
        let root = try AccountListenerAccess.resolve(realUID: 0, effectiveUID: 0)
        #expect(root == .allAccounts)
        #expect(root.permits(uid: 0) && root.permits(uid: 501) && root.permits(uid: 502))
        let user = try AccountListenerAccess.resolve(realUID: 501, effectiveUID: 501)
        #expect(user == .ownAccount(501))
        #expect(user.permits(uid: 501))
        #expect(!user.permits(uid: 0) && !user.permits(uid: 502))
        #expect(throws: (any Error).self) { try AccountListenerAccess.resolve(realUID: 501, effectiveUID: 0) }
        #expect(throws: (any Error).self) { try AccountListenerAccess.resolve(realUID: 0, effectiveUID: 501) }
    }

    @Test func listenerHasOneModeAndRejectsRemovedOptions() throws {
        guard case .run(let config) = try CLI.parse(arguments: []) else { Issue.record("expected listener"); return }
        #expect(config.displaySelection == .all)
        #expect(config.fileTransfer && config.clipboardSync && !config.allowEncryption)
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(!encoded.contains("password") && !encoded.contains("sessionTarget"))
        for args in [["--session", "user"], ["--session", "console"], ["--session", "listener"],
                     ["--no-password"], ["--insecure-allow-no-auth"], ["--console-worker", "{}"]] {
            #expect(throws: (any Error).self) { try CLI.parse(arguments: args) }
        }
        guard case .service(_, let arguments) = try CLI.parse(arguments: ["--service"]) else {
            Issue.record("expected service"); return
        }
        #expect(arguments.isEmpty)
    }

    @Test func rootSessionSelectsTheCurrentConsoleOwner() throws {
        let loginWindow = ConsoleIdentity(uid: 0, auditID: 7)
        #expect(try AccountAuthentication.session(uid: 0, console: { loginWindow }) == loginWindow)
        #expect(try AccountAuthentication.session(uid: 0, console: { identity }) == identity)
        let otherUser = ConsoleIdentity(uid: 502, auditID: 42)
        #expect(try AccountAuthentication.session(uid: 0, console: { otherUser }) == otherUser)
        #expect(throws: AccountSessionError.consoleUnavailable) {
            try AccountAuthentication.session(uid: 0, console: { nil })
        }
    }

    @Test func nonRootListenerRejectsRootBeforeSelectingItsOwnConsoleDesktop() throws {
        #expect(throws: (any Error).self) {
            try AccountAuthentication.sessionForVerifiedAccount(uid: 0, access: .ownAccount(501), console: {
                Issue.record("root must be rejected before resolving a desktop on a non-root listener")
                return identity
            })
        }
        #expect(try AccountAuthentication.sessionForVerifiedAccount(uid: 0, access: .allAccounts,
            console: { identity }) == identity)
    }

    @Test(arguments: [AppleRFB.version, "RFB 003.008\n", "RFB 003.007\n"])
    func unavailableRootSessionIsRejectedBeforeWorkerCreation(version: String) throws {
        let counter = AccountWorkerCounter()
        let pool = SessionWorkerPool { _ in counter.make() }
        let listener = try ListeningSocket(bindAddress: "127.0.0.1", port: 0)
        let server = SessionListener(config: accountConfig(), pool: pool) { username, password in
            guard username == "root", password == "fixture-password" else { throw RFBError.authenticationFailed }
            return try AccountAuthentication.sessionForVerifiedAccount(uid: 0, access: .allAccounts, console: { nil })
        }
        let done = DispatchSemaphore(value: 0)
        let holder = AccountTestListener(server: server, listener: listener)
        DispatchQueue.global().async {
            defer { done.signal() }
            do { try holder.server.run(listener: holder.listener) } catch { Issue.record(error) }
        }
        defer { server.stop(); #expect(done.wait(timeout: .now() + 5) == .success) }
        for password in ["wrong", "fixture-password"] {
            let viewer = try accountConnect(listener)
            defer { viewer.shutdown() }
            try beginLogin(viewer, version: version, password: password, username: "root")
            #expect(try read(viewer, 4) == UInt32(1).beBytes)
            if version == "RFB 003.008\n" {
                let header = try read(viewer, 4)
                let length = Int(UInt32.be(header[0], header[1], header[2], header[3]))
                let reason = String(decoding: try read(viewer, length), as: UTF8.self)
                if password == "fixture-password" {
                    #expect(reason == AccountSessionError.consoleUnavailable.errorDescription)
                } else {
                    #expect(!reason.contains("physical console") && !reason.contains("password was accepted"))
                }
            }
            #expect(counter.created == 0)
        }
    }

    @Test func credentialVerifierReceivesBothCompleteFieldsAndRejectsMalformedUTF8() throws {
        let server = try AppleAuth.Exchange(), client = try AppleAuth.Exchange()
        let key = try client.wrappingKey(peerKey: server.publicKey)
        var clear = credentials(username: "revin", password: "long-password-with-suffix")
        let encrypted = try AppleEncryption.ecb(clear, key: key, encrypt: true)
        let (result, actualKey) = try server.authenticateAccount(credentials: encrypted, peerKey: client.publicKey) { name, password in
            #expect(name == "revin")
            #expect(password == "long-password-with-suffix")
            return 501
        }
        #expect(result == 501 && actualKey == key)
        clear[0] = 0xff
        let invalid = try AppleEncryption.ecb(clear, key: key, encrypt: true)
        #expect(throws: (any Error).self) {
            try server.authenticateAccount(credentials: invalid, peerKey: client.publicKey) { _, _ in
                Issue.record("malformed username reached verifier"); return 0
            }
        }
        #expect(throws: (any Error).self) {
            try server.authenticateAccount(credentials: encrypted, peerKey: client.publicKey) { _, _ -> Int in
                throw RFBError.authenticationFailed
            }
        }
    }

    @Test func descriptorsCrossARealChildProcessWithoutRelayingClientTraffic() throws {
        let (channel, childInput) = try SessionChannel.pair()
        defer { channel.shutdown(); try? childInput.close() }
        let (original, viewer) = try accountSocketPair()
        defer { viewer.shutdown() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", """
        import array, json, os, socket, struct
        control = socket.socket(fileno=0)
        marker, ancillary, flags, address = control.recvmsg(1, socket.CMSG_SPACE(4))
        assert marker == b'F' and len(ancillary) == 1
        descriptors = array.array('i'); descriptors.frombytes(ancillary[0][2])
        def read(n):
            data = b''
            while len(data) < n:
                part = control.recv(n-len(data))
                assert part
                data += part
            return data
        admission = json.loads(read(struct.unpack('!I', read(4))[0]))
        assert admission['identity']['uid'] == 501
        peer = socket.socket(fileno=descriptors[0]); peer.settimeout(3)
        peer.sendall(struct.pack('!I', os.getpid()))
        assert peer.recv(4) == b'ping'
        peer.sendall(b'pong')
        """]
        child.standardInput = childInput
        try child.run()
        try childInput.close()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        try channel.send(client: original, admission: SessionAdmission(identity: identity, version: AppleRFB.version, wrappingKey: Array(repeating: 7, count: 16)))
        let pid = try viewer.withReadTimeout(5, operation: "child reply") { try viewer.readExact(4) }
        #expect(UInt32.be(pid[0], pid[1], pid[2], pid[3]) == UInt32(child.processIdentifier))
        try viewer.writeAll(Array("ping".utf8))
        #expect(try viewer.withReadTimeout(5, operation: "child echo") { try viewer.readExact(4) } == Array("pong".utf8))
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
    }

    @Test func handoffDescriptorSurvivesListenerCloseAndRejectsMissingRights() throws {
        let (sender, child) = try SessionChannel.pair()
        let receiver = try SessionChannel(fd: dup(child.fileDescriptor))
        try child.close()
        defer { sender.shutdown(); receiver.shutdown() }
        var original: ClientSocket?
        let viewer: ClientSocket
        (original, viewer) = try accountSocketPair()
        defer { viewer.shutdown() }
        let admission = SessionAdmission(identity: identity, version: AppleRFB.version, wrappingKey: Array(repeating: 1, count: 16))
        try sender.send(client: #require(original), admission: admission)
        original = nil // close, never shutdown, after passing ownership
        let (transferred, received) = try #require(try receiver.receive(timeout: 1))
        #expect(received.identity == identity)
        #expect(fcntl(transferred.fd, F_GETFD) & FD_CLOEXEC != 0)
        try transferred.writeAll([42])
        #expect(try viewer.withReadTimeout(1, operation: "handoff") { try viewer.readExact(1) } == [42])
        try sender.socket.writeAll([70]) // marker without SCM_RIGHTS is invalid
        #expect(throws: (any Error).self) { try receiver.receive(timeout: 1) }
        #expect(throws: (any Error).self) { try admission.validate(for: ConsoleIdentity(uid: 0, auditID: 12345)) }
    }

    @Test func simultaneousAdmissionsShareOneWorkerAndShutdownPreventsRespawn() throws {
        let factory = AccountWorkerCounter()
        let pool = SessionWorkerPool { _ in factory.make() }
        let (client, peer) = try accountSocketPair()
        defer { client.shutdown(); peer.shutdown(); pool.stop() }
        let admission = SessionAdmission(identity: identity, version: AppleRFB.version, wrappingKey: Array(repeating: 0, count: 16))
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do { try pool.handOff(client: client, admission: admission) }
            catch { Issue.record(error) }
        }
        #expect(factory.created == 1 && factory.latest.sent == 16)
        factory.latest.stop()
        try pool.handOff(client: client, admission: admission)
        #expect(factory.created == 2)
        pool.stop()
        #expect(throws: (any Error).self) { try pool.handOff(client: client, admission: admission) }
        #expect(factory.created == 2 && !factory.latest.isRunning)
    }

    @Test(arguments: [AppleRFB.version, "RFB 003.008\n", "RFB 003.007\n"])
    func rootAndUserLoginsShareTheConsoleUsersWorkerAndStreamDirectly(version: String) throws {
        let identity = identity
        let worker = try AccountDirectWorker()
        let counter = AccountWorkerCounter()
        let pool = SessionWorkerPool { selected in
            #expect(selected == identity, "both accounts must select the console user's worker, never a UID 0 worker")
            _ = counter.make(); return worker
        }
        let listener = try ListeningSocket(bindAddress: "127.0.0.1", port: 0)
        let server = SessionListener(config: accountConfig(), pool: pool) { username, password in
            guard password == "fixture-password" else { throw RFBError.authenticationFailed }
            switch username {
            case "root": return try AccountAuthentication.sessionForVerifiedAccount(uid: 0, access: .allAccounts,
                console: { identity })
            case "revin": return identity
            default: throw RFBError.authenticationFailed
            }
        }
        let done = DispatchSemaphore(value: 0)
        let holder = AccountTestListener(server: server, listener: listener)
        DispatchQueue.global().async { defer { done.signal() }; do { try holder.server.run(listener: holder.listener) } catch { Issue.record(error) } }
        defer { server.stop(); #expect(done.wait(timeout: .now() + 5) == .success) }

        let failed = try accountConnect(listener)
        defer { failed.shutdown() }
        try beginLogin(failed, version: version, password: "wrong", username: "root")
        #expect(try read(failed, 4) == UInt32(1).beBytes)
        #expect(counter.created == 0)

        let first = try accountConnect(listener), second = try accountConnect(listener)
        defer { first.shutdown(); second.shutdown() }
        for (viewer, username) in zip([first, second], ["root", "revin"]) {
            try beginLogin(viewer, version: version, password: "fixture-password", username: username)
            #expect(try read(viewer, 4) == UInt32(0).beBytes)
            try viewer.writeAll([version == AppleRFB.version ? 0xc1 : 1])
            let initBytes = try read(viewer, 24)
            #expect(Array(initBytes.prefix(4)) == [0, 2, 0, 1])
            let length = Int(UInt32.be(initBytes[20], initBytes[21], initBytes[22], initBytes[23]))
            _ = try read(viewer, length)
            try viewer.writeAll([2, 0, 0, 1] + UInt32(0).beBytes)
            try viewer.writeAll([3, 0, 0, 0, 0, 0, 0, 2, 0, 1])
            let frame = try read(viewer, 24) // update + raw rectangle + 8 pixel bytes
            #expect(Array(frame.suffix(8)) == [9, 8, 7, 0, 6, 5, 4, 0])
        }
        #expect(counter.created == 1)
        #expect(worker.server.activeClientCount == 2)
        first.shutdown()
        try second.writeAll([3, 0, 0, 0, 0, 0, 0, 2, 0, 1])
        #expect(try read(second, 24).suffix(8) == [9, 8, 7, 0, 6, 5, 4, 0])
    }

    @Test func reapingDoesNotBlockAcceptsBehindWorkerStartup() throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0), reaped = DispatchSemaphore(value: 0)
        let pool = SessionWorkerPool { _ in
            started.signal(); _ = release.wait(timeout: .now() + 3)
            return AccountCountingWorker()
        }
        let (client, viewer) = try accountSocketPair()
        defer { client.shutdown(); viewer.shutdown(); pool.stop() }
        let admission = SessionAdmission(identity: identity, version: AppleRFB.version, wrappingKey: Array(repeating: 0, count: 16))
        DispatchQueue.global().async {
            defer { completed.signal() }
            do { try pool.handOff(client: client, admission: admission) } catch { Issue.record(error) }
        }
        #expect(started.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global().async { pool.reap(); reaped.signal() }
        let result = reaped.wait(timeout: .now() + 0.5)
        release.signal()
        #expect(result == .success)
        #expect(completed.wait(timeout: .now() + 2) == .success)
    }

    @Test func accountInputWorksWithoutEncryptingFramebufferTraffic() throws {
        let identity = identity
        let worker = try AccountDirectWorker()
        let pool = SessionWorkerPool { _ in worker }
        let listener = try ListeningSocket(bindAddress: "127.0.0.1", port: 0)
        let server = SessionListener(config: accountConfig(), pool: pool) { username, password in
            guard username == "revin", password == "fixture-password" else { throw RFBError.authenticationFailed }
            return identity
        }
        let done = DispatchSemaphore(value: 0)
        let holder = AccountTestListener(server: server, listener: listener)
        DispatchQueue.global().async { defer { done.signal() }; do { try holder.server.run(listener: holder.listener) } catch { Issue.record(error) } }
        defer { server.stop(); #expect(done.wait(timeout: .now() + 5) == .success) }
        let viewer = try accountConnect(listener)
        defer { viewer.shutdown() }
        let key = try beginLogin(viewer, version: AppleRFB.version, password: "fixture-password")
        #expect(try read(viewer, 4) == UInt32(0).beBytes)
        try viewer.writeAll([0xc1])
        let header = try read(viewer, 24)
        let length = Int(UInt32.be(header[20], header[21], header[22], header[23]))
        let name = try read(viewer, length)
        #expect(AppleRFB.supports(0x10, bitmap: Array(name[6..<22])), "account input is independent of file transfer")
        try viewer.writeAll([2, 0, 0, 1] + UInt32(0).beBytes)

        func event(down: Bool) throws -> [UInt8] {
            // A single type-30 input envelope carries both key and pointer.
            // Apple's right button (2) must reach the input bridge as RFB 4.
            let clear: [UInt8] = [0xff, down ? 1 : 0, 0, 0, 0, 0x61, 0, 0, 0, 0,
                                  0xff, down ? 2 : 0, 0, 1, 0, 0]
            return try [0x10, 0] + AppleEncryption.ecb(clear, key: key, encrypt: true)
        }
        let update: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 2, 0, 1]
        let down = try event(down: true), up = try event(down: false)
        try viewer.writeAll([0x0a, 0, 0, 1] + down + up + update)
        // No record ciphers are installed in this client. Reading raw pixels
        // also proves the input messages completed without losing framing.
        #expect(try read(viewer, 24).suffix(8) == [9, 8, 7, 0, 6, 5, 4, 0])
        #expect(worker.input.events == ["key:97:down", "pointer:4:1:0", "key:97:up", "pointer:0:1:0"])
        try viewer.writeAll([0x0a, 0, 0, 0] + down + up + update)
        _ = try read(viewer, 24)
        #expect(worker.input.events.count == 4, "Observe mode must still suppress authenticated input")
        #expect(worker.server.activeClientCount == 1)
    }

    private func credentials(username: String, password: String) -> [UInt8] {
        var clear = [UInt8](repeating: 0, count: 128)
        clear.replaceSubrange(0..<username.utf8.count, with: username.utf8)
        clear.replaceSubrange(64..<(64 + password.utf8.count), with: password.utf8)
        return clear
    }
    private func read(_ socket: ClientSocket, _ count: Int) throws -> [UInt8] {
        try socket.withReadTimeout(5, operation: "account test") { try socket.readExact(count) }
    }
    @discardableResult
    private func beginLogin(_ socket: ClientSocket, version: String, password: String, username: String = "revin") throws -> [UInt8] {
        #expect(String(decoding: try read(socket, 12), as: UTF8.self) == AppleRFB.version)
        try socket.writeString(version)
        #expect(try read(socket, 2) == [1, 30])
        try socket.writeAll([30])
        let challenge = try read(socket, 4 + 512)
        #expect(Array(challenge.prefix(4)) == [0, 2, 1, 0])
        let client = try AppleAuth.Exchange()
        let key = try client.wrappingKey(peerKey: Array(challenge.suffix(256)))
        let encrypted = try AppleEncryption.ecb(credentials(username: username, password: password), key: key, encrypt: true)
        try socket.writeAll(encrypted + client.publicKey)
        return key
    }
}

private func accountConfig() -> ServerConfig {
    ServerConfig(bindAddress: "127.0.0.1", port: 0,
        fps: 30, scale: 1, encodingPreference: .raw, displaySelection: .all, verbose: false,
        clipboardSync: false, adaptiveStreaming: false, adaptiveFrameRate: false,
        fileTransfer: false)
}
private func accountSocketPair() throws -> (ClientSocket, ClientSocket) {
    var fds: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    return (try ClientSocket(fd: fds[0]), try ClientSocket(fd: fds[1]))
}
private func accountConnect(_ listener: ListeningSocket) throws -> ClientSocket {
    var address = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
    try #require(withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener.fd, $0, &size) }
    } == 0)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard withUnsafePointer(to: &address, {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
    }) == 0 else { close(fd); throw RFBError.socketError("test connect failed") }
    let client = try ClientSocket(fd: fd)
    try client.configureTCP()
    return client
}
private final class AccountTestListener: @unchecked Sendable {
    let server: SessionListener; let listener: ListeningSocket
    init(server: SessionListener, listener: ListeningSocket) { self.server = server; self.listener = listener }
}
private final class AccountWorkerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var workers: [AccountCountingWorker] = []
    var created: Int { lock.withLock { workers.count } }
    var latest: AccountCountingWorker { lock.withLock { workers.last! } }
    func make() -> AccountCountingWorker {
        lock.withLock { let worker = AccountCountingWorker(); workers.append(worker); return worker }
    }
}
private final class AccountCountingWorker: SessionWorkerConnection, @unchecked Sendable {
    private(set) var isRunning = true
    private(set) var sent = 0
    func send(client: ClientSocket, admission: SessionAdmission) { sent += 1 }
    func stop() { isRunning = false }
}
private final class AccountDirectWorker: SessionWorkerConnection, @unchecked Sendable {
    let server: RFBServer
    let input = AccountTestInput()
    let sender: SessionChannel
    let receiver: SessionChannel
    var isRunning = true
    init() throws {
        let (sender, child) = try SessionChannel.pair()
        self.sender = sender; receiver = try SessionChannel(fd: dup(child.fileDescriptor))
        try child.close()
        let input = SharedInputController(input: self.input)
        server = RFBServer(config: accountConfig(), capture: AccountTestFrame(),
            makeInput: { input.makeClient() }, makeClipboard: { DisabledClipboard() }, logger: ServerLogger(verbose: false))
    }
    func send(client: ClientSocket, admission: SessionAdmission) throws {
        try sender.send(client: client, admission: admission)
        let (socket, received) = try #require(try receiver.receive(timeout: 1))
        server.serve(client: socket, admission: received)
    }
    func stop() { isRunning = false; sender.shutdown(); receiver.shutdown(); server.stop(); server.waitForClients() }
}
private struct AccountTestFrame: FramebufferSource {
    var includesCursor: Bool { true }
    func capture() -> Framebuffer {
        Framebuffer(width: 2, height: 1, bgra: [9, 8, 7, 0, 6, 5, 4, 0],
            layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1))
    }
}
private final class AccountTestInput: InputController, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {
        lock.withLock { recorded.append("key:\(keysym):\(down ? "down" : "up")") }
    }
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {
        lock.withLock { recorded.append("pointer:\(buttonMask):\(x):\(y)") }
    }
    func releaseKeys() {}
}
