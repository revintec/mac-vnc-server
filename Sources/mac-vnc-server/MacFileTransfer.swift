import AppKit
import Darwin
import Foundation

/// The drag bridge can be exercised with pipes without opening a desktop drag.
protocol NativeDragHelper: AnyObject, Sendable {
    var input: ClientSocket { get }
    func read(_ count: Int, timeout: TimeInterval) throws -> [UInt8]
    func cancel()
}

extension NativeDragHelper {
    func read(_ count: Int) throws -> [UInt8] { try read(count, timeout: 30) }
}

/// One unprivileged helper, with bounded pipe I/O and deterministic cancellation.
final class NativeTransferProcess: NativeDragHelper, @unchecked Sendable {
    static let support = "/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/Support/"
    static let senderPath = support + "SSFileCopySender.bundle/Contents/MacOS/SSFileCopySender"
    static let receiverPath = support + "SSFileCopyReceiver.bundle/Contents/MacOS/SSFileCopyReceiver"
    static let dragPath = "/System/Library/CoreServices/RemoteManagement/AppleVNCServer.bundle/Contents/Support/SSDragHelper.app/Contents/MacOS/SSDragHelper"
    static var available: Bool {
        [senderPath, receiverPath, dragPath].allSatisfy { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private let process: Process
    let input: ClientSocket
    let output: ClientSocket
    private let lock = NSCondition()
    private var cancelled = false
    private var paused = false

    init(path: String) throws {
        let process = Process()
        let inputPipe = Pipe(), outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = path == Self.dragPath ? [] : [String(getuid()), String(getgid())]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        input = try ClientSocket(fd: dup(inputPipe.fileHandleForWriting.fileDescriptor))
        output = try ClientSocket(fd: dup(outputPipe.fileHandleForReading.fileDescriptor))
        _ = fcntl(input.fd, F_SETNOSIGPIPE, 1)
        self.process = process
        try process.run()
        try inputPipe.fileHandleForReading.close()
        try inputPipe.fileHandleForWriting.close()
        try outputPipe.fileHandleForReading.close()
        try outputPipe.fileHandleForWriting.close()
    }

    func setPaused(_ value: Bool) {
        lock.lock(); paused = value; lock.broadcast(); lock.unlock()
    }

    func waitUntilResumed() throws {
        lock.lock()
        defer { lock.unlock() }
        while paused && !cancelled { lock.wait() }
        if cancelled { throw RFBError.socketError("file transfer cancelled") }
    }

    func read(_ count: Int, timeout: TimeInterval = 30) throws -> [UInt8] {
        try waitUntilResumed()
        return try output.withReadTimeout(timeout, operation: "native file-transfer helper") { try output.readExact(count) }
    }

    var processID: Int32 { process.processIdentifier }

    func cancelAndWait() {
        cancel()
        process.waitUntilExit()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.broadcast()
        let running = process.isRunning
        if running { process.terminate() }
        lock.unlock()
        if running {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    deinit { cancel() }
}

/// All dictionaries are protected by lock. Each helper has one stdout reader;
/// only the RFB reader writes file-data input. The send callback applies network
/// backpressure, so a large folder cannot accumulate in memory.
final class MacFileTransfer: @unchecked Sendable {
    private static let dragLock = NSLock()
    nonisolated(unsafe) private static var dragOwner: (client: UUID, token: UUID)?
    private let identity = UUID()
    private let lock = NSLock()
    private let send: @Sendable ([UInt8]) throws -> Void
    private let logger: ServerLogger
    private let input: InputController
    private let pointerLock = NSLock()
    private let makeDragHelper: @Sendable () throws -> any NativeDragHelper
    private let inbox: TransferInbox?
    private var stagedBatches: [String: UUID] = [:]
    private var stagedReceives: [UInt32: TransferStore.Receive] = [:]
    private var receiveFailures: [UInt32: String] = [:]
    private var cancelledBatches = Set<UUID>()
    private var cancelledReceives = Set<UInt32>()
    private var gesture: TransferGesture?
    private var stopped = false
    private var drag: (any NativeDragHelper)?
    private var dragToken: UUID?
    private var sourceFiles: Set<String> = []
    private var dropDirectories: Set<String> = []
    private var senders: [UInt32: NativeTransferProcess] = [:]
    private var receivers: [UInt32: NativeTransferProcess] = [:]

    init(logger: ServerLogger, input: InputController = MacInputController(), inbox: TransferInbox? = nil,
         makeDragHelper: @escaping @Sendable () throws -> any NativeDragHelper = {
             try NativeTransferProcess(path: NativeTransferProcess.dragPath)
         },
         send: @escaping @Sendable ([UInt8]) throws -> Void) {
        self.logger = logger
        self.inbox = inbox
        self.input = input
        self.makeDragHelper = makeDragHelper
        self.send = send
    }

    func stop() { cancelAll(permanently: true) }

    func cancelAll(permanently: Bool = false) {
        lock.lock()
        stopped = stopped || permanently
        var helpers: [any NativeDragHelper] = senders.values.map { $0 }
        helpers.append(contentsOf: receivers.values.map { $0 as any NativeDragHelper })
        if let drag { helpers.append(drag) }
        let token = dragToken
        let gesture = self.gesture; self.gesture = nil
        let batches = Array(stagedBatches.values); stagedBatches.removeAll()
        cancelledReceives.formUnion(stagedReceives.keys)
        dragToken = nil
        senders.removeAll(); receivers.removeAll(); drag = nil
        sourceFiles.removeAll(); dropDirectories.removeAll()
        lock.unlock()
        helpers.forEach { $0.cancel() }
        gesture?.cancel()
        for id in batches { try? inbox?.store.finishWaiting(id, reason: "Connection ended or transfer cancelled") }
        releaseDrag(token: token)
    }

    private func releaseDrag(token: UUID?) {
        Self.dragLock.withLock {
            if let token, Self.dragOwner?.client == identity, Self.dragOwner?.token == token {
                // The native agent also posts mouse-up when tearing down its
                // helper. A cancelled promise must not leave our synthetic down held.
                postMouse(.leftMouseUp)
                Self.dragOwner = nil
            }
        }
    }

    /// Called only after RFB control and viewer capability checks.
    func startDrag(sessionID: UInt32, compressed: [UInt8], archiveSize: Int) throws {
        logger.verbose("Apple drag: session=\(sessionID) direction=\(compressed.isEmpty ? "server-to-client" : "client-to-server") archive_bytes=\(archiveSize)")
        var incomingFiles: [URL] = []
        if !compressed.isEmpty {
            let files = try AppleFileTransfer.dragFiles(compressed: compressed, archiveSize: archiveSize)
            incomingFiles = files
            guard !files.isEmpty else {
                logger.verbose("Apple drag ignored: session=\(sessionID) no supported file URLs in archive")
                return
            }
        }
        let token = UUID()
        let acquired = Self.dragLock.withLock { () -> Bool in
            guard Self.dragOwner == nil || Self.dragOwner?.client == identity else { return false }
            Self.dragOwner = (identity, token)
            return true
        }
        guard acquired else {
            logger.verbose("Apple drag ignored: session=\(sessionID) another connection owns the drag helper")
            return
        }
        do {
            lock.lock()
            let old = drag
            let oldGesture = gesture; gesture = nil
            drag = nil
            dragToken = token
            sourceFiles.removeAll()
            dropDirectories = Set(stagedBatches.keys)
            let active = !stopped
            lock.unlock()
            old?.cancel()
            oldGesture?.cancel()
            guard active else { releaseDrag(token: token); return }
            if let inbox, !incomingFiles.isEmpty {
                let batch: TransferStore.Batch
                do { batch = try inbox.store.begin(names: incomingFiles.map(\.lastPathComponent)) }
                catch {
                    // A storage failure must not tear down the remote desktop
                    // or turn the still-held file drag into a click on an app.
                    logger.warning("Apple staged transfer unavailable: \(error.localizedDescription)")
                    inbox.reportError(error.localizedDescription)
                    let blocked = TransferGesture(batch: UUID(), input: input) { [weak self] in
                        self?.endStagedGesture(token: token)
                    }
                    lock.withLock { gesture = blocked }
                    return
                }
                let directory = inbox.store.destination(batch.id)
                let nextGesture = TransferGesture(batch: batch.id, input: input) { [weak self] in
                    self?.endStagedGesture(token: token)
                }
                lock.withLock {
                    stagedBatches[directory.path] = batch.id
                    dropDirectories.insert(directory.path)
                    gesture = nextGesture
                }
                inbox.register(nextGesture) { [weak self] in self?.cancelStagedBatch(batch.id, keepPartialFiles: true) }
                let path = Array(directory.path.utf8)
                try send([0x1e, 0, 0, 0] + sessionID.beBytes + UInt32(path.count).beBytes + path)
                logger.verbose("Apple staged transfer requested before mouse-up: session=\(sessionID) batch=\(batch.id)")
                scheduleWaitingTimeout(batch.id)
                return
            }
            let helper = try makeDragHelper()
            lock.lock()
            guard !stopped else { lock.unlock(); helper.cancel(); releaseDrag(token: token); return }
            drag = helper
            lock.unlock()
            try helper.input.writeAll(sessionID.nativeBytes + UInt32(compressed.count).nativeBytes
                + UInt32(archiveSize).nativeBytes + compressed)
            // Match ScreensharingAgent: wait for the shield to exist before
            // processing the viewer's next pointer packet (which may be up).
            guard try helper.read(1, timeout: 5) == [15] else {
                throw RFBError.protocolError("native drag helper did not initialize")
            }
            if !compressed.isEmpty {
                guard lock.withLock({ () -> Bool in
                    guard !stopped && drag === helper else { return false }
                    postMouse(.leftMouseUp)
                    postMouse(.leftMouseDown, offset: 1)
                    return true
                }) else { return }
                try helper.input.writeAll([20])
            }
            logger.verbose("Apple drag ready: session=\(sessionID)")
            DispatchQueue.global(qos: .userInitiated).async { [self, helper] in
                defer {
                    helper.cancel()
                    lock.lock()
                    let current = drag === helper
                    if current { drag = nil; dragToken = nil }
                    lock.unlock()
                    // Completion of an old helper must not release a newer drag.
                    if current { releaseDrag(token: token) }
                }
                do { try readDrag(helper) }
                catch { logger.verbose("Apple drag ended: \(error)") }
            }
        } catch {
            cancelDrag()
            throw error
        }
    }

    func cancelDrag() {
        lock.lock()
        let gesture = self.gesture; self.gesture = nil
        let helper = drag
        drag = nil
        let token = dragToken
        dragToken = nil
        lock.unlock()
        helper?.cancel()
        gesture?.cancel()
        if let gesture { cancelStagedBatch(gesture.batch, reason: "Drag cancelled or left the remote view") }
        releaseDrag(token: token)
    }

    private func scheduleWaitingTimeout(_ id: UUID) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, let store = inbox?.store,
                  let batch = try? store.snapshot().first(where: { $0.id == id }), batch.isActive else { return }
            if !batch.items.contains(where: { $0.state == .receiving }), Date().timeIntervalSince(batch.updated) >= 120 {
                try? store.finishWaiting(id, reason: "Client did not start the remaining files")
            } else { scheduleWaitingTimeout(id) }
        }
    }

    /// Returns true when staging consumed the event (no click on the target).
    func pointer(mask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) -> Bool {
        lock.withLock { gesture }?.pointer(mask: mask, x: x, y: y, layout: layout) ?? false
    }

    private func endStagedGesture(token: UUID) {
        // No postMouse here: a mouse-up already arrived, or AppKit ended the
        // local drag. Releasing an old token must never affect a newer gesture.
        Self.dragLock.withLock {
            if Self.dragOwner?.client == identity && Self.dragOwner?.token == token { Self.dragOwner = nil }
        }
    }

    private func cancelStagedBatch(_ id: UUID, reason: String = "Cancelled", keepPartialFiles: Bool = false) {
        if keepPartialFiles {
            do { try inbox?.store.keepPartialFilesOnCancel(id) }
            catch {
                inbox?.reportError("Could not keep partial files before cancelling: \(error.localizedDescription)")
                return
            }
        }
        let helpers = lock.withLock { () -> [(UInt32, NativeTransferProcess)] in
            var result: [(UInt32, NativeTransferProcess)] = []
            cancelledBatches.insert(id)
            for (session, receive) in stagedReceives where receive.batch == id {
                cancelledReceives.insert(session)
                receiveFailures[session] = reason
                if let helper = receivers.removeValue(forKey: session) { result.append((session, helper)) }
            }
            for (path, batch) in stagedBatches where batch == id { dropDirectories.remove(path) }
            return result
        }
        lock.withLock { gesture?.batch == id ? gesture : nil }?.cancel()
        for (session, helper) in helpers {
            helper.cancel()
            try? send(AppleFileTransfer.receiverResult(sessionID: session, status: UInt16.max, name: ""))
        }
        try? inbox?.store.finishWaiting(id, reason: reason)
    }

    private func postMouse(_ type: CGEventType, offset: CGFloat = 0) {
        pointerLock.lock()
        defer { pointerLock.unlock() }
        guard var point = CGEvent(source: nil)?.location else { return }
        point.x += offset; point.y += offset
        // Use the same input bridge as RFB pointer packets, so the synthetic
        // button belongs to this client and subsequent up/disconnect releases it.
        // An origin at the current point also supports negative monitor positions.
        let layout = VirtualDisplayLayout(displays: [], origin: point, scale: 1, width: 1, height: 1)
        input.pointer(buttonMask: type == .leftMouseUp ? 0 : 1, x: 0, y: 0, layout: layout)
    }

    private func readDrag(_ helper: any NativeDragHelper) throws {
        while true {
            let code = try helper.read(1, timeout: 60)[0]
            guard lock.withLock({ !stopped && drag === helper }) else { return }
            switch code {
            case 12, 13:
                lock.withLock {
                    guard !stopped && drag === helper else { return }
                    postMouse(code == 12 ? .leftMouseUp : .leftMouseDragged, offset: code == 13 ? 1 : 0)
                }
            case 14: return
            case 10:
                let header = try helper.read(8)
                let session = UInt32(littleEndianBytes: header, at: 0)
                let length = Int(UInt32(littleEndianBytes: header, at: 4))
                guard length > 0, length < 16_384 else { throw RFBError.protocolError("invalid drop destination length") }
                let path = try AppleFileTransfer.pathString(helper.read(length))
                let directory = URL(fileURLWithPath: path).standardizedFileURL
                guard directory.hasDirectoryPath || (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    throw RFBError.protocolError("drop destination is not a directory")
                }
                guard lock.withLock({ () -> Bool in
                    guard !stopped && drag === helper else { return false }
                    dropDirectories.insert(directory.path)
                    return true
                }) else { return }
                // Server-to-viewer file-transfer request: session, UTF-8 path.
                let bytes = Array(path.utf8)
                try send([0x1e, 0, 0, 0] + session.beBytes + UInt32(bytes.count).beBytes + bytes)
            case 11:
                let header = try helper.read(12)
                let session = UInt32(littleEndianBytes: header, at: 0)
                let length = Int(UInt32(littleEndianBytes: header, at: 4))
                let size = Int(UInt32(littleEndianBytes: header, at: 8))
                guard length > 0, length <= AppleFileTransfer.maxDragBytes else { throw RFBError.protocolError("invalid outgoing drag size") }
                let compressed = try helper.read(length)
                let files = try AppleFileTransfer.dragFiles(compressed: compressed, archiveSize: size)
                guard !files.isEmpty else { return }
                guard lock.withLock({ () -> Bool in
                    guard !stopped && drag === helper else { return false }
                    sourceFiles = Set(files.map(\.path))
                    return true
                }) else { return }
                try send(AppleFileTransfer.dragMessage(sessionID: session, compressed: compressed, archiveSize: UInt32(size)))
            default: throw RFBError.protocolError("unknown native drag helper command \(code)")
            }
        }
    }

    func handle(_ message: AppleFileTransfer.Message) throws {
        if message.command < 100 || message.command == 200 {
            logger.verbose("Apple FileCopy: command=\(message.command) session=\(message.sessionID) payload_bytes=\(message.payload.count)")
        }
        switch message.command {
        case 1:
            let start = try message.startPath()
            let source = URL(fileURLWithPath: start.path).standardizedFileURL
            guard lock.withLock({ !stopped && sourceFiles.contains(source.path) }) else {
                throw RFBError.protocolError("file requested outside the active drag")
            }
            try startSender(session: message.sessionID, source: source)
        case 2:
            let start = try message.startPath()
            let destination = URL(fileURLWithPath: start.path).standardizedFileURL
            let directory = destination
            let name = start.name
            if lock.withLock({ () -> Bool in
                guard let batch = stagedBatches[directory.path], cancelledBatches.contains(batch) else { return false }
                cancelledReceives.insert(message.sessionID)
                return true
            }) {
                try send(AppleFileTransfer.receiverResult(sessionID: message.sessionID, status: UInt16.max, name: name ?? ""))
                return
            }
            guard lock.withLock({ !stopped && dropDirectories.contains(directory.path) }) else {
                throw RFBError.protocolError("file destination does not match a drop")
            }
            try startReceiver(session: message.sessionID, directory: directory, name: name)
        case 3, 4:
            lock.withLock { senders[message.sessionID] }?.setPaused(message.command == 3)
        case 5:
            // Cancellation commands belong to the issuing connection only.
            lock.lock()
            let sender = senders.removeValue(forKey: message.sessionID)
            let receiver = receivers.removeValue(forKey: message.sessionID)
            if stagedReceives[message.sessionID] != nil { cancelledReceives.insert(message.sessionID) }
            lock.unlock()
            sender?.cancel(); receiver?.cancel()
        case 100...104:
            if lock.withLock({ cancelledReceives.contains(message.sessionID) }) { return }
            guard let helper = lock.withLock({ receivers[message.sessionID] }) else {
                throw RFBError.protocolError("file data without an active receive session")
            }
            try message.validateFileData()
            if let receive = lock.withLock({ stagedReceives[message.sessionID] }), let inbox {
                let count: Int64
                switch message.command {
                case 101: count = 4096
                case 102: count = Int64(message.payload.count - 4)
                case 103: count = Int64(UInt32.be(message.payload[2], message.payload[3], message.payload[4], message.payload[5]))
                default: count = 0
                }
                do { if count > 0 { try inbox.store.accept(receive, bytes: count, dataBytes: message.command == 101 ? 0 : count) } }
                catch {
                    logger.warning("Apple staged transfer stopped: \(error.localizedDescription)")
                    cancelStagedBatch(receive.batch, reason: error.localizedDescription)
                    return
                }
            }
            try helper.input.writeAll(message.receiverInput)
        case 200, 201:
            // Viewer receive status/progress. It has already consumed our data.
            if message.command == 200 {
                lock.withLock { senders.removeValue(forKey: message.sessionID) }?.cancel()
            }
        default: throw RFBError.protocolError("unsupported Apple file-copy command \(message.command)")
        }
    }

    func startSender(session: UInt32, source: URL) throws {
        let helper = try NativeTransferProcess(path: NativeTransferProcess.senderPath)
        lock.lock()
        guard !stopped, senders[session] == nil, senders.count + receivers.count < 8 else {
            lock.unlock(); helper.cancel()
            throw RFBError.protocolError("too many or duplicate file-copy sessions")
        }
        senders[session] = helper
        lock.unlock()
        let path = Array(source.path.utf8)
        try helper.input.writeAll(UInt16(1).nativeBytes + session.nativeBytes + UInt16(path.count).nativeBytes + path)
        DispatchQueue.global(qos: .utility).async { [self, helper] in
            defer {
                helper.cancel()
                lock.withLock { if senders[session] === helper { senders.removeValue(forKey: session) } }
            }
            do {
                while true {
                    let size = Int(UInt32(littleEndianBytes: try helper.read(4), at: 0))
                    guard size >= 2, size <= AppleFileTransfer.maxMessageBytes + 8 else {
                        throw RFBError.protocolError("invalid sender helper record")
                    }
                    let record = try helper.read(size)
                    let command = UInt16(littleEndianBytes: record, at: 0)
                    if command == 2 { return }
                    if command == 1 {
                        try helper.waitUntilResumed()
                        try send(Array(record.dropFirst(2)))
                    }
                    else if command != 3 { throw RFBError.protocolError("unknown sender helper record") }
                }
            } catch {
                guard lock.withLock({ !stopped && senders[session] === helper }) else { return }
                logger.warning("Apple file send failed: \(error)")
                try? send(AppleFileTransfer.Message(command: 104, sessionID: session, payload: UInt32.max.beBytes).wire)
            }
        }
    }

    func startReceiver(session: UInt32, directory: URL, name: String?) throws {
        // A private staging directory prevents incomplete transfers and name
        // collisions from replacing existing files at the selected destination.
        let batch = lock.withLock { stagedBatches[directory.path] }
        let receive = try batch.flatMap { try inbox?.store.receive(batch: $0, name: name) }
        let staging = receive?.staging ?? directory.appendingPathComponent(".mac-vnc-transfer-\(UUID())", isDirectory: true)
        if receive == nil {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let helper: NativeTransferProcess
        do { helper = try NativeTransferProcess(path: NativeTransferProcess.receiverPath) }
        catch {
            if let receive { try? inbox?.store.fail(receive, reason: error.localizedDescription) }
            else { try? FileManager.default.removeItem(at: staging) }
            throw error
        }
        lock.lock()
        guard !stopped, receivers[session] == nil, senders.count + receivers.count < 8 else {
            lock.unlock(); helper.cancelAndWait()
            if let receive { try? inbox?.store.fail(receive, reason: "Too many or duplicate transfers") }
            else { try? FileManager.default.removeItem(at: staging) }
            throw RFBError.protocolError("too many or duplicate file-copy sessions")
        }
        receivers[session] = helper
        if let receive { stagedReceives[session] = receive }
        lock.unlock()
        do {
            if let receive { try inbox?.store.writerStarted(receive, pid: helper.processID) }
            try helper.input.writeAll(AppleFileTransfer.receiverStart(sessionID: session, directory: staging, name: name))
        } catch {
            helper.cancelAndWait()
            lock.withLock { _ = receivers.removeValue(forKey: session); stagedReceives.removeValue(forKey: session) }
            if let receive { try? inbox?.store.fail(receive, reason: error.localizedDescription) }
            else { try? FileManager.default.removeItem(at: staging) }
            throw error
        }
        DispatchQueue.global(qos: .utility).async { [self, helper] in
            var failure = "Cancelled or interrupted"
            var succeeded = false
            defer {
                helper.cancelAndWait()
                lock.withLock {
                    if let reason = receiveFailures.removeValue(forKey: session) { failure = reason }
                    if receive != nil && !succeeded { cancelledReceives.insert(session) }
                    if receivers[session] === helper { receivers.removeValue(forKey: session) }
                    stagedReceives.removeValue(forKey: session)
                }
                if let receive { try? inbox?.store.fail(receive, reason: failure) }
                else { try? FileManager.default.removeItem(at: staging) }
            }
            do {
                while true {
                    let command = UInt16(littleEndianBytes: try helper.read(2), at: 0)
                    if command == 2 { _ = try helper.read(8); continue }
                    guard command == 1 else { throw RFBError.protocolError("unknown receiver helper record") }
                    let record = try helper.read(1_284)
                    let status = UInt16(littleEndianBytes: record, at: 0)
                    let length = Int(UInt16(littleEndianBytes: record, at: 2))
                    guard length < 1_024 else { throw RFBError.protocolError("invalid received filename") }
                    let receivedName = length == 0 ? (name ?? "")
                        : try AppleFileTransfer.pathString(Array(record[4..<(4 + length)]))
                    guard status == 0 else {
                        failure = "Client/native receiver reported status \(status)"
                        try send(AppleFileTransfer.receiverResult(sessionID: session, status: status, name: receivedName))
                        return
                    }
                    guard !receivedName.isEmpty, receivedName != ".", receivedName != "..", !receivedName.contains("/") else {
                        throw RFBError.protocolError("invalid received filename")
                    }
                    lock.lock()
                    guard !stopped, receivers[session] === helper else { lock.unlock(); return }
                    let finalName: String
                    do {
                        if let receive, let inbox {
                            finalName = try inbox.store.complete(receive, name: receivedName).lastPathComponent
                        } else { finalName = try publish(staging: staging, directory: directory, name: receivedName) }
                    }
                    catch { lock.unlock(); throw error }
                    lock.unlock()
                    succeeded = true
                    try send(AppleFileTransfer.receiverResult(sessionID: session, status: 0, name: finalName))
                    logger.verbose("Apple file receive completed: session=\(session)\(receive.map { " batch=\($0.batch)" } ?? "")")
                    return
                }
            } catch {
                guard lock.withLock({ !stopped && receivers[session] === helper }) else { return }
                failure = error.localizedDescription
                logger.warning("Apple file receive failed: \(error)")
                try? send(AppleFileTransfer.receiverResult(sessionID: session, status: UInt16.max, name: name ?? ""))
            }
        }
    }

    private func publish(staging: URL, directory: URL, name: String) throws -> String {
        try TransferStore.publish(source: staging.appendingPathComponent(name), directory: directory, name: name).lastPathComponent
    }

}

extension UInt32 {
    init(littleEndianBytes bytes: [UInt8], at offset: Int) {
        self = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
extension UInt16 {
    init(littleEndianBytes bytes: [UInt8], at offset: Int) {
        self = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
}
