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

    func currentText() -> String {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return pasteboard.string(forType: .string) ?? ""
    }

    func localTextIfChanged() -> String? {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        guard pasteboard.changeCount != lastChangeCount else {
            return nil
        }
        lastChangeCount = pasteboard.changeCount
        return pasteboard.string(forType: .string) ?? ""
    }

    func setRemoteText(_ text: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        // A viewer may echo a forwarded update. Do not turn equal text into a
        // new generation that bounces forever between connected clients.
        if pasteboard.string(forType: .string) == text
            || (text.isEmpty && pasteboard.types?.isEmpty != false) {
            lastChangeCount = pasteboard.changeCount
            return
        }
        pasteboard.clearContents()
        if !text.isEmpty {
            pasteboard.setString(text, forType: .string)
        }
        lastChangeCount = pasteboard.changeCount
    }
}
