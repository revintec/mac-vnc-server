import Foundation

/// Loginwindow has no user clipboard or file-transfer state.
struct DisabledClipboard: ClipboardBridge {
    func currentContent() -> ClipboardContent? { nil }
    func localContentIfChanged() -> ClipboardContent? { nil }
    func setRemoteContent(_ content: ClipboardContent) {}
}
