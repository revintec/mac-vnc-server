import AppKit
import Foundation

protocol OutgoingFileDrag: AnyObject, Sendable {
    func start(nudge: @escaping @Sendable () -> Void,
               release: @escaping @Sendable () -> Void,
               completion: @escaping @Sendable (Result<[URL], Error>) -> Void)
    func cancel()
}

/// Receive the real local drag through AppKit. SSDragHelper's Carbon receiver
/// can return an archive without finishing the source application's AppKit
/// drag, leaving Finder unable to start subsequent drags.
final class AppKitOutgoingFileDrag: OutgoingFileDrag, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var receiver: OutgoingDragReceiver?

    func start(nudge: @escaping @Sendable () -> Void,
               release: @escaping @Sendable () -> Void,
               completion: @escaping @Sendable (Result<[URL], Error>) -> Void) {
        DispatchQueue.main.async { [self] in
            guard !lock.withLock({ cancelled }) else { return }
            let next = OutgoingDragReceiver(nudge: nudge, release: release, completion: completion)
            let active = lock.withLock {
                guard !cancelled else { return false }
                receiver = next
                return true
            }
            if active { next.start() }
        }
    }

    func cancel() {
        let receiver = lock.withLock { cancelled = true; return self.receiver }
        if let receiver { DispatchQueue.main.async { receiver.cancel() } }
    }
}

@MainActor
private final class OutgoingDragReceiver {
    private let nudge: @Sendable () -> Void
    private let release: @Sendable () -> Void
    private let completion: @Sendable (Result<[URL], Error>) -> Void
    private var windows: [NSWindow] = []
    private var timeout: Timer?
    private var releaseRequested = false
    private var released = false
    private var files: [URL]?
    private var finished = false

    init(nudge: @escaping @Sendable () -> Void, release: @escaping @Sendable () -> Void,
         completion: @escaping @Sendable (Result<[URL], Error>) -> Void) {
        self.nudge = nudge; self.release = release; self.completion = completion
    }

    func start() {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false; window.backgroundColor = .clear
            window.level = .popUpMenu
            let view = OutgoingDragView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.receiver = self
            window.contentView = view
            windows.append(window)
            window.orderFrontRegardless()
            window.displayIfNeeded()
        }
        guard !windows.isEmpty else { finish(.failure(CancellationError())); return }
        // Common modes also run while this worker is an AppKit drag source.
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        timeout = timer; RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !finished else { return }
            nudge()
        }
    }

    func entered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !finished, sender.draggingSourceOperationMask.contains(.copy),
              !Self.fileURLs(sender).isEmpty else { return [] }
        if !releaseRequested {
            releaseRequested = true
            // Let draggingEntered return before ending the source gesture.
            DispatchQueue.main.async { [weak self] in
                guard let self, !finished else { return }
                released = true
                release()
            }
        }
        return .copy
    }

    func perform(_ sender: NSDraggingInfo) -> Bool {
        guard !finished, sender.draggingSourceOperationMask.contains(.copy) else { return false }
        let urls = Self.fileURLs(sender)
        guard !urls.isEmpty, urls.count <= 256 else { return false }
        files = urls
        return true
    }

    func ended() {
        if let files { finish(.success(files)) }
        else { cancel() }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<[URL], Error>) {
        guard !finished else { return }
        finished = true; timeout?.invalidate(); timeout = nil
        if !released { released = true; release() }
        // Keep the destination alive while AppKit returns its final reply to
        // the source. Tearing it down inside performDragOperation strands it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            windows.forEach { $0.close() }; windows.removeAll()
            completion(result)
        }
    }

    private static func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter {
            $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") && !$0.path.contains("\0")
        }.map(\.standardizedFileURL)
    }
}

@MainActor
private final class OutgoingDragView: NSView {
    weak var receiver: OutgoingDragReceiver?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        // A completely transparent window is absent from WindowServer hit
        // testing. A barely painted receiver must cover the pointer's display.
        NSColor.black.withAlphaComponent(0.01).setFill(); bounds.fill()
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { receiver?.entered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { receiver?.entered(sender) ?? [] }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { receiver != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { receiver?.perform(sender) ?? false }
    override func draggingEnded(_ sender: NSDraggingInfo) { receiver?.ended() }
}
