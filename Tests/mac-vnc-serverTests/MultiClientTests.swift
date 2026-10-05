import AppKit
import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

@Suite(.serialized)
struct MultiClientTests {
    @Test func twoClientsAuthenticateAndStreamWithIndependentEncodingState() throws {
        let server = try MultiClientServer()
        defer { server.finish() }
        let first = try server.connect()
        defer { first.finish() }
        _ = try first.handshake(version: AppleRFB.version)
        let second = try server.connect()
        defer { second.finish() }
        // Even an exclusive ClientInit must not evict the established viewer.
        _ = try second.handshake(version: AppleRFB.version, shared: false)
        try first.write([2, 0, 0, 1, 0, 0, 0, 6])
        try second.write([2, 0, 0, 1, 0, 0, 0, 0])
        var compressed: [[UInt8]] = []
        for _ in 0..<2 {
            try first.write(fullUpdate)
            try second.write(fullUpdate)
            compressed.append(try framePayload(first, encoding: 6))
            #expect(try framePayload(second, encoding: 0) == [UInt8](repeating: 0, count: 8))
        }
        try second.write([2, 0, 0, 1, 0, 0, 0, 6])
        var otherCompressed: [[UInt8]] = []
        for _ in 0..<2 {
            try second.write(fullUpdate)
            try first.write(fullUpdate)
            otherCompressed.append(try framePayload(second, encoding: 6))
            compressed.append(try framePayload(first, encoding: 6))
        }
        #expect(try inflatePayloads(compressed, outputCounts: [8, 8, 8, 8]) == [UInt8](repeating: 0, count: 32))
        first.finish()
        try second.write(fullUpdate)
        otherCompressed.append(try framePayload(second, encoding: 6))
        #expect(try inflatePayloads(otherCompressed, outputCounts: [8, 8, 8]) == [UInt8](repeating: 0, count: 24))
    }

    @Test func pixelFormatsBelongToEachClient() throws {
        let server = try MultiClientServer()
        defer { server.finish() }
        let first = try server.connect()
        defer { first.finish() }
        let second = try server.connect()
        defer { second.finish() }
        for peer in [first, second] { _ = try peer.handshake(version: AppleRFB.version) }
        let rgb565 = PixelFormat(bitsPerPixel: 16, depth: 16, bigEndian: false, trueColor: true,
            redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0)
        try second.write([0, 0, 0, 0] + rgb565.bytes)
        try second.write(fullUpdate)
        try first.write(fullUpdate)
        #expect(try framePayload(second, encoding: 0, pixelBytes: 4).count == 4)
        #expect(try framePayload(first, encoding: 0).count == 8)
    }

    @Test func clipboardChangesReachBothAppleClientsAndRemoteEchoesStop() throws {
        let server = try MultiClientServer()
        defer { server.finish() }
        let first = try server.connect()
        defer { first.finish() }
        let second = try server.connect()
        defer { second.finish() }
        for peer in [first, second] {
            _ = try peer.handshake(version: AppleRFB.version)
            try peer.enableAppleClipboard()
        }
        server.clipboard.setRemoteText("server → both 中文")
        for peer in [first, second] {
            #expect(try peer.read(8) == changedStatus)
            try fetch(peer)
            #expect(try peer.readClipboard().1 == .text("server → both 中文"))
        }
        try first.write(AppleClipboard.message(text: "first → second ✓", requestID: 7))
        try fetch(first)
        #expect(try first.readClipboard().1 == .text("first → second ✓"))
        #expect(try second.read(8) == changedStatus)
        try fetch(second)
        #expect(try second.readClipboard().1 == .text("first → second ✓"))
        try second.write(AppleClipboard.message(text: "first → second ✓", requestID: 8))
        try fetch(second)
        #expect(try second.readClipboard().1 == .text("first → second ✓"))
        #expect(!first.hasData(timeout: 0.2))
        #expect(!second.hasData(timeout: 0.2))
        try first.write(AppleClipboard.message(text: "", requestID: 9))
        #expect(try second.read(8) == changedStatus)
        try fetch(second)
        #expect(try second.readClipboard().1 == .text(""))
    }

    @Test func appleAndClassicClientsShareClipboardOnOnePort() throws {
        let server = try MultiClientServer()
        defer { server.finish() }
        let apple = try server.connect()
        defer { apple.finish() }
        _ = try apple.handshake(version: AppleRFB.version)
        try apple.enableAppleClipboard()
        let classic = try server.connect()
        defer { classic.finish() }
        _ = try classic.handshake(version: "RFB 003.008\n")
        server.clipboard.setRemoteText("both")
        #expect(try apple.read(8) == changedStatus)
        #expect(try classic.read(4) == [3, 0, 0, 0])
        #expect(try classic.read(Int(classic.number())) == Array("both".utf8))
        try classic.write([6, 0, 0, 0, 0, 0, 0, 7] + Array("classic".utf8))
        #expect(try apple.read(8) == changedStatus)
        try fetch(apple)
        #expect(try apple.readClipboard().1 == .text("classic"))
        #expect(!classic.hasData(timeout: 0.2))
    }

    @Test func stalledHandshakeExpiresWithoutBlockingAnotherClient() throws {
        let server = try MultiClientServer(handshakeTimeout: 0.8)
        defer { server.finish() }
        let silent = try server.connect()
        defer { silent.finish() }
        #expect(try silent.read(12) == Array(AppleRFB.version.utf8))
        let active = try server.connect()
        defer { active.finish() }
        _ = try active.handshake(version: AppleRFB.version)
        try active.write(fullUpdate)
        #expect(try framePayload(active, encoding: 0).count == 8)
        #expect(throws: (any Error).self) { try silent.read(1) }
        // Established sessions have no handshake deadline or idle read timeout.
        try active.write(fullUpdate)
        #expect(try framePayload(active, encoding: 0).count == 8)
    }

    @Test func clientLimitRejectsOnlyTheExtraConnection() throws {
        let server = try MultiClientServer(maximumClients: 2)
        defer { server.finish() }
        let first = try server.connect()
        defer { first.finish() }
        _ = try first.handshake(version: AppleRFB.version)
        let second = try server.connect()
        defer { second.finish() }
        _ = try second.handshake(version: AppleRFB.version)
        let extra = try server.connect()
        defer { extra.finish() }
        #expect(throws: (any Error).self) { try extra.read(1) }
        for peer in [first, second] {
            try peer.write(fullUpdate)
            #expect(try framePayload(peer, encoding: 0).count == 8)
        }
    }

    @Test func failedAuthenticationAndDisconnectLeaveOtherClientWorking() throws {
        let server = try MultiClientServer()
        defer { server.finish() }
        let good = try server.connect()
        defer { good.finish() }
        _ = try good.handshake(version: AppleRFB.version)
        let bad = try server.connect()
        defer { bad.finish() }
        _ = try bad.read(12)
        try bad.write(Array(AppleRFB.version.utf8))
        #expect(try bad.read(2) == [1, 2])
        _ = try bad.read(16)
        try bad.write([UInt8](repeating: 0, count: 16))
        #expect(try bad.number() == 1)
        #expect(throws: (any Error).self) { try bad.read(1) }
        try good.write(fullUpdate)
        #expect(try framePayload(good, encoding: 0).count == 8)
    }

    @Test func clipboardClearingAlsoRemovesNonTextContents() {
        let board = NSPasteboard(name: .init("mac-vnc-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let first = MacClipboard(pasteboard: board)
        let second = MacClipboard(pasteboard: board)
        board.setData(Data([1, 2]), forType: .png)
        first.setRemoteText("")
        #expect(board.data(forType: .png) == nil)
        #expect(second.localTextIfChanged() == "")
        #expect(first.localTextIfChanged() == nil)
        first.setRemoteText("same")
        #expect(second.localTextIfChanged() == "same")
        second.setRemoteText("same")
        #expect(first.localTextIfChanged() == nil)
    }

    @Test func observeAndDisconnectReleaseOnlyThatSessionsInput() throws {
        let server = try MultiClientServer()
        defer { server.finish() }
        let first = try server.connect()
        defer { first.finish() }
        let second = try server.connect()
        defer { second.finish() }
        for peer in [first, second] {
            _ = try peer.handshake(version: AppleRFB.version)
            try peer.write([4, 1, 0, 0, 0, 0, 0, 0x61, 5, 1, 0, 0, 0, 0])
            try fetch(peer)
            _ = try peer.readClipboard()
        }
        #expect(server.input.snapshot.keyTransitions == [true])
        #expect(server.input.snapshot.mask == 1)
        // Observe mode is a release for this client; the second still owns both.
        try first.write([0x0a, 0, 0, 0])
        try first.write(fullUpdate)
        _ = try framePayload(first, encoding: 0)
        #expect(server.input.snapshot.keyTransitions == [true])
        #expect(server.input.snapshot.mask == 1)
        first.finish()
        try fetch(second)
        _ = try second.readClipboard()
        #expect(server.input.snapshot.keyTransitions == [true])
        // The remaining client's releases finally lift the physical controls.
        try second.write([4, 0, 0, 0, 0, 0, 0, 0x61, 5, 0, 0, 0, 0, 0])
        try fetch(second)
        _ = try second.readClipboard()
        #expect(server.input.snapshot.keyTransitions == [true, false])
        #expect(server.input.snapshot.mask == 0)
    }

    @Test func stoppingServerDisconnectsActiveAndPendingHandshakes() throws {
        let server = try MultiClientServer()
        defer { server.finish() }
        let active = try server.connect()
        defer { active.finish() }
        _ = try active.handshake(version: AppleRFB.version)
        let pending = try server.connect()
        defer { pending.finish() }
        _ = try pending.read(12)
        server.server.stop()
        #expect(throws: (any Error).self) { try active.read(1) }
        #expect(throws: (any Error).self) { try pending.read(1) }
    }

    private var fullUpdate: [UInt8] { [3, 0, 0, 0, 0, 0, 0, 2, 0, 1] }
    private var changedStatus: [UInt8] { [0x14, 0, 0, 4, 0, 1, 0, 2] }
    private func fetch(_ peer: ClipboardTestPeer) throws {
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 1])
    }
    private func framePayload(_ peer: ClipboardTestPeer, encoding: UInt32, pixelBytes: Int = 8) throws -> [UInt8] {
        #expect(try peer.read(4) == [0, 0, 0, 1])
        #expect(try peer.read(8) == [0, 0, 0, 0, 0, 2, 0, 1])
        #expect(try peer.number() == encoding)
        if encoding == 6 {
            let count = try peer.number()
            return try count.beBytes + peer.read(Int(count))
        }
        return try peer.read(pixelBytes)
    }
}

private final class MultiClientServer: @unchecked Sendable {
    let server: RFBServer
    let clipboard: MacClipboard
    let board: NSPasteboard
    let port: UInt16
    let input = MultiClientInput()
    private let done = DispatchSemaphore(value: 0)

    init(maximumClients: Int = 32, handshakeTimeout: TimeInterval = 10) throws {
        let name = "mac-vnc-test-\(UUID())"
        board = NSPasteboard(name: .init(name))
        clipboard = MacClipboard(pasteboard: board)
        let listener = try ListeningSocket(bindAddress: "127.0.0.1", port: 0)
        var address = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener.fd, $0, &size) }
        }
        guard status == 0 else { throw RFBError.socketError("test getsockname failed") }
        port = UInt16(bigEndian: address.sin_port)
        let config = ServerConfig(bindAddress: "127.0.0.1", port: port, password: "testpass",
            passwordFromConfig: false, fps: 30, scale: 1, encodingPreference: .auto,
            displaySelection: .all, verbose: false, clipboardSync: true,
            adaptiveStreaming: false, adaptiveFrameRate: false)
        let inputs = SharedInputController(input: input)
        server = RFBServer(config: config, capture: MultiClientScreen(),
            makeInput: { inputs.makeClient() },
            makeClipboard: { MacClipboard(pasteboard: NSPasteboard(name: .init(name))) },
            logger: ServerLogger(verbose: false), maximumClients: maximumClients,
            handshakeTimeout: handshakeTimeout)
        // The listener is owned by this worker once created.
        let worker = MultiClientListener(server: server, listener: listener, done: done)
        DispatchQueue.global().async { worker.run() }
    }

    func connect() throws -> ClipboardTestPeer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RFBError.socketError("test socket failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else { close(fd); throw RFBError.socketError("test connect failed") }
        var flag: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, socklen_t(MemoryLayout<Int32>.size))
        return ClipboardTestPeer(socket: try ClientSocket(fd: fd))
    }

    func finish() {
        server.stop()
        #expect(done.wait(timeout: .now() + 3) == .success)
        board.releaseGlobally()
    }
}

private final class MultiClientListener: @unchecked Sendable {
    let server: RFBServer
    let listener: ListeningSocket
    let done: DispatchSemaphore
    init(server: RFBServer, listener: ListeningSocket, done: DispatchSemaphore) {
        self.server = server; self.listener = listener; self.done = done
    }
    func run() {
        defer { done.signal() }
        do { try server.run(listener: listener) }
        catch { Issue.record(error) }
    }
}

private struct MultiClientScreen: FramebufferSource {
    func capture() throws -> Framebuffer {
        Framebuffer(width: 2, height: 1, bgra: [0, 0, 0, 255, 0, 0, 0, 255],
            layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1))
    }
}

private final class MultiClientInput: InputController {
    struct Snapshot {
        var keyTransitions: [Bool] = []
        var mask: UInt8 = 0
    }
    private let lock = NSLock()
    private var state = Snapshot()
    var snapshot: Snapshot { lock.withLock { state } }
    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {
        lock.withLock { state.keyTransitions.append(down) }
    }
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {
        lock.withLock { state.mask = buttonMask }
    }
    func releaseKeys() {}
}
