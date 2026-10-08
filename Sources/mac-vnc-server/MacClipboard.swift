import AppKit
import Foundation

final class MacClipboard: ClipboardBridge {
    // Every subscription shares the process-wide pasteboard lock, including
    // clients on different display ports. Change cursors remain per client.
    private static let lock = NSLock()
    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = Self.lock.withLock { pasteboard.changeCount }
    }

    func currentContent() -> ClipboardContent? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return readContent()
    }

    func localContentIfChanged() -> ClipboardContent? {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        guard pasteboard.changeCount != lastChangeCount else {
            return nil
        }
        lastChangeCount = pasteboard.changeCount
        return readContent()
    }

    func setRemoteContent(_ content: ClipboardContent) {
        guard !content.hasPromises else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }

        // Compare the complete supported snapshot, including image bytes, so
        // one viewer echoing another cannot create an endless update loop.
        if readContent() == content {
            lastChangeCount = pasteboard.changeCount
            return
        }
        let items = content.items.map { flavors in
            let item = NSPasteboardItem()
            for flavor in flavors {
                if let data = flavor.data { item.setData(data, forType: .init(flavor.type)) }
            }
            return item
        }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
        lastChangeCount = pasteboard.changeCount
    }

    /// Call only with the process-wide lock held. Reading unsupported content
    /// must not synthesize an empty text update on a classic viewer.
    private func readContent() -> ClipboardContent? {
        guard pasteboard.types?.isEmpty == false else { return .empty }
        let generation = pasteboard.changeCount
        var items: [[ClipboardContent.Flavor]] = []
        var archiveBytes = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var flavors: [ClipboardContent.Flavor] = []
            archiveBytes += 4
            for type in item.types where ClipboardContent.supportedTypes.contains(type.rawValue) {
                guard let data = item.data(forType: type) else { return nil }
                archiveBytes += 16 + type.rawValue.utf8.count + data.count
                guard archiveBytes <= AppleClipboard.maxArchiveBytes else { return nil }
                if !data.isEmpty { flavors.append(.init(type: type.rawValue, data: data)) }
            }
            if !flavors.isEmpty { items.append(flavors) }
        }
        guard pasteboard.changeCount == generation else { return nil }
        if items.isEmpty {
            // An actual empty string is a clear; unrelated formats are not.
            return pasteboard.string(forType: .string) == "" ? .empty : nil
        }
        return ClipboardContent(items: items)
    }
}
