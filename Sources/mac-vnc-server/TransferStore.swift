import Darwin
import Foundation

/// Persistent copies belong to the server user, not to an RFB connection. A
/// process holds each receiving batch's lease until all native writers stop.
final class TransferStore: @unchecked Sendable {
    struct Options: Sendable {
        var root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/mac-vnc-server/Transfers", isDirectory: true)
        var maximumBytes: Int64 = 10 * 1_024 * 1_024 * 1_024
        var minimumFreeBytes: Int64 = 1_024 * 1_024 * 1_024
    }
    enum State: String, Codable, Sendable { case waiting, receiving, complete, partial, failed, moved }
    struct Item: Codable, Sendable, Identifiable {
        var id = UUID()
        var name: String
        var state = State.waiting
        var bytes: Int64 = 0
        var storageBytes: Int64 = 0
        var relativePath: String?
        var error: String?
        var writerPID: Int32?
        var finderMoveStarted: Date?
        var isMoving: Bool { finderMoveStarted != nil && error == nil }
    }
    struct Batch: Codable, Sendable, Identifiable {
        var id = UUID()
        var created = Date()
        var updated = Date()
        var retained = false
        // Optional for manifests written before panel cancellation kept data.
        var keepPartialOnFailure: Bool?
        var items: [Item]
        var isActive: Bool { items.contains { $0.state == .waiting || $0.state == .receiving } }
        var isComplete: Bool { items.allSatisfy { $0.state == .complete } }
    }
    struct Receive: Sendable { let batch: UUID; let item: UUID; let staging: URL }
    let options: Options
    private let lock = NSLock()
    private let rootFD: Int32
    private var leases: [UUID: Int32] = [:]
    private let fm = FileManager.default

    init(options: Options = .init()) throws {
        var options = options
        options.root = options.root.standardizedFileURL
        self.options = options
        try Self.privateDirectory(options.root, createParents: true)
        rootFD = open(options.root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard rootFD >= 0 else { throw Self.error("Cannot lock transfer storage") }
        try transaction { try recoverAndClean() }
    }
    deinit {
        for fd in leases.values { close(fd) }
        close(rootFD)
    }
    private static func error(_ message: String) -> Error { CLIError.commandFailed(message) }
    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
    private static func privateDirectory(_ url: URL, createParents: Bool = false) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: createParents,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw error("Transfer storage must be a directory owned by this user: \(url.path)")
        }
        guard chmod(url.path, 0o700) == 0 else { throw error("Cannot protect transfer storage") }
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard flock(rootFD, LOCK_EX) == 0 else { throw Self.error("Cannot lock transfer storage") }
            defer { flock(rootFD, LOCK_UN) }
            return try body()
        }
    }
    func directory(_ id: UUID) -> URL { options.root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func destination(_ id: UUID) -> URL { directory(id).appendingPathComponent("files", isDirectory: true) }
    private func partialDirectory(_ id: UUID) -> URL { directory(id).appendingPathComponent("partial", isDirectory: true) }
    private func itemURL(_ item: Item, batch: UUID) -> URL? {
        guard let path = item.relativePath else { return nil }
        return (item.state == .partial ? partialDirectory(batch) : destination(batch)).appendingPathComponent(path)
    }
    private func load(_ id: UUID) throws -> Batch {
        let url = directory(id).appendingPathComponent("manifest.json")
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 1_048_576 else { throw Self.error("Invalid transfer manifest") }
        let batch = try JSONDecoder().decode(Batch.self, from: Data(contentsOf: url))
        guard batch.id == id, batch.items.count <= 256,
              batch.items.allSatisfy({ Self.validName($0.name) && $0.bytes >= 0 && $0.storageBytes >= $0.bytes && ($0.relativePath == nil || Self.validName($0.relativePath!)) }) else {
            throw Self.error("Invalid transfer manifest")
        }
        return batch
    }
    private func save(_ batch: Batch) throws {
        var batch = batch
        batch.updated = Date()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(batch).write(to: directory(batch.id).appendingPathComponent("manifest.json"), options: .atomic)
    }
    private func batches() throws -> [Batch] {
        try fm.contentsOfDirectory(at: options.root, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .compactMap { url in
                guard let id = UUID(uuidString: url.lastPathComponent),
                      (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return nil }
                return try? load(id)
            }
    }
    func snapshot() throws -> [Batch] {
        try transaction {
            var result = try batches()
            for i in result.indices { try reconcileFinderMoves(&result[i]) }
            return result.sorted { $0.created > $1.created }
        }
    }

    func begin(names: [String]) throws -> Batch {
        try transaction {
            guard !names.isEmpty, names.count <= 256, names.allSatisfy(Self.validName) else { throw Self.error("Invalid transfer selection") }
            try recoverAndClean()
            try checkSpace(extra: 0)
            guard try batches().filter(\.isActive).count < 8 else { throw Self.error("Too many receiving transfers") }
            let batch = Batch(items: names.map { Item(name: $0) })
            let dir = directory(batch.id)
            try Self.privateDirectory(dir)
            do {
                try Self.privateDirectory(dir.appendingPathComponent(".incoming", isDirectory: true))
                try Self.privateDirectory(destination(batch.id))
                let fd = open(dir.appendingPathComponent(".owner").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw Self.error("Cannot create transfer lease") }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Self.error("Transfer already active") }
                leases[batch.id] = fd
                try save(batch)
                return batch
            } catch {
                if let fd = leases.removeValue(forKey: batch.id) { close(fd) }
                try? fm.removeItem(at: dir)
                throw error
            }
        }
    }
    func receive(batch id: UUID, name: String?) throws -> Receive {
        try transaction {
            guard leases[id] != nil else { throw Self.error("Transfer is no longer active") }
            var batch = try load(id)
            guard let index = batch.items.firstIndex(where: { $0.state == .waiting && (name == nil || $0.name == name) }) else {
                throw Self.error("File was not part of the selected drag, or was already received")
            }
            let staging = directory(id).appendingPathComponent(".incoming/\(batch.items[index].id)", isDirectory: true)
            try Self.privateDirectory(staging)
            batch.items[index].state = .receiving
            try save(batch)
            return Receive(batch: id, item: batch.items[index].id, staging: staging)
        }
    }
    func writerStarted(_ receive: Receive, pid: Int32) throws {
        try transaction {
            var batch = try load(receive.batch)
            guard let index = batch.items.firstIndex(where: { $0.id == receive.item && $0.state == .receiving }) else {
                throw Self.error("Transfer cancelled")
            }
            batch.items[index].writerPID = pid
            try save(batch)
        }
    }
    /// Charge decompressed payload bytes before they reach the native receiver.
    /// Reserve metadata too, so millions of zero-byte entries cannot evade limits.
    func accept(_ receive: Receive, bytes: Int64, dataBytes: Int64? = nil) throws {
        try transaction {
            var batch = try load(receive.batch)
            guard leases[receive.batch] != nil,
                  let index = batch.items.firstIndex(where: { $0.id == receive.item && $0.state == .receiving }) else {
                throw Self.error("Transfer cancelled")
            }
            try checkSpace(extra: bytes)
            let dataBytes = dataBytes ?? bytes
            guard dataBytes >= 0 && dataBytes <= bytes else { throw Self.error("Invalid file byte count") }
            batch.items[index].bytes += dataBytes
            batch.items[index].storageBytes += bytes
            try save(batch)
        }
    }
    private func checkSpace(extra: Int64) throws {
        var used: Int64 = 0
        for item in try batches().flatMap(\.items) {
            let (sum, overflow) = used.addingReportingOverflow(item.storageBytes)
            guard !overflow else { throw Self.error("Invalid transfer quota accounting") }
            used = sum
        }
        guard extra >= 0, extra <= options.maximumBytes, used <= options.maximumBytes - extra else {
            throw Self.error("Transfer storage limit reached; remove retained transfers or increase --transfer-limit-gib")
        }
        var fs = statfs()
        guard statfs(options.root.path, &fs) == 0,
              Int64(fs.f_bavail) * Int64(fs.f_bsize) - extra >= options.minimumFreeBytes else {
            throw Self.error("Not enough free disk space for this transfer")
        }
    }
    func complete(_ receive: Receive, name: String) throws -> URL {
        try transaction {
            guard Self.validName(name), leases[receive.batch] != nil else { throw Self.error("Invalid or inactive received file") }
            var batch = try load(receive.batch)
            guard let index = batch.items.firstIndex(where: { $0.id == receive.item && $0.state == .receiving }) else { throw Self.error("Transfer cancelled") }
            let source = receive.staging.appendingPathComponent(name)
            // Never publish a symlink or special file produced by a helper.
            var info = stat()
            guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else {
                throw Self.error("Received item is not a regular file or folder")
            }
            let target = try Self.publish(source: source, directory: destination(receive.batch), name: name)
            batch.items[index].relativePath = target.lastPathComponent
            batch.items[index].state = .complete
            // Keep the conservative byte reservation, including metadata, in the quota.
            try save(batch)
            try? fm.removeItem(at: receive.staging)
            finishLeaseIfIdle(batch)
            return target
        }
    }
    /// Invoke only after the native writer has exited, including after cancel.
    func fail(_ receive: Receive, reason: String) throws {
        try transaction {
            var batch = try load(receive.batch)
            if let index = batch.items.firstIndex(where: { $0.id == receive.item }) {
                try failItem(&batch, index: index, staging: receive.staging, reason: reason)
                batch.items[index].writerPID = nil
                try save(batch)
            }
            finishLeaseIfIdle(batch)
        }
    }
    /// Persist this before stopping writers, so recovery also honors Cancel.
    func keepPartialFilesOnCancel(_ id: UUID) throws {
        try transaction {
            var batch = try load(id)
            batch.keepPartialOnFailure = true; batch.retained = true
            try save(batch)
        }
    }
    private func failItem(_ batch: inout Batch, index: Int, staging: URL, reason: String) throws {
        guard batch.items[index].state == .receiving || batch.items[index].state == .waiting else { return }
        if batch.keepPartialOnFailure == true,
           fm.fileExists(atPath: staging.path),
           !(try fm.contentsOfDirectory(atPath: staging.path)).isEmpty {
            try Self.privateDirectory(partialDirectory(batch.id))
            // Keep the entire native output, including unfinished folder entries.
            // The .partial container makes incompleteness visible in Finder too.
            let size = try storedSize(staging)
            let target = try Self.publish(source: staging, directory: partialDirectory(batch.id), name: batch.items[index].name + ".partial")
            batch.items[index].state = .partial
            batch.items[index].relativePath = target.lastPathComponent
            batch.items[index].storageBytes = max(batch.items[index].storageBytes, size)
            batch.retained = true
        } else {
            try? fm.removeItem(at: staging)
            batch.items[index].state = .failed
            batch.items[index].bytes = 0; batch.items[index].storageBytes = 0
        }
        batch.items[index].error = reason
    }
    func finishWaiting(_ id: UUID, reason: String) throws {
        try transaction {
            var batch = try load(id)
            for i in batch.items.indices where batch.items[i].state == .waiting {
                batch.items[i].state = .failed; batch.items[i].error = reason
            }
            try save(batch); finishLeaseIfIdle(batch)
        }
    }
    private func finishLeaseIfIdle(_ batch: Batch) {
        if !batch.isActive, let fd = leases.removeValue(forKey: batch.id) { close(fd) }
    }
    func retain(_ id: UUID) throws {
        try transaction { var batch = try load(id); batch.retained = true; try save(batch) }
    }
    func urls(_ id: UUID, allowPartial: Bool = false) throws -> [URL] {
        try transaction {
            var batch = try load(id)
            try reconcileFinderMoves(&batch)
            guard batch.items.allSatisfy({ $0.state == .complete || $0.state == .moved }) || (allowPartial && !batch.isActive) else { return [] }
            return batch.items.compactMap { item in
                guard item.state == .complete, !item.isMoving,
                      let url = itemURL(item, batch: id), fm.fileExists(atPath: url.path) else { return nil }
                return url
            }
        }
    }
    /// Reveal incomplete containers separately; they are never drag/save URLs.
    func revealURLs(_ id: UUID) throws -> [URL] {
        try transaction {
            let batch = try load(id)
            return batch.items.compactMap { item in
                guard item.state == .complete || item.state == .partial,
                      let url = itemURL(item, batch: id), fm.fileExists(atPath: url.path) else { return nil }
                return url
            }
        }
    }
    /// Finder owns the filesystem operation. Never delete a source on drag-end:
    /// its move may still be running, may fail, or may be cancelled in a dialog.
    func finderMoveAccepted(_ id: UUID, urls: [URL]) throws {
        try transaction {
            var batch = try load(id)
            for i in batch.items.indices where batch.items[i].state == .complete {
                if let url = itemURL(batch.items[i], batch: id), urls.contains(url) {
                    batch.items[i].finderMoveStarted = Date()
                    batch.items[i].error = nil
                }
            }
            try save(batch)
            try reconcileFinderMoves(&batch)
        }
    }
    private func reconcileFinderMoves(_ batch: inout Batch) throws {
        var changed = false
        for i in batch.items.indices {
            guard let started = batch.items[i].finderMoveStarted,
                  let url = itemURL(batch.items[i], batch: batch.id) else { continue }
            var info = stat()
            if lstat(url.path, &info) != 0 && errno == ENOENT {
                batch.items[i].state = .moved
                batch.items[i].relativePath = nil
                batch.items[i].bytes = 0; batch.items[i].storageBytes = 0
                batch.items[i].finderMoveStarted = nil
                batch.items[i].error = nil
                changed = true
            } else if Date().timeIntervalSince(started) > 300 && batch.items[i].error == nil {
                // A Finder collision dialog may have been cancelled. Make the
                // surviving copy usable again, but still recognize a slow move
                // that finishes later (for example to another volume).
                batch.items[i].error = "Finder has not moved this file; the received copy is still here"
                changed = true
            }
        }
        if changed { try save(batch) }
    }
    func remove(_ id: UUID) throws {
        try transaction {
            let batch = try load(id)
            guard !batch.isActive else { throw Self.error("Cancel the transfer before removing it") }
            try fm.removeItem(at: directory(id))
        }
    }
    func clean() throws { try transaction { try recoverAndClean() } }
    private func recoverAndClean() throws {
        for var batch in try batches() where leases[batch.id] == nil {
            let fd = open(directory(batch.id).appendingPathComponent(".owner").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            // A parent crash can precede its helper's pipe-EOF exit. Never
            // delete partial data until every recorded writer has disappeared.
            if batch.items.contains(where: { item in
                guard let pid = item.writerPID else { return false }
                return kill(pid, 0) == 0 || errno == EPERM
            }) { continue }
            var changedSize = false
            try reconcileFinderMoves(&batch)
            for i in batch.items.indices where batch.items[i].state == .complete || batch.items[i].state == .partial {
                guard let url = itemURL(batch.items[i], batch: batch.id) else { continue }
                let actual = try storedSize(url)
                if actual > batch.items[i].storageBytes { batch.items[i].storageBytes = actual; changedSize = true }
            }
            if changedSize { try save(batch) }
            if batch.isActive {
                for i in batch.items.indices where batch.items[i].state == .waiting || batch.items[i].state == .receiving {
                    let staging = directory(batch.id).appendingPathComponent(".incoming/\(batch.items[i].id)")
                    try failItem(&batch, index: i, staging: staging, reason: batch.keepPartialOnFailure == true ? "Cancelled" : "Interrupted before completion")
                    batch.items[i].writerPID = nil
                }
                try save(batch)
            }
            try? fm.removeItem(at: directory(batch.id).appendingPathComponent(".incoming"))
            if !batch.retained && Date().timeIntervalSince(batch.updated) > 24 * 3600 {
                try fm.removeItem(at: directory(batch.id))
            }
        }
    }
    private func storedSize(_ url: URL) throws -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        var total = max(Int64(info.st_size), Int64(info.st_blocks) * 512)
        guard info.st_mode & S_IFMT == S_IFDIR else { return total }
        if let entries = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let child as URL in entries {
                guard lstat(child.path, &info) == 0 else { continue }
                if info.st_mode & S_IFMT == S_IFLNK { entries.skipDescendants() }
                let (sum, overflow) = total.addingReportingOverflow(max(Int64(info.st_size), Int64(info.st_blocks) * 512))
                guard !overflow else { throw Self.error("Transfer storage size overflow") }
                total = sum
            }
        }
        return total
    }
    static func publish(source: URL, directory: URL, name: String) throws -> URL {
        for suffix in 0..<1_000 {
            let ext = (name as NSString).pathExtension
            let numbered = "\((name as NSString).deletingPathExtension) \(suffix)" + (ext.isEmpty ? "" : "." + ext)
            let target = directory.appendingPathComponent(suffix == 0 ? name : numbered)
            if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            guard errno == EEXIST else { throw error("Cannot publish received file: \(String(cString: strerror(errno)))") }
        }
        throw error("Too many files with the same name")
    }
}
