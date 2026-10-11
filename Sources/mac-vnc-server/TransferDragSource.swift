import AppKit

/// A file gesture has one AppKit event stream, independent of WindowServer's
/// button ownership and of ordinary pointer events delivered to other apps.
enum TransferDragEvent: Equatable, Sendable {
    case move(CGPoint)
    case drop(CGPoint)
    case cancel
}

@MainActor
final class TransferDragSource: NSView, NSDraggingSource {
    var finished: ((NSDragOperation) -> Void)?
    private var tracking = false
    private var ending = false

    func start(urls: [URL]) {
        guard let window, !tracking, !urls.isEmpty,
              let event = mouseEvent(.leftMouseDragged, location: NSPoint(x: 20, y: 20)) else {
            finished?([]); return
        }
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: 4 + index * 3, y: 4 + index * 3, width: 32, height: 32),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        tracking = true
        beginDraggingSession(with: items, event: event, source: self).animatesToStartingPositionsOnCancelOrFail = false
        window.ignoresMouseEvents = true
    }

    func receive(_ input: TransferDragEvent) {
        guard tracking, !ending, let window else { return }
        let event: NSEvent?
        switch input {
        case .move(let point), .drop(let point):
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            let location = window.convertPoint(fromScreen: NSPoint(x: point.x, y: screenHeight - point.y))
            let up: Bool
            if case .drop = input { up = true } else { up = false }
            ending = up
            event = mouseEvent(up ? .leftMouseUp : .leftMouseDragged, location: location)
        case .cancel:
            ending = true
            event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)
        }
        // A HID mouse-up can go to the app under the pointer instead of this
        // background source. Queue it on the same AppKit application that owns
        // the dragging session, with the source window and drag coordinates.
        if let event { NSApp.postEvent(event, atStart: false) }
    }

    private func mouseEvent(_ type: NSEvent.EventType, location: NSPoint) -> NSEvent? {
        guard let window else { return nil }
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        tracking = false
        finished?(operation)
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
