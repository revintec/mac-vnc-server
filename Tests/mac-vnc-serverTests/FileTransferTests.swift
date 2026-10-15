import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

@Suite(.serialized)
struct FileTransferTests {
    @Test func fileTransferIsEnabledByDefault() throws {
        guard case .run(let config) = try CLI.parse(arguments: ["run"]) else {
            Issue.record("expected run configuration"); return
        }
        #expect(config.fileTransfer)
        #expect(config.clipboardSync && !config.allowEncryption)
        let enabled = Array(AppleRFB.desktopName("test", fileTransfer: true)[6..<22])
        let disabled = Array(AppleRFB.desktopName("test")[6..<22])
        for message in [14, 16, 18, 32, 34] {
            #expect(AppleRFB.supports(message, bitmap: enabled))
            #expect(!AppleRFB.supports(message, bitmap: disabled))
        }
    }

    @Test(.enabled(if: NativeTransferProcess.available))
    func nativeDisplayNegotiationDoesNotWaitForAFrameRequest() throws {
        let peer = try ClipboardTestPeer(fileTransfer: true)
        defer { peer.finish() }
        let name = try peer.handshake(version: AppleRFB.version)
        #expect(AppleRFB.supports(0x12, bitmap: Array(name[6..<22])))
        // The viewer sends SetEncodings before it considers the session ready.
        // Prefer the native layout in either order, including duplicate entries
        // and a viewer advertising 1105 alone. Retain the 1101 fallback.
        let offers: [[UInt32]] = [[6, 1101], [6, 1101, 1105], [1105, 6, 1101],
                                 [1101, 1105, 1101, 1105], [6, 1105], [6, 1101]]
        for encodings in offers {
            try peer.write([2, 0] + UInt16(encodings.count).beBytes + encodings.flatMap(\.beBytes))
            #expect(try peer.read(12) == [0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 1])
            if encodings.contains(1105) {
                #expect(try peer.number() == 1105)
                #expect(try peer.read(2) == [0, 76]) // prefix excludes itself
                #expect(try peer.read(20) == [0, 5, 0, 2, 0, 1, 0, 2, 0, 1,
                                            255, 255, 255, 255, 0, 0, 0, 4, 0, 1])
                // Native density and server scale, both big-endian f64 1.0.
                #expect(try peer.read(16) == [0x3f, 0xf0, 0, 0, 0, 0, 0, 0,
                                            0x3f, 0xf0, 0, 0, 0, 0, 0, 0])
                #expect(try peer.read(4) == [0, 0, 0, 1]) // display ID
                #expect(try peer.read(16) == [0, 0, 0, 0, 0, 1, 0, 2,
                                            0, 0, 0, 0, 0, 1, 0, 2]) // logical/backing bounds
                #expect(try peer.read(20) == [0, 0, 0, 1, 32, 24, 0, 1, 0, 255,
                                            0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
            } else {
                #expect(try peer.number() == 1101)
                #expect(try peer.read(10) == [0, 2, 0, 1, 0, 0, 0, 0, 0, 1])
                #expect(try peer.read(28) == UInt32(1).beBytes + [0, 2, 0, 1]
                    + [UInt8](repeating: 0, count: 12) + UInt32(2).beBytes + UInt32(1).beBytes)
            }
            #expect(!peer.hasData(timeout: 0.05))
        }
        try peer.write([2, 0, 0, 1] + UInt32(0).beBytes)
        #expect(!peer.hasData(timeout: 0.1))
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [UInt16(2), UInt16.max])
    func unsupportedEncryptionLevelsAreRefused(level: UInt16) throws {
        let peer = try ClipboardTestPeer(fileTransfer: true)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.write([0x12, 0, 0, 1] + level.beBytes + [0, 1, 0, 0, 0, 1])
        #expect(throws: (any Error).self) { try peer.read(1) }
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [0, 0x1e, 0x20])
    func nativeViewerWithoutFileCopyBitStillRequiresDragAuthorization(missingCapability: Int) throws {
        let peer = try ClipboardTestPeer(fileTransfer: true)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        var viewer = [UInt8](repeating: 0, count: 66)
        viewer[0] = 0x21
        viewer[3] = 62
        // Screen Sharing advertises these two messages but omits FileCopy,
        // including in the native framework probe with file drops enabled.
        for message in [0x1e, 0x20] where message != missingCapability {
            viewer[34 + message / 8] |= 0x80 >> (message % 8)
        }
        let path = Array("/tmp/mac-vnc-unselected-test-file".utf8)
        let unselected = AppleFileTransfer.Message(command: 1, sessionID: 1,
            payload: [UInt8](repeating: 0, count: 8) + UInt16(path.count).beBytes + path)
        try peer.write(viewer + [0x0a, 0, 0, 1] + unselected.wire + [0x0b, 0, 0, 0, 0, 0, 0, 42])
        if missingCapability == 0 {
            // The request reaches the transfer handler, which must reject the
            // unselected path before reading any file or launching a helper.
            #expect(throws: (any Error).self) { try peer.read(1) }
        } else {
            // Incomplete drag negotiation still disables the transfer backend.
            #expect(try peer.readClipboard().1 == .text("initial"))
        }
    }

    @Test(.enabled(if: NativeTransferProcess.available))
    func plaintextEncryptionCommandPreservesTheFollowingMessage() throws {
        let peer = try ClipboardTestPeer(fileTransfer: true)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.write([0x12, 0, 0, 2, 0, 0, 0, 0])
        try peer.enableAppleClipboard()
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 42])
        #expect(try peer.readClipboard().1 == .text("initial"))
    }

    @Test(.enabled(if: NativeTransferProcess.available))
    func plaintextPolicyRetainsNativeCapabilitiesAuthenticationAndClipboard() throws {
        let peer = try ClipboardTestPeer(fileTransfer: true, allowEncryption: false)
        defer { peer.finish() }
        let name = try peer.handshake(version: AppleRFB.version)
        #expect(peer.appleWrappingKey?.count == 16) // Account key wraps input; session records stay plaintext.
        for message in [0x0e, 0x12, 0x20, 0x22] {
            #expect(AppleRFB.supports(message, bitmap: Array(name[6..<22])))
        }
        #expect(AppleRFB.supports(0x10, bitmap: Array(name[6..<22])))
        // Disabling records is legal even when enabling them is forbidden.
        try peer.write([0x12, 0, 0, 2, 0, 0, 0, 0])
        try peer.enableAppleClipboard()
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 42])
        #expect(try peer.readClipboard().1 == .text("initial"))
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [UInt16(0), UInt16(1)])
    func plaintextPolicyConsumesKeyRequestsWithoutChangingFraming(level: UInt16) throws {
        let peer = try ClipboardTestPeer(fileTransfer: true, allowEncryption: false)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        // Send twice to cover a repeated request. No encoding-1103 reply should
        // precede the next ordinary clipboard response, and no cipher is armed.
        let request = [UInt8(0x12), 0, 0, 1] + level.beBytes + [0, 1, 0, 0, 0, 1]
        try peer.write(request + request)
        try peer.enableAppleClipboard()
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 42])
        #expect(try peer.readClipboard().1 == .text("initial"))
        #expect(peer.appleWrappingKey?.count == 16)
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [
        [UInt8(0x12), 0, 0, 2, 0, 1, 0, 0], // incoming records
        [UInt8(0x10), 0] + [UInt8](repeating: 0, count: 16) // encrypted input
    ])
    func plaintextPolicyRejectsRecordEncryptionAndMalformedInput(request: [UInt8]) throws {
        let peer = try ClipboardTestPeer(fileTransfer: true, allowEncryption: false)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.write(request)
        #expect(throws: (any Error).self) { try peer.read(1) }
    }

    @Test(.enabled(if: NativeTransferProcess.available))
    func oversizedEncryptionMethodListIsRejectedWithoutWaitingForItsBody() throws {
        let peer = try ClipboardTestPeer(fileTransfer: true)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.write([0x12, 0, 0, 1, 0, 1, 0, 101])
        #expect(throws: (any Error).self) { try peer.read(1) }
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [
        [UInt8(0x12), 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 99], // unknown cipher
        [UInt8(0x12), 0, 0, 1, 0, 1, 0, 0], // no supported cipher
        [UInt8(0x12), 0, 0, 2, 0, 1, 0, 0], // enable before keys
        [UInt8(0x12), 0, 0, 2, 0, 2, 0, 0] // invalid enable flag
    ])
    func invalidEncryptionNegotiationClosesTheSession(request: [UInt8]) throws {
        let peer = try ClipboardTestPeer(fileTransfer: true)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.write(request)
        try #require(peer.hasData(timeout: 2))
        var byte: UInt8 = 0
        #expect(recv(peer.socket.fd, &byte, 1, MSG_PEEK) == 0)
    }

    @Test func rejectsMalformedPathsArchivesAndFileData() throws {
        for path in ["relative", "/tmp/a\0b"] {
            let payload = [UInt8](repeating: 0, count: 8) + UInt16(path.utf8.count).beBytes + Array(path.utf8)
            #expect(throws: (any Error).self) {
                try AppleFileTransfer.Message(command: 1, sessionID: 1, payload: payload).startPath()
            }
        }
        #expect(throws: (any Error).self) { try AppleFileTransfer.Message(body: [0, 1]) }
        #expect(throws: (any Error).self) {
            try AppleFileTransfer.Message(command: 102, sessionID: 1, payload: [0, 0, 0, 100, 1]).validateFileData()
        }
        #expect(throws: (any Error).self) {
            try AppleFileTransfer.dragFiles(compressed: [1], archiveSize: AppleFileTransfer.maxDragBytes + 1)
        }
        let files = ClipboardContent(items: [[.init(type: "public.file-url", data: Data("file:///tmp/a%20b.txt".utf8))]])
        let raw = try AppleClipboard.archive(content: files)
        let urls = try AppleFileTransfer.dragFiles(compressed: AppleClipboard.compress(raw), archiveSize: raw.count)
        #expect(urls.map(\.path) == ["/tmp/a b.txt"])
        var item = [UInt8](repeating: 0, count: 104)
        item[0] = 1
        item[101] = 2
        item += Array("..".utf8) + [0]
        #expect(throws: (any Error).self) {
            try AppleFileTransfer.Message(command: 101, sessionID: 1, payload: item).validateFileData()
        }
    }

    private func stage(_ receiver: MacFileTransfer, store: TransferStore, source: URL, session: UInt32) throws -> URL {
        let archive = try AppleClipboard.archive(content: ClipboardContent(items: [[
            .init(type: "public.file-url", data: Data(source.absoluteString.utf8))
        ]]))
        try receiver.startDrag(sessionID: session, compressed: AppleClipboard.compress(archive), archiveSize: archive.count)
        return store.destination(try #require(store.snapshot().first).id)
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [false, true])
    func nativeHelpersTransferNestedFolderIntoStaging(named: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-vnc-native-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let nested = source.appendingPathComponent("日本語 folder")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let payload = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: nested.appendingPathComponent("binary.dat"))
        try Data().write(to: source.appendingPathComponent("empty.txt"))
        let result = FileTransferTestResult()
        let store = try TransferStore(options: .init(root: destination))
        let receiver = MacFileTransfer(logger: ServerLogger(verbose: true), inbox: TransferInbox(store: store)) { bytes in
            if bytes.first != 0x1e { result.receive(bytes) }
        }
        let sender = MacFileTransfer(logger: ServerLogger(verbose: true)) { bytes in
            guard bytes.count >= 6 else { throw RFBError.protocolError("missing output header") }
            try receiver.handle(AppleFileTransfer.Message(body: Array(bytes.dropFirst(6))))
        }
        defer { sender.stop(); receiver.stop() }
        let directory = try stage(receiver, store: store, source: source, session: 123)
        try receiver.startReceiver(session: 123, directory: directory, name: named ? "source" : nil)
        try sender.startSender(session: 123, source: source)
        #expect(result.ready.wait(timeout: .now() + 15) == .success)
        let response = try AppleFileTransfer.Message(body: Array(try #require(result.bytes).dropFirst(6)))
        #expect(response.command == 200)
        #expect(response.payload.prefix(2) == [0, 0])
        let batch = try #require(store.snapshot().first)
        let urls = try store.urls(batch.id)
        let received = try #require(urls.first)
        #expect(try Data(contentsOf: received.appendingPathComponent("日本語 folder/binary.dat")) == payload)
        #expect(try Data(contentsOf: received.appendingPathComponent("empty.txt")).isEmpty)
    }

    @Test(.enabled(if: NativeTransferProcess.available))
    func cancellationDoesNotPublishAnIncompleteFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-vnc-cancel-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = FileTransferTestResult()
        let store = try TransferStore(options: .init(root: root.appendingPathComponent("inbox")))
        let receiver = MacFileTransfer(logger: ServerLogger(verbose: false), inbox: TransferInbox(store: store)) { bytes in
            if bytes.first != 0x1e { result.receive(bytes) }
        }
        defer { receiver.stop() }
        let directory = try stage(receiver, store: store, source: root.appendingPathComponent("incomplete"), session: 9)
        try receiver.startReceiver(session: 9, directory: directory, name: "incomplete")
        receiver.stop()
        let batch = try #require(store.snapshot().first)
        #expect(try store.urls(batch.id).isEmpty)
        #expect(!batch.isComplete)
    }

    @Test func unrelatedConnectionCannotRequestAFile() throws {
        let transfer = MacFileTransfer(logger: ServerLogger(verbose: false)) { _ in }
        defer { transfer.stop() }
        let path = Array("/tmp/unselected-file".utf8)
        let message = AppleFileTransfer.Message(command: 1, sessionID: 8,
            payload: UInt32(0).beBytes + UInt32(0).beBytes + UInt16(path.count).beBytes + path)
        #expect(throws: (any Error).self) { try transfer.handle(message) }
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [false, true], [false, true])
    func negotiatedDragAuthorizesNativeFileCopy(toServer: Bool, encrypted: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-vnc-drag-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("file transferred through negotiated drag ✓".utf8).write(to: source)
        let helper = DragTestHelper()
        let result = FileTransferTestResult()
        let dragResult = FileTransferTestResult()
        let upload = try RecordTestLink(encrypted: encrypted)
        let download = try RecordTestLink(encrypted: encrypted)
        let store = try TransferStore(options: .init(root: root.appendingPathComponent("inbox")))
        let receiver = MacFileTransfer(logger: ServerLogger(verbose: false), input: DragTestInput(), inbox: TransferInbox(store: store),
            makeOutgoingDrag: { helper }) { bytes in
                let bytes = try download.transfer([bytes])
                if bytes.first == 0x1e { dragResult.receive(bytes) }
                else { result.receive(bytes) }
            }
        let sender = MacFileTransfer(logger: ServerLogger(verbose: false), input: DragTestInput(),
            makeOutgoingDrag: { helper }) { bytes in
                let bytes = try upload.transfer([Array(bytes.prefix(6)), Array(bytes.dropFirst(6))])
                if bytes.first == 0x20 { dragResult.receive(bytes) }
                else { try receiver.handle(AppleFileTransfer.Message(body: Array(bytes.dropFirst(6)))) }
            }
        defer { sender.stop(); receiver.stop() }
        let archive = try AppleClipboard.archive(content: ClipboardContent(items: [[
            .init(type: "public.file-url", data: Data(source.absoluteString.utf8))
        ]]))
        let compressed = try AppleClipboard.compress(archive)
        if toServer {
            try receiver.startDrag(sessionID: 77, compressed: compressed, archiveSize: archive.count)
            let batch = try #require(store.snapshot().first)
            let path = Array(store.destination(batch.id).path.utf8)
            #expect(dragResult.ready.wait(timeout: .now() + 2) == .success)
            let name = Array("source.txt".utf8)
            let body = UInt16(2).beBytes + UInt16(2).beBytes + UInt32(88).beBytes
                + [UInt8](repeating: 0, count: 8) + UInt16(path.count).beBytes + UInt16(name.count).beBytes
                + path + [0] + name + [0]
            try receiver.handle(AppleFileTransfer.Message(body: body))
            try sender.startSender(session: 88, source: source)
        } else {
            let directory = try stage(receiver, store: store, source: source, session: 88)
            // The receiving peer has finished its drop before the source
            // helper starts. Both peers share this test process's drag gate.
            let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 1, height: 1)
            #expect(receiver.pointer(mask: 0, x: 0, y: 0, layout: layout))
            #expect(dragResult.ready.wait(timeout: .now() + 2) == .success)
            try sender.startDrag(sessionID: 77, compressed: [], archiveSize: 0)
            helper.complete(.success([source]))
            #expect(dragResult.ready.wait(timeout: .now() + 2) == .success)
            try receiver.startReceiver(session: 88, directory: directory, name: "source.txt")
            let path = Array(source.path.utf8)
            try sender.handle(AppleFileTransfer.Message(command: 1, sessionID: 88,
                payload: [UInt8](repeating: 0, count: 8) + UInt16(path.count).beBytes + path))
        }
        #expect(result.ready.wait(timeout: .now() + 10) == .success)
        let batch = try #require(store.snapshot().first)
        let urls = try store.urls(batch.id)
        let received = try #require(urls.first)
        #expect(try Data(contentsOf: received) == Data(contentsOf: source))
    }

    @Test func cancelledOutgoingDragCannotAuthorizeALateFileResult() throws {
        let helper = DragTestHelper(), sent = FileTransferTestResult()
        let transfer = MacFileTransfer(logger: ServerLogger(verbose: false), input: DragTestInput(),
            makeOutgoingDrag: { helper }, send: { sent.receive($0) })
        defer { transfer.stop() }
        try transfer.startDrag(sessionID: 91, compressed: [], archiveSize: 0)
        transfer.cancelDrag()
        let source = URL(fileURLWithPath: "/tmp/cancelled-vnc-drag-fixture")
        helper.complete(.success([source]))
        #expect(sent.ready.wait(timeout: .now() + 0.2) == .timedOut)
        let request = AppleFileTransfer.Message(command: 1, sessionID: 92,
            payload: [UInt8](repeating: 0, count: 8) + UInt16(source.path.utf8.count).beBytes + Array(source.path.utf8))
        #expect(throws: (any Error).self) { try transfer.handle(request) }
    }

    @Test func replacedOutgoingDragCannotPublishOrCancelItsReplacement() throws {
        let first = DragTestHelper(), second = DragTestHelper(), sent = FileTransferTestResult()
        let queue = DragTestFactory([first, second])
        let input = DragTestInput()
        let transfer = MacFileTransfer(logger: ServerLogger(verbose: false), input: input,
            makeOutgoingDrag: { queue.next() }, send: { sent.receive($0) })
        defer { transfer.stop() }
        try transfer.startDrag(sessionID: 93, compressed: [], archiveSize: 0)
        try transfer.startDrag(sessionID: 94, compressed: [], archiveSize: 0)
        first.nudge()
        first.release()
        first.complete(.success([URL(fileURLWithPath: "/tmp/obsolete-vnc-drag-fixture")]))
        #expect(sent.ready.wait(timeout: .now() + 0.2) == .timedOut)
        #expect(input.masks.isEmpty)
        let source = URL(fileURLWithPath: "/tmp/current-vnc-drag-fixture")
        second.complete(.success([source]))
        #expect(sent.ready.wait(timeout: .now() + 2) == .success)
        let wire = try #require(sent.bytes)
        #expect(Array(wire[4..<8]) == UInt32(94).beBytes)
        let size = Int(UInt32.be(wire[8], wire[9], wire[10], wire[11]))
        #expect(try AppleFileTransfer.dragFiles(compressed: Array(wire.dropFirst(16)), archiveSize: size) == [source])
    }

    @Test func outgoingReceiverCannotPressAgainAfterRemoteRelease() throws {
        let helper = DragTestHelper(), input = DragTestInput()
        let transfer = MacFileTransfer(logger: ServerLogger(verbose: false), input: input,
            makeOutgoingDrag: { helper }, send: { _ in })
        defer { transfer.stop() }
        let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 100, height: 100)
        _ = transfer.pointer(mask: 1, x: 20, y: 20, layout: layout)
        try transfer.startDrag(sessionID: 95, compressed: [], archiveSize: 0)
        // The destination becomes ready after the viewer has already let go.
        _ = transfer.pointer(mask: 0, x: 20, y: 20, layout: layout)
        helper.nudge()
        #expect(input.masks.isEmpty)
    }

    @Test func outgoingCompletionDoesNotReleaseANewerOrdinaryClick() throws {
        let helper = DragTestHelper(), input = DragTestInput(), sent = FileTransferTestResult()
        let transfer = MacFileTransfer(logger: ServerLogger(verbose: false), input: input,
            makeOutgoingDrag: { helper }, send: { sent.receive($0) })
        defer { transfer.stop() }
        let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 100, height: 100)
        try transfer.startDrag(sessionID: 96, compressed: [], archiveSize: 0)
        helper.release()
        #expect(input.releases.wait(timeout: .now() + 1) == .success)
        // A new regular click can arrive during AppKit's delayed destination
        // teardown, before the archive is sent and drag ownership is cleared.
        _ = transfer.pointer(mask: 1, x: 40, y: 40, layout: layout)
        input.pointer(buttonMask: 1, x: 40, y: 40, layout: layout)
        helper.complete(.success([URL(fileURLWithPath: "/tmp/outgoing-vnc-drag-fixture")]))
        #expect(sent.ready.wait(timeout: .now() + 2) == .success)
        #expect(input.releases.wait(timeout: .now() + 0.2) == .timedOut)
        #expect(input.masks.last == 1)
    }
}

private final class DragTestFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var helpers: [DragTestHelper]
    init(_ helpers: [DragTestHelper]) { self.helpers = helpers }
    func next() -> DragTestHelper { lock.withLock { helpers.removeFirst() } }
}

private final class DragTestHelper: OutgoingFileDrag, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<[URL], Error>) -> Void)?
    private var nudgeCallback: (@Sendable () -> Void)?
    private var releaseCallback: (@Sendable () -> Void)?
    func start(nudge: @escaping @Sendable () -> Void, release: @escaping @Sendable () -> Void,
               completion: @escaping @Sendable (Result<[URL], Error>) -> Void) {
        lock.withLock {
            self.completion = completion
            nudgeCallback = nudge; releaseCallback = release
        }
    }
    func complete(_ result: Result<[URL], Error>) { lock.withLock { completion }?(result) }
    func nudge() { lock.withLock { nudgeCallback }?() }
    func release() { lock.withLock { releaseCallback }?() }
    func cancel() {}
}

private final class DragTestInput: InputController {
    private let lock = NSLock()
    let releases = DispatchSemaphore(value: 0)
    private var values: [UInt8] = []
    var masks: [UInt8] { lock.withLock { values } }
    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {}
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {
        lock.withLock { values.append(buttonMask) }
        if buttonMask == 0 { releases.signal() }
    }
    func releaseKeys() {}
}

private final class FileTransferTestResult: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: [UInt8]?
    var bytes: [UInt8]? { lock.withLock { value } }
    func receive(_ bytes: [UInt8]) {
        lock.withLock { value = bytes }
        ready.signal()
    }
}
