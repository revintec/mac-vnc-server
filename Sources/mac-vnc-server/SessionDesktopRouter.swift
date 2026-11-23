import Foundation

/// Keeps the viewer-facing RFB session, compression streams and encryption in
/// place. Only its desktop source changes. The original canvas stays constant
/// when visiting another session; larger desktops fit inside it with letterboxing.
final class SessionDesktopRouter: @unchecked Sendable, FramebufferSource, FramebufferSequenceSource, InputRecoverySource, CaptureFrameRateController {
    let localCapture: FramebufferSource
    private let localInput: @Sendable () -> InputController
    private let localClipboard: @Sendable () -> ClipboardBridge
    private let lock = NSRecursiveLock()
    private let changes = FrameChangeHub()
    private var localObserver: UUID?
    private var remoteObserver: UUID?
    private var remote: ConsoleFramebufferBridge?
    private var remoteInputs: SharedInputController?
    private var canvas: (width: Int, height: Int)?
    private var fitted: Rect?
    private var cachedSourceSequence: UInt64?
    private var cached: Framebuffer?
    private var serial: UInt64 = 0
    private var epoch: UInt64 = 0
    private var stopped = false
    private var inputs: [UUID: WeakInput] = [:]
    private var observers: [UUID: @Sendable (Bool) -> Void] = [:]

    init(capture: FramebufferSource, makeInput: @escaping @Sendable () -> InputController,
         makeClipboard: @escaping @Sendable () -> ClipboardBridge) {
        localCapture = capture; localInput = makeInput; localClipboard = makeClipboard
        localObserver = capture.frameChanges?.observe { [weak self] in
            guard let self, !self.isRemote else { return }; self.changes.signal()
        }
    }
    deinit { if let localObserver { localCapture.frameChanges?.remove(localObserver) } }
    var frameChanges: FrameChangeHub? { changes }
    var generation: UInt64 { lock.withLock { epoch } }
    var isRemote: Bool { lock.withLock { remote != nil } }
    var includesCursor: Bool { lock.withLock { remote?.includesCursor ?? localCapture.includesCursor } }
    var cursorSnapshot: CursorSnapshot? {
        lock.withLock {
            guard let remote else { return localCapture.cursorSnapshot }
            guard let cursor = remote.cursorSnapshot, let canvas, let source = try? remote.capture() else { return nil }
            let scale = min(1, min(Double(canvas.width) / Double(source.width), Double(canvas.height) / Double(source.height)))
            let width = max(1, Int((Double(source.width) * scale).rounded()))
            let height = max(1, Int((Double(source.height) * scale).rounded()))
            guard let image = try? cursor.image.scaled(by: scale) else { return nil }
            return CursorSnapshot(image: image, position: CGPoint(
                x: Double((canvas.width - width) / 2) + cursor.position.x * Double(width) / Double(source.width),
                y: Double((canvas.height - height) / 2) + cursor.position.y * Double(height) / Double(source.height)))
        }
    }
    func withSnapshot<T>(_ body: () throws -> T) rethrows -> T { try lock.withLock(body) }

    func install(_ bridge: ConsoleFramebufferBridge) throws {
        // A failed first capture must leave the existing desktop intact.
        let home = try localCapture.capture()
        let first = try bridge.capture()
        _ = try fittedFrame(first, width: home.width, height: home.height)
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            change(to: bridge, canvas: (home.width, home.height))
        }
        bridge.start { [weak self, weak bridge] in
            guard let self, let bridge else { return }
            self.lock.withLock {
                if self.remote === bridge { self.change(to: nil, canvas: nil) }
            }
        }
    }

    func returnHome() { lock.withLock { change(to: nil, canvas: nil) } }
    func stop() { lock.withLock { stopped = true; change(to: nil, canvas: nil) } }

    // Called with the recursive lock. Cancel local drags before redirecting
    // input, and release every client's held controls in the old desktop.
    private func change(to next: ConsoleFramebufferBridge?, canvas: (Int, Int)?) {
        for callback in observers.values { callback(next != nil) }
        for entry in inputs.values { entry.value?.releaseLocked(); entry.value?.enabledEpoch = nil }
        let old = remote
        if let token = remoteObserver { old?.frameChanges?.remove(token) }
        remote = next; remoteInputs = next.map { SharedInputController(input: $0) }
        self.canvas = canvas; fitted = nil; cached = nil; cachedSourceSequence = nil
        epoch &+= 1
        remoteObserver = next?.frameChanges?.observe { [weak self] in self?.changes.signal() }
        old?.stop()
        changes.signal()
        SessionActivity.shared.changed()
    }

    func observeSwitch(_ callback: @escaping @Sendable (Bool) -> Void) -> UUID {
        lock.withLock { let id = UUID(); observers[id] = callback; callback(remote != nil); return id }
    }
    func removeSwitchObserver(_ id: UUID) { lock.withLock { observers[id] = nil } }

    func capture() throws -> Framebuffer {
        try lock.withLock {
            let source = try remote?.capture() ?? localCapture.capture()
            if let sequence = source.sequence, sequence == cachedSourceSequence, let cached,
               remote != nil || (source.width == cached.width && source.height == cached.height && source.layout == cached.layout) {
                return cached
            }
            let output: Framebuffer
            if let canvas, remote != nil {
                let result = try fittedFrame(source, width: canvas.width, height: canvas.height)
                output = result.0; fitted = result.1
            } else { output = source }
            serial &+= 1
            let result = Framebuffer(width: output.width, height: output.height, bytesPerRow: output.bytesPerRow,
                bgra: output.bgra, layout: output.layout, sequence: serial,
                dirtyRects: remote == nil && cachedSourceSequence.map({ source.sequence == $0 &+ 1 }) == true
                    ? source.dirtyRects : nil)
            cachedSourceSequence = source.sequence; cached = result
            return result
        }
    }
    func currentSequence() throws -> UInt64? { try capture().sequence }

    private func fittedFrame(_ source: Framebuffer, width: Int, height: Int) throws -> (Framebuffer, Rect) {
        let scale = min(1, min(Double(width) / Double(source.width), Double(height) / Double(source.height)))
        let small = try FramebufferResampling.scale(source, factor: scale)
        let rect = Rect(x: (width - small.width) / 2, y: (height - small.height) / 2,
            width: small.width, height: small.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { output in
            small.bgra.withUnsafeBytes { input in
                for row in 0..<small.height {
                    memcpy(output.baseAddress!.advanced(by: ((rect.y + row) * width + rect.x) * 4),
                        input.baseAddress!.advanced(by: row * small.bytesPerRow), small.width * 4)
                }
            }
        }
        return (Framebuffer(width: width, height: height, bgra: pixels,
            layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: width, height: height)), rect)
    }

    func makeLocalInput() -> InputController { localInput() }
    // File-transfer gestures belong to the account desktop for their whole
    // lifetime. Keep the same per-viewer input ownership, without routing their
    // cancellation through this lock while a switch suspends the transfer.
    func accountInput(for input: InputController) -> InputController {
        (input as? RoutedInput)?.local ?? input
    }
    func makeInput() -> InputController {
        lock.withLock {
            let client = RoutedInput(owner: self, local: localInput(), epoch: epoch)
            inputs[client.id] = WeakInput(value: client)
            return client
        }
    }
    func makeClipboard() -> ClipboardBridge { RoutedClipboard(owner: self, local: localClipboard()) }
    func activateInput(_ input: InputController, generation: UInt64) {
        lock.withLock { if generation == epoch { (input as? RoutedInput)?.enabledEpoch = epoch } }
    }
    func requestRecoveryAfterInput() {
        lock.withLock { if remote == nil { (localCapture as? InputRecoverySource)?.requestRecoveryAfterInput() } }
    }
    func registerCaptureRateConsumer(_ consumer: ObjectIdentifier, fps: Int) {
        (localCapture as? CaptureFrameRateController)?.registerCaptureRateConsumer(consumer, fps: fps)
    }
    func updateCaptureRate(_ fps: Int, consumer: ObjectIdentifier) {
        (localCapture as? CaptureFrameRateController)?.updateCaptureRate(fps, consumer: consumer)
    }
    func unregisterCaptureRateConsumer(_ consumer: ObjectIdentifier) {
        (localCapture as? CaptureFrameRateController)?.unregisterCaptureRateConsumer(consumer)
    }

    private struct WeakInput { weak var value: RoutedInput? }
    private final class RoutedInput: InputController {
        let id = UUID()
        let owner: SessionDesktopRouter
        let local: InputController
        var remote: InputController?
        var enabledEpoch: UInt64?
        var lastPosition: (UInt16, UInt16) = (0, 0)
        init(owner: SessionDesktopRouter, local: InputController, epoch: UInt64) {
            self.owner = owner; self.local = local; enabledEpoch = epoch
        }
        deinit { owner.lock.withLock { releaseLocked(); owner.inputs[id] = nil } }
        func destination() -> InputController {
            guard let shared = owner.remoteInputs else { return local }
            if remote == nil { remote = shared.makeClient() }
            return remote!
        }
        func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {
            owner.lock.withLock {
                guard enabledEpoch == owner.epoch else { return }
                destination().key(down: down, keysym: keysym, mapAltToCommand: mapAltToCommand)
            }
        }
        func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {
            owner.lock.withLock {
                guard enabledEpoch == owner.epoch else { return }
                guard let bridge = owner.remote else {
                    local.pointer(buttonMask: buttonMask, x: x, y: y, layout: layout); return
                }
                guard let canvas = owner.canvas, let fit = owner.fitted,
                      let frame = try? bridge.capture() else { return }
                let px = Int(x) * canvas.width / max(1, layout.width)
                let py = Int(y) * canvas.height / max(1, layout.height)
                if px >= fit.x, py >= fit.y, px < fit.x + fit.width, py < fit.y + fit.height {
                    lastPosition = (UInt16((px - fit.x) * frame.width / fit.width),
                                    UInt16((py - fit.y) * frame.height / fit.height))
                } else if buttonMask != 0 { return }
                destination().pointer(buttonMask: buttonMask, x: lastPosition.0, y: lastPosition.1, layout: frame.layout)
            }
        }
        func releaseLocked() { local.releaseKeys(); remote?.releaseKeys(); remote = nil }
        func releaseKeys() { owner.lock.withLock { releaseLocked() } }
        func resetClickSequence() { owner.lock.withLock { destination().resetClickSequence() } }
    }
    private final class RoutedClipboard: ClipboardBridge {
        let owner: SessionDesktopRouter
        let local: ClipboardBridge
        init(owner: SessionDesktopRouter, local: ClipboardBridge) { self.owner = owner; self.local = local }
        func currentContent() -> ClipboardContent? { owner.lock.withLock { owner.remote == nil ? local.currentContent() : nil } }
        func localContentIfChanged() -> ClipboardContent? { owner.lock.withLock { owner.remote == nil ? local.localContentIfChanged() : nil } }
        func setRemoteContent(_ content: ClipboardContent) {
            owner.lock.withLock { if owner.remote == nil { local.setRemoteContent(content) } }
        }
    }
}
