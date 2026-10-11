import AppKit
import ObjectiveC

/// A file gesture has one AppKit event stream, independent of WindowServer's
/// button ownership and of ordinary pointer events delivered to other apps.
enum TransferDragEvent: Equatable, Sendable {
    case move(CGPoint)
    case drop(CGPoint)
    case cancel
}

@MainActor
final class TransferDragPolicy {
    private typealias SetActions = @convention(c) (UInt, UInt32, UInt32) -> Int32
    private typealias CancelDrag = @convention(c) (UInt) -> Int32
    private typealias DragReference = @convention(c) (AnyObject, Selector) -> UInt
    private static let dragRefSelector = NSSelectorFromString("dragRef")
    private static let setActions: SetActions? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDragSetAllowableActions") else { return nil }
        return unsafeBitCast(symbol, to: SetActions.self)
    }()
    private static let cancelDrag: CancelDrag? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDragCancelDrag") else { return nil }
        return unsafeBitCast(symbol, to: CancelDrag.self)
    }()
    private(set) var moveUnavailable = false
    var logger = ServerLogger(verbose: false)
    private var reportedOperation: NSDragOperation?
    private var monitor: Any?

    static var canChangeOperation: Bool {
        guard setActions != nil, cancelDrag != nil, let method = class_getInstanceMethod(NSDraggingSession.self, dragRefSelector),
              method_getNumberOfArguments(method) == 2 else { return false }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        return String(cString: returnType) == "Q"
    }

    func begin(_ session: NSDraggingSession, at point: NSPoint) {
        end()
        moveUnavailable = false
        reportedOperation = nil
        // Update before AppKit delivers this movement/up to the destination.
        // movedTo alone runs too late for a jump straight into a new target.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self, weak session] event in
            if let session {
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
                self?.update(session, at: point)
            }
            return event
        }
        update(session, at: point)
    }
    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// AppKit caches both source-operation masks before the drag has a location.
    /// Update the same CoreDrag actions AppKit uses as the target changes. This
    /// optional macOS bridge is checked at runtime; unsupported hosts keep Copy.
    func update(_ session: NSDraggingSession, at point: NSPoint) {
        let operation = Self.operation(at: point)
        guard Self.cancelDrag != nil, let setActions = Self.setActions, let reference = Self.reference(session) else {
            moveUnavailable = operation == .move
            return
        }
        let result = setActions(reference, UInt32(operation.rawValue), 0)
        moveUnavailable = operation == .move && result != 0
        if reportedOperation != operation {
            logger.verbose("Received Files drag operation: \(operation == .move ? "move" : "copy") result=\(result) point=\(point)")
            reportedOperation = operation
        }
    }
    func cancel(_ session: NSDraggingSession) {
        if let cancel = Self.cancelDrag, let reference = Self.reference(session) {
            let result = cancel(reference)
            logger.verbose("Received Files drag cancel: result=\(result)")
        }
    }
    private static func reference(_ session: NSDraggingSession) -> UInt? {
        guard let method = class_getInstanceMethod(type(of: session), dragRefSelector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == "Q" else { return nil }
        let getReference = unsafeBitCast(method_getImplementation(method), to: DragReference.self)
        return getReference(session, dragRefSelector)
    }

    /// Hit-test the actual window under the pointer, including inactive Finder
    /// windows and its desktop. The frontmost application is not the target.
    static func operation(at point: NSPoint) -> NSDragOperation {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              let pid = windows.first?[kCGWindowOwnerPID as String] as? Int32,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder" else { return .copy }
        return .move
    }
}

@MainActor
final class TransferTableView: NSTableView {
    let dragPolicy = TransferDragPolicy()
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        dragPolicy.update(session, at: screenPoint)
    }
    override func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

@MainActor
final class TransferDragSource: NSView, NSDraggingSource {
    var finished: ((NSDragOperation, Bool) -> Void)?
    let policy = TransferDragPolicy()
    private var session: NSDraggingSession?
    private var initialOperation: NSDragOperation = .copy
    private var tracking = false
    private var ending = false

    func start(urls: [URL]) {
        guard let window, !tracking, !urls.isEmpty,
              let event = mouseEvent(.leftMouseDragged, location: NSPoint(x: 20, y: 20)) else {
            finished?([], false); return
        }
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: 4 + index * 3, y: 4 + index * 3, width: 32, height: 32),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        tracking = true
        // Unlike a table drag, handoff can begin directly over Finder. Supply
        // its operation in AppKit's initial snapshot too: without movement the
        // destination may keep its first accepted action until mouse-up.
        window.ignoresMouseEvents = true
        let point = window.convertPoint(toScreen: event.locationInWindow)
        initialOperation = TransferDragPolicy.canChangeOperation ? TransferDragPolicy.operation(at: point) : .copy
        let session = beginDraggingSession(with: items, event: event, source: self)
        self.session = session
        session.animatesToStartingPositionsOnCancelOrFail = false
        policy.update(session, at: point)
    }

    func receive(_ input: TransferDragEvent) {
        guard tracking, !ending, let window else { return }
        let event: NSEvent?
        switch input {
        case .move(let point), .drop(let point):
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            let screenPoint = NSPoint(x: point.x, y: screenHeight - point.y)
            if let session { policy.update(session, at: screenPoint) }
            let location = window.convertPoint(fromScreen: screenPoint)
            let up: Bool
            if case .drop = input { up = true } else { up = false }
            ending = up
            event = mouseEvent(up ? .leftMouseUp : .leftMouseDragged, location: location)
        case .cancel:
            ending = true
            if let session { policy.cancel(session) }
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
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? initialOperation : .copy
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        policy.begin(session, at: screenPoint)
    }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        policy.update(session, at: screenPoint)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        tracking = false
        self.session = nil
        policy.end()
        finished?(operation, policy.moveUnavailable)
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
