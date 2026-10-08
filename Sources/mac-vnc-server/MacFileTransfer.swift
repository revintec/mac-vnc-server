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
    private var stopped = false
    private var drag: (any NativeDragHelper)?
    private var dragToken: UUID?
    private var sourceFiles: Set<String> = []
    private var dropDirectories: Set<String> = []
    private var senders: [UInt32: NativeTransferProcess] = [:]
    private var receivers: [UInt32: NativeTransferProcess] = [:]

    init(logger: ServerLogger, input: InputController = MacInputController(),
         makeDragHelper: @escaping @Sendable () throws -> any NativeDragHelper = {
             try NativeTransferProcess(path: NativeTransferProcess.dragPath)
         },
         send: @escaping @Sendable ([UInt8]) throws -> Void) {
        self.logger = logger
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
        dragToken = nil
        senders.removeAll(); receivers.removeAll(); drag = nil
        sourceFiles.removeAll(); dropDirectories.removeAll()
        lock.unlock()
        helpers.forEach { $0.cancel() }
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
        if !compressed.isEmpty {
            let files = try AppleFileTransfer.dragFiles(compressed: compressed, archiveSize: archiveSize)
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
            drag = nil
            dragToken = token
            sourceFiles.removeAll()
            dropDirectories.removeAll()
            let active = !stopped
            lock.unlock()
            old?.cancel()
            guard active else { releaseDrag(token: token); return }
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
        let helper = drag
        drag = nil
        let token = dragToken
        dragToken = nil
        lock.unlock()
        helper?.cancel()
        releaseDrag(token: token)
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
            lock.unlock()
            sender?.cancel(); receiver?.cancel()
        case 100...104:
            guard let helper = lock.withLock({ receivers[message.sessionID] }) else {
                throw RFBError.protocolError("file data without an active receive session")
            }
            try message.validateFileData()
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
        let staging = directory.appendingPathComponent(".mac-vnc-transfer-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let helper: NativeTransferProcess
        do { helper = try NativeTransferProcess(path: NativeTransferProcess.receiverPath) }
        catch { try? FileManager.default.removeItem(at: staging); throw error }
        lock.lock()
        guard !stopped, receivers[session] == nil, senders.count + receivers.count < 8 else {
            lock.unlock(); helper.cancel(); try? FileManager.default.removeItem(at: staging)
            throw RFBError.protocolError("too many or duplicate file-copy sessions")
        }
        receivers[session] = helper
        lock.unlock()
        do {
            try helper.input.writeAll(AppleFileTransfer.receiverStart(sessionID: session, directory: staging, name: name))
        } catch {
            helper.cancel()
            lock.withLock { _ = receivers.removeValue(forKey: session) }
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        DispatchQueue.global(qos: .utility).async { [self, helper] in
            defer {
                helper.cancel()
                lock.withLock { if receivers[session] === helper { receivers.removeValue(forKey: session) } }
                try? FileManager.default.removeItem(at: staging)
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
                        try send(AppleFileTransfer.receiverResult(sessionID: session, status: status, name: receivedName))
                        return
                    }
                    guard !receivedName.isEmpty, receivedName != ".", receivedName != "..", !receivedName.contains("/") else {
                        throw RFBError.protocolError("invalid received filename")
                    }
                    lock.lock()
                    guard !stopped, receivers[session] === helper else { lock.unlock(); return }
                    let finalName: String
                    do { finalName = try publish(staging: staging, directory: directory, name: receivedName) }
                    catch { lock.unlock(); throw error }
                    lock.unlock()
                    try send(AppleFileTransfer.receiverResult(sessionID: session, status: 0, name: finalName))
                    logger.verbose("Apple file receive completed: session=\(session)")
                    return
                }
            } catch {
                guard lock.withLock({ !stopped && receivers[session] === helper }) else { return }
                logger.warning("Apple file receive failed: \(error)")
                try? send(AppleFileTransfer.receiverResult(sessionID: session, status: UInt16.max, name: name ?? ""))
            }
        }
    }

    private func publish(staging: URL, directory: URL, name: String) throws -> String {
        let source = staging.appendingPathComponent(name)
        for suffix in 0..<1_000 {
            let ext = (name as NSString).pathExtension
            let numbered = "\((name as NSString).deletingPathExtension) \(suffix)" + (ext.isEmpty ? "" : "." + ext)
            let candidate = suffix == 0 ? name : numbered
            let target = directory.appendingPathComponent(candidate)
            // RENAME_EXCL is atomic and never replaces an existing destination.
            if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            guard errno == EEXIST else { throw RFBError.socketError("could not finish received file: \(String(cString: strerror(errno)))") }
        }
        throw RFBError.protocolError("too many files with the same name at the drop destination")
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
