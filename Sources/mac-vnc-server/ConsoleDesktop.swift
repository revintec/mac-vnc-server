import Foundation

/// Stable RFB-facing desktop. Worker generations never share input ownership,
/// pixel sequences, or clipboard state. Only the latest complete frame is kept.
final class ConsoleDesktop: @unchecked Sendable, FramebufferSource, FramebufferSequenceSource, CaptureFrameRateController {
    let includesCursor = true
    private let changes = FrameChangeHub()
    var frameChanges: FrameChangeHub? { changes }
    private let lock = NSLock()
    private let identify: @Sendable () -> ConsoleIdentity?
    private var identity: ConsoleIdentity?
    private var generation: UUID?
    private var transport: ConsoleTransport?
    private var ready = false
    private var sequence: UInt64 = 0
    private var frame = Framebuffer(width: 640, height: 480,
        bgra: [UInt8](repeating: 0, count: 640 * 480 * 4),
        layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 640, height: 480))
    private var rates: [ObjectIdentifier: Int] = [:]
    private let defaultFPS: Int

    init(fps: Int, identify: @escaping @Sendable () -> ConsoleIdentity? = { ConsoleIdentity.current() }) {
        defaultFPS = fps; self.identify = identify
    }

    func begin(_ identity: ConsoleIdentity, transport: ConsoleTransport) -> UUID {
        invalidate()
        return lock.withLock {
            let token = UUID()
            self.identity = identity; generation = token; self.transport = transport
            return token
        }
    }

    @discardableResult
    func publish(_ info: ConsoleFrameInfo, pixels: [UInt8], generation token: UUID) throws -> Bool {
        let current = identify()
        let accepted = try lock.withLock {
            guard generation == token, identity == current else { return false }
            sequence &+= 1
            frame = try info.framebuffer(pixels: pixels, sequence: sequence)
            ready = true
            return true
        }
        if accepted { changes.signal() }
        return accepted
    }

    func invalidate(generation token: UUID? = nil) {
        let result: (ConsoleTransport?, Bool) = lock.withLock {
            guard token == nil || generation == token, generation != nil || ready else { return (nil, false) }
            let old = transport
            transport = nil; generation = nil; identity = nil; ready = false
            sequence &+= 1
            frame = Framebuffer(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow,
                bgra: [UInt8](repeating: 0, count: frame.bytesPerRow * frame.height),
                layout: frame.layout, sequence: sequence)
            return (old, true)
        }
        result.0?.shutdown()
        if result.1 { changes.signal() }
    }

    var hasReadyFrame: Bool { token() != nil }
    func isActive(_ token: UUID) -> Bool { lock.withLock { generation == token } }
    func token() -> UUID? {
        let current = identify()
        let state = lock.withLock { (generation, identity, ready) }
        guard let generation = state.0 else { return nil }
        guard current == state.1 else { invalidate(generation: generation); return nil }
        return state.2 ? generation : nil
    }

    func capture() throws -> Framebuffer {
        _ = token() // Invalidate immediately, even before the supervisor's poll.
        return lock.withLock { frame }
    }
    func currentSequence() throws -> UInt64? { try capture().sequence }
    func makeInput() -> InputController { ConsoleInputClient(desktop: self) }

    func send(_ message: ConsoleMessage, generation token: UUID) {
        guard self.token() == token else { return }
        let sink = lock.withLock { generation == token ? transport : nil }
        do { try sink?.send(message) }
        catch { invalidate(generation: token) }
    }

    func registerCaptureRateConsumer(_ consumer: ObjectIdentifier, fps: Int) {
        updateCaptureRate(fps, consumer: consumer, reconfigureCapture: true)
    }
    func updateCaptureRate(_ fps: Int, consumer: ObjectIdentifier, reconfigureCapture: Bool) {
        lock.withLock { rates[consumer] = fps }
        sendRate()
    }
    func unregisterCaptureRateConsumer(_ consumer: ObjectIdentifier) {
        _ = lock.withLock { rates.removeValue(forKey: consumer) }
        sendRate()
    }
    func sendRate() {
        guard let token = token() else { return }
        let fps = lock.withLock { rates.values.max() ?? defaultFPS }
        send(ConsoleMessage(kind: .fps, fps: fps), generation: token)
    }
}

/// A held key/button cannot become a fresh press in the next console session.
/// Suppress it until the viewer releases it, including input received while the
/// replacement worker is still starting. Aggregation happens inside the worker.
final class ConsoleInputClient: InputController {
    private let desktop: ConsoleDesktop
    private let id = UUID()
    private let lock = NSLock()
    private var generation: UUID?
    private var heldKeys: Set<UInt32> = []
    private var blockedKeys: Set<UInt32> = []
    private var heldButtons: UInt8 = 0
    private var blockedButtons: UInt8 = 0

    init(desktop: ConsoleDesktop) { self.desktop = desktop }
    deinit { releaseKeys() }

    private func synchronize(_ token: UUID?) {
        if generation != token {
            blockedKeys.formUnion(heldKeys)
            blockedButtons |= heldButtons
            generation = token
        }
    }

    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {
        lock.withLock {
            let token = desktop.token()
            synchronize(token)
            if down { heldKeys.insert(keysym) } else { heldKeys.remove(keysym) }
            if token == nil, down { blockedKeys.insert(keysym) }
            let blocked = blockedKeys.contains(keysym)
            if !down { blockedKeys.remove(keysym) }
            guard !blocked, let token else { return }
            desktop.send(ConsoleMessage(kind: .key, client: id, down: down, keysym: keysym,
                                        apple: mapAltToCommand), generation: token)
        }
    }
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {
        lock.withLock {
            let token = desktop.token()
            synchronize(token)
            heldButtons = buttonMask & 7
            blockedButtons &= heldButtons
            if token == nil { blockedButtons |= heldButtons }
            guard let token else { return }
            desktop.send(ConsoleMessage(kind: .pointer, client: id,
                mask: buttonMask & ~blockedButtons, x: x, y: y), generation: token)
        }
    }
    func releaseKeys() {
        lock.withLock {
            if let token = generation { desktop.send(ConsoleMessage(kind: .release, client: id), generation: token) }
            generation = nil; heldKeys.removeAll(); blockedKeys.removeAll()
            heldButtons = 0; blockedButtons = 0
        }
    }
}

struct ConsoleClipboard: ClipboardBridge {
    func currentContent() -> ClipboardContent? { nil }
    func localContentIfChanged() -> ClipboardContent? { nil }
    func setRemoteContent(_ content: ClipboardContent) {}
}
