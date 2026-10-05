import AppKit
import Foundation

final class MacClipboard: ClipboardBridge {
    private let lock = NSLock()
    private var lastChangeCount: Int

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func currentText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return NSPasteboard.general.string(forType: .string) ?? ""
    }

    func localTextIfChanged() -> String? {
        lock.lock()
        defer { lock.unlock() }

        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else {
            return nil
        }
        lastChangeCount = pasteboard.changeCount
        return pasteboard.string(forType: .string) ?? ""
    }

    func setRemoteText(_ text: String) {
        lock.lock()
        defer { lock.unlock() }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !text.isEmpty {
            pasteboard.setString(text, forType: .string)
        }
        lastChangeCount = pasteboard.changeCount
    }
}
