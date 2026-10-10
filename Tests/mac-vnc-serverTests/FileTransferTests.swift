import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

@Suite(.serialized)
struct FileTransferTests {
    @Test func fileTransferIsOptIn() throws {
        guard case .run(let config) = try CLI.parse(arguments: ["run", "--file-transfer"]) else {
            Issue.record("expected run configuration"); return
        }
        #expect(config.fileTransfer)
        #expect(!config.clipboardSync)
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

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [false, true])
    func nativeHelpersTransferNestedFolderAndKeepExistingDestination(legacy: Bool) throws {
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
        let targetName = legacy ? "source" : "copy"
        let existing = destination.appendingPathComponent(targetName)
        try Data("existing".utf8).write(to: existing)
        let result = FileTransferTestResult()
        let receiver = MacFileTransfer(logger: ServerLogger(verbose: true)) { bytes in result.receive(bytes) }
        let sender = MacFileTransfer(logger: ServerLogger(verbose: true)) { bytes in
            guard bytes.count >= 6 else { throw RFBError.protocolError("missing output header") }
            try receiver.handle(AppleFileTransfer.Message(body: Array(bytes.dropFirst(6))))
        }
        defer { sender.stop(); receiver.stop() }
        try receiver.startReceiver(session: 123, directory: destination, name: legacy ? nil : "copy")
        try sender.startSender(session: 123, source: source)
        #expect(result.ready.wait(timeout: .now() + 15) == .success)
        let response = try AppleFileTransfer.Message(body: Array(try #require(result.bytes).dropFirst(6)))
        #expect(response.command == 200)
        #expect(response.payload.prefix(2) == [0, 0])
        #expect(try Data(contentsOf: existing) == Data("existing".utf8))
        let received = destination.appendingPathComponent(targetName + " 1")
        #expect(try Data(contentsOf: received.appendingPathComponent("日本語 folder/binary.dat")) == payload)
        #expect(try Data(contentsOf: received.appendingPathComponent("empty.txt")).isEmpty)
    }

    @Test(.enabled(if: NativeTransferProcess.available))
    func cancellationDoesNotPublishAnIncompleteFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-vnc-cancel-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = FileTransferTestResult()
        let receiver = MacFileTransfer(logger: ServerLogger(verbose: false)) { bytes in result.receive(bytes) }
        try receiver.startReceiver(session: 9, directory: root, name: "incomplete")
        receiver.stop()
        // Closing the helper pipe wakes its reader and removes private staging.
        let deadline = Date().addingTimeInterval(2)
        while (try FileManager.default.contentsOfDirectory(atPath: root.path)).count > 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func unrelatedConnectionCannotRequestAFile() throws {
        let transfer = MacFileTransfer(logger: ServerLogger(verbose: false)) { _ in }
        defer { transfer.stop() }
        let path = Array("/tmp/unselected-file".utf8)
        let message = AppleFileTransfer.Message(command: 1, sessionID: 8,
            payload: UInt32(0).beBytes + UInt32(0).beBytes + UInt16(path.count).beBytes + path)
        #expect(throws: (any Error).self) { try transfer.handle(message) }
    }

    @Test func incomingDragWaitsForReadyAndReleasesTheSharedButton() throws {
        let helper = try DragTestHelper()
        let input = DragTestInput()
        let shared = SharedInputController(input: input)
        let client = shared.makeClient()
        let transfer = MacFileTransfer(logger: ServerLogger(verbose: false), input: client,
            makeDragHelper: { helper }, send: { _ in })
        defer { transfer.stop() }
        let archive = try AppleClipboard.archive(content: ClipboardContent(items: [[
            .init(type: "public.file-url", data: Data("file:///tmp/example.txt".utf8))
        ]]))
        let compressed = try AppleClipboard.compress(archive)
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { started.signal() }
            do { try transfer.startDrag(sessionID: 7, compressed: compressed, archiveSize: archive.count) }
            catch { Issue.record(error) }
        }
        #expect(try Array(helper.readCommands(12 + compressed.count).prefix(4)) == UInt32(7).nativeBytes)
        #expect(started.wait(timeout: .now() + 0.05) == .timedOut)
        #expect(input.masks.isEmpty)
        try helper.events.writeAll([15])
        #expect(try helper.readCommands(1) == [20])
        #expect(started.wait(timeout: .now() + 1) == .success)
        #expect(input.masks.last == 1)
        // A viewer can send mouse-up immediately after DropEvent. It must
        // release the same button the helper pressed, with no stuck drag.
        client.pointer(buttonMask: 0, x: 0, y: 0, layout: .empty)
        #expect(input.masks.last == 0)
        transfer.cancelDrag()
        #expect(input.masks.last == 0)
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [false, true])
    func negotiatedDragAuthorizesNativeFileCopy(toServer: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-vnc-drag-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("file transferred through negotiated drag ✓".utf8).write(to: source)
        let helper = try DragTestHelper()
        let result = FileTransferTestResult()
        let dragResult = FileTransferTestResult()
        let upload = try EncryptedTestLink()
        let download = try EncryptedTestLink()
        let receiver = MacFileTransfer(logger: ServerLogger(verbose: false), input: DragTestInput(),
            makeDragHelper: { helper }) { bytes in
                let bytes = try download.transfer([bytes])
                if bytes.first == 0x1e { dragResult.receive(bytes) }
                else { result.receive(bytes) }
            }
        let sender = MacFileTransfer(logger: ServerLogger(verbose: false), input: DragTestInput(),
            makeDragHelper: { helper }) { bytes in
                let bytes = try upload.transfer([Array(bytes.prefix(6)), Array(bytes.dropFirst(6))])
                if bytes.first == 0x20 { dragResult.receive(bytes) }
                else { try receiver.handle(AppleFileTransfer.Message(body: Array(bytes.dropFirst(6)))) }
            }
        defer { sender.stop(); receiver.stop() }
        let archive = try AppleClipboard.archive(content: ClipboardContent(items: [[
            .init(type: "public.file-url", data: Data(source.absoluteString.utf8))
        ]]))
        let compressed = try AppleClipboard.compress(archive)
        try helper.events.writeAll([15])
        if toServer {
            try receiver.startDrag(sessionID: 77, compressed: compressed, archiveSize: archive.count)
            _ = try helper.readCommands(12 + compressed.count)
            #expect(try helper.readCommands(1) == [20])
            let path = Array(root.path.utf8)
            try helper.events.writeAll([10] + UInt32(77).nativeBytes + UInt32(path.count).nativeBytes + path)
            #expect(dragResult.ready.wait(timeout: .now() + 2) == .success)
            let name = Array("received.txt".utf8)
            let body = UInt16(2).beBytes + UInt16(2).beBytes + UInt32(88).beBytes
                + [UInt8](repeating: 0, count: 8) + UInt16(path.count).beBytes + UInt16(name.count).beBytes
                + path + [0] + name + [0]
            try receiver.handle(AppleFileTransfer.Message(body: body))
            try sender.startSender(session: 88, source: source)
        } else {
            try sender.startDrag(sessionID: 77, compressed: [], archiveSize: 0)
            _ = try helper.readCommands(12)
            try helper.events.writeAll([11] + UInt32(77).nativeBytes + UInt32(compressed.count).nativeBytes
                + UInt32(archive.count).nativeBytes + compressed)
            #expect(dragResult.ready.wait(timeout: .now() + 2) == .success)
            try receiver.startReceiver(session: 88, directory: root, name: "received.txt")
            let path = Array(source.path.utf8)
            try sender.handle(AppleFileTransfer.Message(command: 1, sessionID: 88,
                payload: [UInt8](repeating: 0, count: 8) + UInt16(path.count).beBytes + path))
        }
        #expect(result.ready.wait(timeout: .now() + 10) == .success)
        #expect(try Data(contentsOf: root.appendingPathComponent("received.txt")) == Data(contentsOf: source))
    }
}

private final class DragTestHelper: NativeDragHelper, @unchecked Sendable {
    let input: ClientSocket
    let commands: ClientSocket
    let events: ClientSocket
    private let output: ClientSocket
    init() throws {
        func pair() throws -> (ClientSocket, ClientSocket) {
            var fds = [Int32](repeating: -1, count: 2)
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw RFBError.socketError("socketpair") }
            for fd in fds {
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            }
            return (try ClientSocket(fd: fds[0]), try ClientSocket(fd: fds[1]))
        }
        (input, commands) = try pair()
        (output, events) = try pair()
    }
    func read(_ count: Int, timeout: TimeInterval) throws -> [UInt8] {
        try output.withReadTimeout(timeout, operation: "test drag helper") { try output.readExact(count) }
    }
    func readCommands(_ count: Int) throws -> [UInt8] {
        try commands.withReadTimeout(2, operation: "test drag commands") { try commands.readExact(count) }
    }
    func cancel() { input.shutdown(); output.shutdown() }
}

private final class DragTestInput: InputController {
    private let lock = NSLock()
    private var values: [UInt8] = []
    var masks: [UInt8] { lock.withLock { values } }
    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {}
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {
        lock.withLock { values.append(buttonMask) }
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
