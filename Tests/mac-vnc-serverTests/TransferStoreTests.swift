import AppKit
import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

@Suite(.serialized)
struct TransferStoreTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mac-vnc-inbox-test-\(UUID())") }
    private func publish(_ store: TransferStore, batch: UUID, name: String, content: String = "test") throws -> URL {
        let receive = try store.receive(batch: batch, name: name)
        try store.accept(receive, bytes: Int64(content.utf8.count))
        try Data(content.utf8).write(to: receive.staging.appendingPathComponent(name))
        return try store.complete(receive, name: name)
    }
    @Test func allSelectedFilesMustCompleteAndNamesAreCollisionSafe() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(options: .init(root: root))
        let batch = try store.begin(names: ["report.txt", "report.txt"])
        let first = try publish(store, batch: batch.id, name: "report.txt", content: "one")
        #expect(try store.urls(batch.id).isEmpty)
        #expect(try store.urls(batch.id, allowPartial: true).isEmpty)
        let second = try publish(store, batch: batch.id, name: "report.txt", content: "two")
        #expect(first.lastPathComponent == "report.txt")
        #expect(second.lastPathComponent == "report 1.txt")
        #expect(try store.urls(batch.id).count == 2)
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
        #expect(try String(contentsOf: second, encoding: .utf8) == "two")
        var info = stat(); #expect(lstat(root.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
    }
    @Test func failureRequiresExplicitPartialSelectionAndRemovesPartialData() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(options: .init(root: root))
        let batch = try store.begin(names: ["good.txt", "bad.txt"])
        _ = try publish(store, batch: batch.id, name: "good.txt")
        let failed = try store.receive(batch: batch.id, name: "bad.txt")
        try Data("partial".utf8).write(to: failed.staging.appendingPathComponent("bad.txt"))
        try store.fail(failed, reason: "Cancelled")
        #expect(!FileManager.default.fileExists(atPath: failed.staging.path))
        #expect(try store.urls(batch.id).isEmpty)
        #expect(try store.urls(batch.id, allowPartial: true).count == 1)
        #expect(throws: (any Error).self) { try store.receive(batch: batch.id, name: "bad.txt") }
    }
    @Test func quotaAndFreeDiskChecksRunBeforeAcceptingBytes() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(options: .init(root: root, maximumBytes: 10, minimumFreeBytes: 0))
        let batch = try store.begin(names: ["a", "b"])
        let a = try store.receive(batch: batch.id, name: "a")
        let b = try store.receive(batch: batch.id, name: "b")
        try store.accept(a, bytes: 7)
        #expect(throws: (any Error).self) { try store.accept(b, bytes: 4) }
        try store.fail(a, reason: "Cancelled")
        try store.accept(b, bytes: 4)
        let other = try TransferStore(options: .init(root: root, maximumBytes: 10, minimumFreeBytes: Int64.max / 2))
        #expect(throws: (any Error).self) { try other.begin(names: ["c"]) }
    }
    @Test func recoveryHonorsActiveLeasesAndLivingWriters() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var first: TransferStore? = try TransferStore(options: .init(root: root))
        let batch = try #require(first).begin(names: ["pending"])
        let receive = try #require(first).receive(batch: batch.id, name: nil)
        try Data("partial".utf8).write(to: receive.staging.appendingPathComponent("pending"))
        let second = try TransferStore(options: .init(root: root))
        #expect(try #require(second.snapshot().first).isActive)
        // If the owner dies before its child, don't remove the child's directory.
        try first?.writerStarted(receive, pid: getpid())
        first = nil
        try second.clean()
        #expect(FileManager.default.fileExists(atPath: receive.staging.path))
        // Model the helper exiting by removing its persisted process identity.
        let manifest = second.directory(batch.id).appendingPathComponent("manifest.json")
        var recovered = try JSONDecoder().decode(TransferStore.Batch.self, from: Data(contentsOf: manifest))
        recovered.items[0].writerPID = nil
        try JSONEncoder().encode(recovered).write(to: manifest, options: .atomic)
        try second.clean()
        #expect(!FileManager.default.fileExists(atPath: receive.staging.path))
        #expect(try #require(second.snapshot().first).items[0].state == .failed)
    }
    @Test func usedFilesSurviveRestartAndExpiryUnusedFilesExpire() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(options: .init(root: root))
        let used = try store.begin(names: ["kept"]), unused = try store.begin(names: ["unused"])
        let keptURL = try publish(store, batch: used.id, name: "kept")
        _ = try publish(store, batch: unused.id, name: "unused")
        try store.retain(used.id)
        for id in [used.id, unused.id] {
            let manifest = store.directory(id).appendingPathComponent("manifest.json")
            var batch = try JSONDecoder().decode(TransferStore.Batch.self, from: Data(contentsOf: manifest))
            batch.updated = Date().addingTimeInterval(-90_000)
            batch.items[0].storageBytes = 1_048_576
            try JSONEncoder().encode(batch).write(to: manifest, options: .atomic)
        }
        let reopened = try TransferStore(options: .init(root: root))
        #expect(FileManager.default.fileExists(atPath: keptURL.path))
        #expect(try reopened.snapshot().map(\.id) == [used.id])
        try reopened.remove(used.id)
        #expect(!FileManager.default.fileExists(atPath: keptURL.path))
    }
    @Test func unsafeRootsNamesAndUnselectedItemsAreRejected() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(options: .init(root: root))
        for name in ["..", "../a", "a/b", "", "x\0y"] {
            #expect(throws: (any Error).self) { try store.begin(names: [name]) }
        }
        let batch = try store.begin(names: ["chosen"])
        #expect(throws: (any Error).self) { try store.receive(batch: batch.id, name: "not-selected") }
        let receive = try store.receive(batch: batch.id, name: "chosen")
        try FileManager.default.createSymbolicLink(atPath: receive.staging.appendingPathComponent("chosen").path, withDestinationPath: "/etc/hosts")
        #expect(throws: (any Error).self) { try store.complete(receive, name: "chosen") }
        #expect(throws: (any Error).self) { try store.remove(batch.id) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: (any Error).self) { try TransferStore(options: .init(root: link)) }
    }
    @Test @MainActor func releaseOrCancellationPreventsLateDragAndHeldGestureStartsOnce() throws {
        let input = StagingTestInput()
        let released = TransferGesture(batch: UUID(), input: input, ended: {})
        #expect(released.pointer(mask: 0, x: 1, y: 2, layout: .empty))
        #expect(!released.startIfHeld { _, press in press(); Issue.record("Late drag started"); return { _ in } })
        let cancelled = TransferGesture(batch: UUID(), input: input, ended: {})
        cancelled.cancel()
        #expect(!cancelled.startIfHeld { _, press in press(); Issue.record("Cancelled drag started"); return { _ in } })
        #expect(!input.masks.contains(1))
        #expect(!released.pointer(mask: 1, x: 1, y: 2, layout: .empty), "Ordinary input must resume after the original up")
        input.masks.removeAll()
        let held = TransferGesture(batch: UUID(), input: input, ended: {})
        let events = DragTestEvents()
        #expect(held.pointer(mask: 1, x: 3, y: 4, layout: .empty))
        let didStart = held.startIfHeld { point, press in
            press()
            #expect(point == CGPoint(x: 3, y: 4))
            return { events.append($0) }
        }
        #expect(didStart)
        #expect(!held.startIfHeld { _, press in press(); Issue.record("Drag started twice"); return { _ in } })
        #expect(held.pointer(mask: 1, x: 5, y: 6, layout: .empty))
        #expect(held.pointer(mask: 0, x: 6, y: 7, layout: .empty))
        held.cancel()
        #expect(events.values == [.move(CGPoint(x: 5, y: 6)), .drop(CGPoint(x: 6, y: 7))])
        #expect(input.masks == [0, 0, 1, 1, 0], "Staging suppresses input; an active drag owns one down/up pair")
    }

    @Test @MainActor func dragReleaseAndLateCleanupDoNotReleaseANewerClick() {
        let input = StagingTestInput()
        let events = DragTestEvents()
        let gesture = TransferGesture(batch: UUID(), input: input, ended: {})
        #expect(gesture.startIfHeld { _, press in press(); return { events.append($0) } })
        #expect(gesture.pointer(mask: 0, x: 4, y: 5, layout: .empty))
        #expect(events.values == [.drop(CGPoint(x: 4, y: 5))])
        input.pointer(buttonMask: 1, x: 6, y: 7, layout: .empty)
        gesture.cancel()
        #expect(input.masks == [0, 1, 0, 1])
        #expect(!gesture.pointer(mask: 1, x: 6, y: 7, layout: .empty))
        #expect(events.values.count == 1)
    }

    @Test @MainActor func cancellationEndsAppKitAndReleasesItsButtonOnce() {
        let input = StagingTestInput()
        let events = DragTestEvents()
        let gesture = TransferGesture(batch: UUID(), input: input, ended: {})
        #expect(gesture.startIfHeld { _, press in press(); return { events.append($0) } })
        gesture.cancel()
        gesture.cancel()
        #expect(events.values == [.cancel])
        #expect(input.masks == [0, 1, 0])
        #expect(!gesture.startIfHeld { _, press in press(); Issue.record("Cancelled drag restarted"); return { _ in } })
    }

}

private final class StagingTestInput: InputController {
    var masks: [UInt8] = []
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) { masks.append(buttonMask) }
    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {}
    func releaseKeys() {}
}

extension FileTransferTests {
    @Test func storageFailureDoesNotDisconnectOrClickTheUnderlyingApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-vnc-storage-full-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(options: .init(root: root, minimumFreeBytes: Int64.max / 2))
        let state = SlowTransferState()
        let inbox = TransferInbox(store: store, reportError: { _ in state.completed.signal() })
        let receiver = MacFileTransfer(logger: ServerLogger(verbose: false), input: state, inbox: inbox) { _ in
            Issue.record("Must not request file bytes when storage is unavailable")
        }
        defer { receiver.stop() }
        let archive = try AppleClipboard.archive(content: ClipboardContent(items: [[
            .init(type: "public.file-url", data: Data("file:///tmp/test".utf8))
        ]]))
        try receiver.startDrag(sessionID: 7, compressed: AppleClipboard.compress(archive), archiveSize: archive.count)
        #expect(state.completed.wait(timeout: .now() + 1) == .success)
        #expect(receiver.pointer(mask: 1, x: 2, y: 3, layout: .empty))
        #expect(!state.pressed)
        #expect(receiver.pointer(mask: 0, x: 2, y: 3, layout: .empty))
        #expect(!receiver.pointer(mask: 1, x: 2, y: 3, layout: .empty))
        #expect(try store.snapshot().isEmpty)
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [false, true])
    func stagedCancellationStopsTheWriterAndRejectsQueuedItems(remoteExit: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-vnc-staged-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TransferStore(options: .init(root: root))
        let state = SlowTransferState()
        let inbox = TransferInbox(store: store, present: { state.setGesture($0) })
        let receiver = MacFileTransfer(logger: ServerLogger(verbose: false), input: state, inbox: inbox) { _ in }
        defer { receiver.stop() }
        let archive = try AppleClipboard.archive(content: ClipboardContent(items: ["first", "queued"].map {
            [.init(type: "public.file-url", data: Data("file:///tmp/\($0)".utf8))]
        }))
        try receiver.startDrag(sessionID: 1, compressed: AppleClipboard.compress(archive), archiveSize: archive.count)
        let batch = try #require(store.snapshot().first)
        let path = Array(store.destination(batch.id).path.utf8)
        func start(_ session: UInt32) -> AppleFileTransfer.Message {
            AppleFileTransfer.Message(command: 2, sessionID: session,
                payload: [UInt8](repeating: 0, count: 8) + UInt16(path.count).beBytes + path)
        }
        try receiver.handle(start(10))
        if remoteExit { receiver.cancelDrag() } else { inbox.cancel(batch.id) }
        let deadline = Date().addingTimeInterval(3)
        while try #require(store.snapshot().first).isActive && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancelled = try #require(store.snapshot().first)
        #expect(!cancelled.isActive)
        #expect(cancelled.items.allSatisfy { $0.state == .failed && $0.writerPID == nil })
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.destination(batch.id).path).isEmpty)
        // A queued native item can race cancellation. Refuse it without
        // disconnecting the desktop or resurrecting the completed batch.
        try receiver.handle(start(11))
        try receiver.handle(.init(command: 102, sessionID: 11, payload: [0, 0, 0, 1, 0x41]))
        let gesture = try #require(state.gesture)
        let started = await MainActor.run { gesture.startIfHeld { _, press in press(); return { _ in } } }
        #expect(!started)
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [false, true])
    func delayedTransferContinuesOnlyWhenTheOriginalButtonIsHeld(releaseEarly: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-vnc-staged-integration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("slow.txt")
        let data = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 59) })
        try data.write(to: source)
        let state = SlowTransferState()
        let store = try TransferStore(options: .init(root: root.appendingPathComponent("inbox")))
        let inbox = TransferInbox(store: store, present: { state.setGesture($0) })
        let receiver = MacFileTransfer(logger: ServerLogger(verbose: false), input: state, inbox: inbox,
            makeDragHelper: { throw CLIError.commandFailed("Staged transfers must not start the promise helper") }) { bytes in
            if bytes.first == 0x1e { state.request.signal() }
            else { state.completed.signal() }
        }
        let sender = MacFileTransfer(logger: ServerLogger(verbose: false)) { bytes in
            let message = try AppleFileTransfer.Message(body: Array(bytes.dropFirst(6)))
            if message.command == 102 || message.command == 103 {
                if state.delayFirstData() {
                    state.dataStarted.signal()
                    guard state.releaseData.wait(timeout: .now() + 10) == .success else { throw CLIError.commandFailed("Test release timed out") }
                }
            }
            try receiver.handle(message)
        }
        defer { state.releaseData.signal(); sender.stop(); receiver.stop() }
        let archive = try AppleClipboard.archive(content: ClipboardContent(items: [[
            .init(type: "public.file-url", data: Data(source.absoluteString.utf8))
        ]]))
        try receiver.startDrag(sessionID: 77, compressed: AppleClipboard.compress(archive), archiveSize: archive.count)
        #expect(await waitForSignal(state.request, seconds: 1))
        let batch = try #require(store.snapshot().first)
        let path = Array(store.destination(batch.id).path.utf8)
        let start = AppleFileTransfer.Message(command: 2, sessionID: 88,
            payload: [UInt8](repeating: 0, count: 8) + UInt16(path.count).beBytes + path)
        let stranger = MacFileTransfer(logger: ServerLogger(verbose: false), inbox: inbox) { _ in }
        defer { stranger.stop() }
        #expect(throws: (any Error).self) { try stranger.handle(start) }
        try receiver.handle(start)
        try sender.startSender(session: 88, source: source)
        #expect(await waitForSignal(state.dataStarted, seconds: 3))
        #expect(try store.urls(batch.id).isEmpty)
        #expect(receiver.pointer(mask: releaseEarly ? 0 : 1, x: 10, y: 20, layout: .empty))
        #expect(!state.pressed)
        // The receiver has an unfinished native transfer when the up arrives.
        state.releaseData.signal()
        #expect(await waitForSignal(state.completed, seconds: 10))
        let urls = try store.urls(batch.id)
        #expect(urls.count == 1)
        #expect(try Data(contentsOf: #require(urls.first)) == data)
        let gesture = try #require(state.gesture)
        let started = await MainActor.run { gesture.startIfHeld { _, press in press(); return { _ in } } }
        #expect(started == !releaseEarly)
        #expect(state.pressed == !releaseEarly)
        receiver.stop()
        #expect(try Data(contentsOf: #require(urls.first)) == data, "Disconnect must retain completed files")
    }
}

private final class SlowTransferState: InputController, @unchecked Sendable {
    let request = DispatchSemaphore(value: 0), dataStarted = DispatchSemaphore(value: 0)
    let releaseData = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didDelay = false, sawDown = false
    private var currentGesture: TransferGesture?
    var gesture: TransferGesture? { lock.withLock { currentGesture } }
    var pressed: Bool { lock.withLock { sawDown } }
    func setGesture(_ value: TransferGesture) { lock.withLock { currentGesture = value } }
    func delayFirstData() -> Bool { lock.withLock { defer { didDelay = true }; return !didDelay } }
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) { lock.withLock { sawDown = sawDown || buttonMask == 1 } }
    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {}
    func releaseKeys() {}
}

private func waitForSignal(_ semaphore: DispatchSemaphore, seconds: Double) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: semaphore.wait(timeout: .now() + seconds) == .success) }
    }
}

private final class DragTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TransferDragEvent] = []
    var values: [TransferDragEvent] { lock.withLock { events } }
    func append(_ event: TransferDragEvent) { lock.withLock { events.append(event) } }
}
