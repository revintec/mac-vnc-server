import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

// The fixture runs blocking socket reader/writer threads, like the real server.
// Serialize fixtures so the test runner cannot exhaust the shared worker pool.
@Suite(.serialized)
struct AppleClipboardTests {

@Test func appleArchiveMatchesIndependentTextWireLayout() throws {
    // One item, one 22-byte UTI, reserved, tag count, counted UTF-8 text.
    let expected: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 22]
        + Array("public.utf8-plain-text".utf8)
        + [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0x68, 0xc3, 0xa9]
    #expect(try AppleClipboard.archive(text: "hé") == expected)
    #expect(try AppleClipboard.parseArchive(expected) == .text("hé"))
    #expect(try AppleClipboard.archive(text: "") == [0, 0, 0, 0])
    #expect(try AppleClipboard.parseArchive([]) == .text(""))
    #expect(try AppleClipboard.parseArchive([0, 0, 0, 0]) == .text(""))
    #expect(try AppleClipboard.parseArchive(AppleClipboard.archive(text: "x", promises: true)) == .promisedText)
}

@Test func appleClipboardArchivesUseIndependentSyncFlushedStreams() throws {
    for text in ["", "你好 🌏\nsecond line\t✓", String(repeating: "abc✓", count: 20_000)] {
        let message = try AppleClipboard.message(text: text, requestID: 0x12345678)
        #expect(Array(message.prefix(8)) == [0x1f, 0, 0, 0, 0x12, 0x34, 0x56, 0x78])
        #expect(Array(message.suffix(4)) == [0, 0, 0xff, 0xff])
        let header = try AppleClipboard.Header(bytes: Array(message[1..<16]))
        #expect(header.requestID == 0x12345678)
        #expect(try AppleClipboard.decode(header: header, compressed: Array(message.dropFirst(16))) == .text(text))
    }
}

@Test func appleClipboardAcceptsHeaderOnlyEmptyArchive() throws {
    for promises: UInt8 in [0, 1] {
        // The zero-size representation has no zlib stream at all. Empty
        // archives clear the clipboard even with the promises bit set.
        let bytes = [0, promises, 0] + UInt32(17).beBytes
            + UInt32(0).beBytes + UInt32(0).beBytes
        let header = try AppleClipboard.Header(bytes: bytes)
        #expect(try AppleClipboard.decode(header: header, compressed: []) == .text(""))
    }

    // Also continue accepting an empty archive inside a real zlib stream.
    let compressed = try AppleClipboard.compress([])
    let header = try AppleClipboard.Header(bytes: [0, 0, 0] + UInt32(18).beBytes
        + UInt32(0).beBytes + UInt32(compressed.count).beBytes)
    #expect(try AppleClipboard.decode(header: header, compressed: compressed) == .text(""))
}

@Test func appleClipboardRejectsMissingCompressedDataForNonemptyArchive() throws {
    let header = try AppleClipboard.Header(bytes: [0, 0, 0] + UInt32(19).beBytes
        + UInt32(4).beBytes + UInt32(0).beBytes)
    #expect(throws: (any Error).self) {
        try AppleClipboard.decode(header: header, compressed: [])
    }
    let missingPayload = try AppleClipboard.Header(bytes: [0, 0, 0] + UInt32(20).beBytes
        + UInt32(0).beBytes + UInt32(1).beBytes)
    #expect(throws: (any Error).self) {
        try AppleClipboard.decode(header: missingPayload, compressed: [])
    }
}

@Test func appleArchiveReadsMultipleItemsTagsAndUnsupportedFlavors() throws {
    func counted(_ bytes: [UInt8]) -> [UInt8] { UInt32(bytes.count).beBytes + bytes }
    let image = counted(Array("com.example.unsupported".utf8)) + UInt32(0).beBytes + UInt32(1).beBytes
        + counted(Array("MIME".utf8)) + counted(Array("image/png".utf8)) + counted([1, 2, 3])
    let firstItem = UInt32(1).beBytes + image
    #expect(try AppleClipboard.parseArchive(firstItem) == .noText)
    #expect(try AppleClipboard.parseArchive(firstItem + AppleClipboard.archive(text: "second item")) == .text("second item"))
}

@Test func appleClipboardRejectsTruncationCountsAndInflationSizeMismatch() throws {
    let raw = try AppleClipboard.archive(text: "test")
    for count in 1..<raw.count {
        // A zero-flavor item is valid; all prefixes of this non-empty item are truncated.
        #expect(throws: (any Error).self) { try AppleClipboard.parseArchive(Array(raw.prefix(count))) }
    }
    #expect(throws: (any Error).self) { try AppleClipboard.parseArchive([0xff, 0xff, 0xff, 0xff]) }
    var invalidText = raw
    invalidText[invalidText.count - 1] = 0xff
    #expect(throws: (any Error).self) { try AppleClipboard.parseArchive(invalidText) }
    let compressed = try AppleClipboard.compress(raw)
    for size in [0, raw.count - 1, raw.count + 1, AppleClipboard.maxArchiveBytes + 1] {
        #expect(throws: (any Error).self) { try AppleClipboard.inflate(compressed, expectedSize: size) }
    }
    #expect(throws: (any Error).self) {
        try AppleClipboard.inflate(Array(compressed.dropLast()), expectedSize: raw.count)
    }
    var header = [UInt8](repeating: 0, count: 15)
    header.replaceSubrange(7..<11, with: UInt32.max.beBytes)
    #expect(throws: (any Error).self) { try AppleClipboard.Header(bytes: header) }
}

@Test func appleClipboardNegotiatesAndTransfersWithoutFramebufferRequests() throws {
    let peer = try ClipboardTestPeer()
    defer { peer.finish() }
    let name = try peer.handshake(version: AppleRFB.version)
    #expect(Array(name.prefix(6)) == [0, 0, 0, 0, 0, 0x12])
    let capabilities = Array(name[6..<22])
    for message in [0x0a, 0x0b, 0x15, 0x1f, 0x21] {
        #expect(AppleRFB.supports(message, bitmap: capabilities))
    }
    #expect(!AppleRFB.supports(0x12, bitmap: capabilities)) // no record encryption
    #expect(String(decoding: name.dropFirst(22), as: UTF8.self) == "mac-vnc-server")
    try peer.enableAppleClipboard()
    peer.clipboard.copyLocal("Tahoe → Ventura 中文\n🌏")
    #expect(try peer.read(8) == [0x14, 0, 0, 4, 0, 1, 0, 2])
    try peer.write([0x0b, 0, 0, 0, 0x12, 0x34, 0x56, 0x78])
    let (header, text) = try peer.readClipboard()
    #expect(header.requestID == 0x12345678)
    #expect(text == .text("Tahoe → Ventura 中文\n🌏"))

    try peer.write(AppleClipboard.message(text: "client → server ✓", requestID: 17))
    // A fetch is a barrier after the received pasteboard has been applied.
    try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 19])
    let (_, received) = try peer.readClipboard()
    #expect(received == .text("client → server ✓"))
    #expect(peer.clipboard.currentText() == "client → server ✓")
    #expect(!peer.hasData(timeout: 0.25)) // remote writes must not echo notifications

    try peer.write(AppleClipboard.message(text: "", requestID: 20))
    try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 21])
    #expect(try peer.readClipboard().1 == .text(""))
}

@Test func appleClipboardHandlesPromisesAndStoppedMonitoring() throws {
    let peer = try ClipboardTestPeer()
    defer { peer.finish() }
    _ = try peer.handshake(version: AppleRFB.version)
    try peer.enableAppleClipboard()
    try peer.write(AppleClipboard.message(text: "promised", requestID: 0, promises: true))
    #expect(try peer.read(8) == [0x14, 0, 0, 4, 0, 1, 0, 3])
    #expect(peer.clipboard.currentText() == "initial")
    try peer.write(AppleClipboard.message(text: "promised", requestID: 0))
    try peer.write([0x0b, 1, 0, 0, 0, 0, 0, 31])
    let (header, contents) = try peer.readClipboard()
    #expect(header.promises)
    #expect(contents == .promisedText)
    try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 32])
    #expect(try peer.readClipboard().1 == .text("promised"))

    try peer.write([0x15, 0, 0, 2, 0, 0, 0, 0])
    try peer.write([0x0b, 1, 0, 0, 0, 0, 0, 33])
    let (stoppedHeader, stoppedContents) = try peer.readClipboard()
    #expect(!stoppedHeader.promises)
    #expect(stoppedContents == .text("promised"))
    peer.clipboard.copyLocal("changed while stopped")
    #expect(!peer.hasData(timeout: 0.25))
    try peer.write([0x15, 0, 0, 1, 0, 0, 0, 0])
    #expect(try peer.read(8) == [0x14, 0, 0, 4, 0, 1, 0, 2])
}

@Test func appleClipboardRepeatedStartDoesNotAnnounceUnchangedServerText() throws {
    let peer = try ClipboardTestPeer()
    defer { peer.finish() }
    _ = try peer.handshake(version: AppleRFB.version)
    try peer.enableAppleClipboard()
    // The viewer has already fetched the server's clipboard before a local copy.
    try peer.write([0x0b, 1, 0, 0, 0, 0, 0, 40])
    #expect(try peer.readClipboard().1 == .promisedText)
    try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 41])
    #expect(try peer.readClipboard().1 == .text("initial"))

    // Reasserting an active subscription must not advertise the old server text
    // as a new copy: the viewer could overwrite its newer local screenshot.
    try peer.write([0x15, 0, 0, 1, 0, 0, 0, 0])
    #expect(!peer.hasData(timeout: 0.25))
    peer.clipboard.copyLocal("new server copy")
    #expect(try peer.read(8) == [0x14, 0, 0, 4, 0, 1, 0, 2])
    try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 42])
    #expect(try peer.readClipboard().1 == .text("new server copy"))
}

@Test func appleClipboardIgnoresUnsupportedFormatsWithoutReplyingOrClearingServerText() throws {
    for promises in [true, false] {
        let peer = try ClipboardTestPeer()
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.enableAppleClipboard()
        try peer.write([0x0b, 1, 0, 0, 0, 0, 0, 44])
        #expect(try peer.readClipboard().1 == .promisedText)
        func counted(_ bytes: [UInt8]) -> [UInt8] { UInt32(bytes.count).beBytes + bytes }
        // Both unsupported announcements and populated unsupported flavors use
        // the no-text path. The payload bytes are opaque to the server.
        let data: [UInt8] = promises ? [] : [0x89, 0x50, 0x4e, 0x47]
        let raw = UInt32(1).beBytes + counted(Array("com.example.unsupported".utf8))
            + UInt32(0).beBytes + UInt32(0).beBytes + counted(data)
        let compressed = try AppleClipboard.compress(raw)
        try peer.write([0x1f, 0, promises ? 1 : 0, 0] + UInt32(0).beBytes
            + UInt32(raw.count).beBytes + UInt32(compressed.count).beBytes + compressed)
        // SetMode provides a processing barrier without fetching the clipboard.
        try peer.write([0x0a, 0, 0, 1])
        #expect(try peer.read(8) == [0x14, 0, 0, 4, 0, 1, 0, 9])
        #expect(!peer.hasData(timeout: 0.25))
        #expect(peer.clipboard.currentText() == "initial")

        try peer.write([0x15, 0, 0, 1, 0, 0, 0, 0])
        #expect(!peer.hasData(timeout: 0.25))

        // A subsequent explicit fetch still returns the server's existing text.
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 43])
        #expect(try peer.readClipboard().1 == .text("initial"))
    }
}

@Test func appleClipboardHeaderOnlyClearDoesNotDisconnectAfterImage() throws {
    let peer = try ClipboardTestPeer()
    defer { peer.finish() }
    _ = try peer.handshake(version: AppleRFB.version)
    try peer.enableAppleClipboard()
    try peer.write([0x0b, 1, 0, 0, 0, 0, 0, 45])
    #expect(try peer.readClipboard().1 == .promisedText)

    // Reproduce the reported unsupported flavor -> zero-payload message
    // sequence, with an old server text promise still outstanding.
    let flavor = Array("public.png".utf8)
    let raw = UInt32(1).beBytes + UInt32(flavor.count).beBytes + flavor
        + UInt32(0).beBytes + UInt32(0).beBytes + UInt32(0).beBytes
    let compressed = try AppleClipboard.compress(raw)
    let imagePromise: [UInt8] = [0x1f, 0, 1, 0] + UInt32(0).beBytes
        + UInt32(raw.count).beBytes + UInt32(compressed.count).beBytes + compressed
    let emptyClipboard: [UInt8] = [0x1f, 0, 0, 0] + [UInt8](repeating: 0, count: 12)
    try peer.write(imagePromise + emptyClipboard + [0x0b, 0, 0, 0, 0, 0, 0, 46])
    #expect(try peer.read(8) == [0x14, 0, 0, 4, 0, 1, 0, 3])
    let (header, contents) = try peer.readClipboard()
    #expect(header.requestID == 46)
    #expect(contents == .text(""))
    #expect(peer.clipboard.currentText() == "")
    #expect(!peer.hasData(timeout: 0.25))

    // Continue on the same socket: no reconnect or stale initial text replay.
    try peer.write(AppleClipboard.message(text: "after clear", requestID: 0))
    try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 47])
    #expect(try peer.readClipboard().1 == .text("after clear"))
}

@Test func appleClipboardRequiresViewerStatusCapability() throws {
    let peer = try ClipboardTestPeer()
    defer { peer.finish() }
    _ = try peer.handshake(version: AppleRFB.version)
    try peer.write([0x21, 0, 0, 62] + [UInt8](repeating: 0, count: 62))
    try peer.write([0x0a, 0, 0, 1, 0x15, 0, 0, 1, 0, 0, 0, 0])
    try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 1])
    #expect(try peer.readClipboard().1 == .text("initial"))
    peer.clipboard.copyLocal("no status capability")
    #expect(!peer.hasData(timeout: 0.25))
}

@Test func appleClipboardRepliesStayBetweenCompleteFramebufferMessages() throws {
    let peer = try ClipboardTestPeer()
    defer { peer.finish() }
    _ = try peer.handshake(version: AppleRFB.version)
    try peer.enableAppleClipboard()
    try peer.write([3, 0, 0, 0, 0, 0, 0, 2, 0, 1])
    var sawFramebuffer = false
    var sawClipboard = false
    for index in 0..<20 {
        let type = try peer.read(1)[0]
        if type == 0 {
            let header = try peer.read(3)
            let count = Int(UInt16.be(header[1], header[2]))
            for _ in 0..<count {
                let rect = try peer.read(12)
                #expect(Array(rect.suffix(4)) == [0, 0, 0, 0])
                let width = Int(UInt16.be(rect[4], rect[5]))
                let height = Int(UInt16.be(rect[6], rect[7]))
                #expect(width <= 2 && height <= 1)
                _ = try peer.read(width * height * 4)
            }
            sawFramebuffer = true
        } else if type == 0x1f {
            let header = try AppleClipboard.Header(bytes: peer.read(15))
            let contents = try AppleClipboard.decode(header: header, compressed: peer.read(header.compressedSize))
            #expect(contents == .text("initial"))
            sawClipboard = true
            break
        } else {
            Issue.record("unexpected message type \(type); stream framing was lost")
            break
        }
        if index == 0 { try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 1]) }
    }
    #expect(sawFramebuffer && sawClipboard)
}

@Test func classicClipboardStillWorksWithAppleBanner() throws {
    for version in ["RFB 003.003\n", "RFB 003.007\n", "RFB 003.008\n"] {
        let peer = try ClipboardTestPeer()
        defer { peer.finish() }
        let name = try peer.handshake(version: version)
        #expect(String(decoding: name, as: UTF8.self) == "mac-vnc-server")
        peer.clipboard.copyLocal("classic text")
        #expect(try peer.read(4) == [3, 0, 0, 0])
        let count = try peer.number()
        #expect(try peer.read(Int(count)) == Array("classic text".utf8))
        try peer.write([6, 0, 0, 0, 0, 0, 0, 6] + Array("remote".utf8))
        // Wait for the receiver rather than depending on a framebuffer update.
        let deadline = Date().addingTimeInterval(2)
        while peer.clipboard.currentText() != "remote" && Date() < deadline { usleep(1_000) }
        #expect(peer.clipboard.currentText() == "remote")
    }
}

@Test func clipboardHandshakeNeverAllowsPasswordDowngrade() throws {
    let peer = try ClipboardTestPeer()
    defer { peer.finish() }
    #expect(try peer.read(12) == Array(AppleRFB.version.utf8))
    try peer.write(Array("RFB 003.008\n".utf8))
    #expect(try peer.read(2) == [1, 2])
    try peer.write([1])
    #expect(throws: (any Error).self) { try peer.read(1) }
}

@Test func clipboardHandshakeNoAuthenticationHasCorrectVersionFraming() throws {
    for version in ["RFB 003.003\n", "RFB 003.007\n", "RFB 003.008\n", AppleRFB.version] {
        let peer = try ClipboardTestPeer(password: nil)
        defer { peer.finish() }
        _ = try peer.handshake(version: version)
    }
}

@Test func applePasswordAuthenticationRejectsAnInvalidChallengeResponse() throws {
    let peer = try ClipboardTestPeer()
    defer { peer.finish() }
    _ = try peer.read(12)
    try peer.write(Array(AppleRFB.version.utf8))
    #expect(try peer.read(2) == [1, 2])
    // Apple's type-2 path has no selector byte before the challenge.
    _ = try peer.read(16)
    try peer.write([UInt8](repeating: 0, count: 16))
    #expect(try peer.number() == 1)
    #expect(throws: (any Error).self) { try peer.read(1) }
}

@Test func appleAutomaticUpdatesCanPauseWithoutStoppingClipboard() throws {
    let peer = try ClipboardTestPeer()
    defer { peer.finish() }
    _ = try peer.handshake(version: AppleRFB.version)
    try peer.enableAppleClipboard()
    let rect: [UInt8] = [0, 0, 0, 0, 0, 2, 0, 1]
    try peer.write([0x09, 0, 0, 1, 0, 0, 0, 0] + rect)
    #expect(try peer.read(4) == [0, 0, 0, 1])
    let frame = try peer.read(12)
    #expect(Array(frame.suffix(4)) == [0, 0, 0, 0])
    _ = try peer.read(8)
    try peer.write([0x09, 0, 0, 1, 0xff, 0xff, 0xff, 0xff] + rect)
    try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 1])
    #expect(try peer.readClipboard().1 == .text("initial"))
    peer.clipboard.copyLocal("clipboard while pixels paused")
    #expect(try peer.read(8) == [0x14, 0, 0, 4, 0, 1, 0, 2])
    #expect(!peer.hasData(timeout: 0.25))
}

@Test func embeddedCursorHidesOnlyANegotiatedViewerOverlay() throws {
    for encoding in [RFBPseudoEncoding.richCursor, RFBPseudoEncoding.xCursor] {
        let peer = try ClipboardTestPeer(includesCursor: true)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.enableAppleClipboard()
        let encodings = [2, 0, 0, 1] + UInt32(bitPattern: encoding).beBytes
        for _ in 0..<2 {
            try peer.write(encodings)
            #expect(try peer.read(16) == [0, 0, 0, 1] + [UInt8](repeating: 0, count: 8)
                + UInt32(bitPattern: encoding).beBytes)
        }
        // No cursor pseudo-encoding: do not inject a message the viewer cannot parse.
        try peer.write([2, 0, 0, 1, 0, 0, 0, 0])
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 1])
        #expect(try peer.readClipboard().1 == .text("initial"))
        #expect(!peer.hasData(timeout: 0.15))
    }
}

@Test func cursorFreeSourceDoesNotHideTheViewerCursor() throws {
    let peer = try ClipboardTestPeer()
    defer { peer.finish() }
    _ = try peer.handshake(version: AppleRFB.version)
    try peer.enableAppleClipboard()
    try peer.write([2, 0, 0, 1] + UInt32(bitPattern: RFBPseudoEncoding.richCursor).beBytes)
    try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 1])
    #expect(try peer.readClipboard().1 == .text("initial"))
}

}

final class ClipboardTestBridge: ClipboardBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var content = ClipboardContent.text("initial")
    private var changed = false
    func currentContent() -> ClipboardContent? { lock.withLock { content } }
    func localContentIfChanged() -> ClipboardContent? {
        lock.withLock {
            guard changed else { return nil }
            changed = false
            return content
        }
    }
    func setRemoteContent(_ value: ClipboardContent) { lock.withLock { content = value; changed = false } }
    func copyLocal(_ value: String) { copyLocal(.text(value)) }
    func copyLocal(_ value: ClipboardContent) { lock.withLock { content = value; changed = true } }
}

private struct ClipboardTestScreen: FramebufferSource {
    var includesCursor = false
    func capture() throws -> Framebuffer {
        Framebuffer(width: 2, height: 1, bgra: [0, 0, 0, 255, 0, 0, 0, 255],
                    layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 2, height: 1))
    }
}

private struct ClipboardTestInput: InputController {
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {}
    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {}
    func releaseKeys() {}
}

final class ClipboardTestPeer: @unchecked Sendable {
    let clipboard = ClipboardTestBridge()
    let socket: ClientSocket
    let password: String?
    let done = DispatchSemaphore(value: 0)
    private var ownsSession = true

    init(socket: ClientSocket, password: String? = "testpass") {
        self.socket = socket
        self.password = password
        ownsSession = false
    }

    init(password: String? = "testpass", includesCursor: Bool = false, fileTransfer: Bool = false) throws {
        self.password = password
        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw RFBError.socketError("test socketpair failed")
        }
        for fd in fds {
            var enabled: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        }
        socket = try ClientSocket(fd: fds[1])
        let server = try ClientSocket(fd: fds[0])
        let session = try RFBClientSession(socket: server, password: password, fps: 30,
            encodingPreference: .raw, capture: ClipboardTestScreen(includesCursor: includesCursor), input: ClipboardTestInput(),
            clipboard: clipboard, clipboardSync: true, adaptiveStreaming: false,
            adaptiveFrameRate: false, logger: ServerLogger(verbose: false), fileTransfer: fileTransfer)
        DispatchQueue.global().async { [self] in
            defer { done.signal() }
            try? session.run()
        }
    }

    func finish() {
        socket.shutdown()
        if ownsSession { #expect(done.wait(timeout: .now() + 3) == .success) }
    }

    func write(_ bytes: [UInt8]) throws { try socket.writeAll(bytes) }

    func hasData(timeout: TimeInterval) -> Bool {
        var descriptor = pollfd(fd: socket.fd, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, Int32(timeout * 1_000)) > 0
    }

    func read(_ count: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: count)
        var offset = 0
        let deadline = Date().addingTimeInterval(3)
        while offset < count {
            guard hasData(timeout: max(0, deadline.timeIntervalSinceNow)), Date() < deadline else {
                throw RFBError.socketError("timed out waiting for test server")
            }
            let received = output.withUnsafeMutableBytes {
                Darwin.read(socket.fd, $0.baseAddress!.advanced(by: offset), count - offset)
            }
            guard received > 0 else { throw RFBError.socketError("test server disconnected") }
            offset += received
        }
        return output
    }

    func number() throws -> UInt32 {
        let bytes = try read(4)
        return UInt32.be(bytes[0], bytes[1], bytes[2], bytes[3])
    }

    func handshake(version: String, shared: Bool = true) throws -> [UInt8] {
        #expect(try read(12) == Array(AppleRFB.version.utf8))
        try write(Array(version.utf8))
        if version == "RFB 003.003\n" {
            #expect(try number() == (password == nil ? 1 : 2))
        } else {
            #expect(try read(2) == [1, password == nil ? 1 : 2])
            if version != AppleRFB.version { try write([password == nil ? 1 : 2]) }
        }
        if let password {
            let challenge = try read(16)
            try write(VNCAuth.response(challenge: challenge, password: password))
            #expect(try number() == 0)
        } else if version != "RFB 003.003\n" && version != "RFB 003.007\n" {
            #expect(try number() == 0)
        }
        try write([version == AppleRFB.version ? 0xc0 | (shared ? 1 : 0) : (shared ? 1 : 0)])
        _ = try read(20)
        return try read(Int(number()))
    }

    func enableAppleClipboard() throws {
        var viewer = [UInt8](repeating: 0, count: 66)
        viewer[0] = 0x21
        viewer[3] = 62
        viewer[5] = 1
        viewer[9] = 2
        viewer[13] = 3 // Screen Sharing 3.0
        viewer[25] = 13
        viewer[29] = 1
        viewer[36] = 0x08 // server message 20: MiscStatus
        viewer[37] = 0x01 // server message 31: ClipboardSend
        try write(viewer + [0x0a, 0, 0, 1, 0x15, 0, 0, 1, 0, 0, 0, 0])
        #expect(try read(8) == [0x14, 0, 0, 4, 0, 1, 0, 9])
        #expect(try read(8) == [0x14, 0, 0, 4, 0, 1, 0, 2])
    }

    func readClipboard() throws -> (AppleClipboard.Header, AppleClipboard.Contents) {
        #expect(try read(1) == [0x1f])
        let header = try AppleClipboard.Header(bytes: read(15))
        let contents = try AppleClipboard.decode(header: header, compressed: read(header.compressedSize))
        return (header, contents)
    }
}
