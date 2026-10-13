import Darwin
import Foundation

enum ConsoleWorker {
    static func run(_ options: ConsoleWorkerOptions) async throws {
        guard options.identity.verifyWorker() else { throw CLIError.commandFailed("console worker identity changed before capture") }
        let transport = try ConsoleTransport(fd: dup(STDIN_FILENO))
        let logger = ServerLogger(verbose: options.verbose)
        let capture = try ConsoleDisplayCapture(scale: options.scale, fps: options.fps,
            displaySelection: options.display == 0 ? .all : .display(options.display),
            logger: logger)
        do { try await capture.waitUntilReady() }
        catch { capture.stop(); throw error }
        let controls: ConsoleWorkerControls
        do { controls = try ConsoleWorkerControls(identity: options.identity, capture: capture) }
        catch { capture.stop(); throw error }
        logger.info("Console input: \(options.identity.uid == 0 ? "IOHIDSystem (loginwindow)" : "CoreGraphics session tap")")
        let reader = Task.detached {
            defer { controls.stop(); transport.shutdown() }
            do {
                while !Task.isCancelled {
                    let (message, _) = try transport.receive()
                    try controls.apply(message)
                }
            } catch { logger.verbose("Console input stopped: \(error.localizedDescription)") }
        }
        do {
            var previousSequence: UInt64?
            var sentFrame = false
            var heartbeat = ContinuousClock.now
            while !Task.isCancelled, !controls.stopped {
                guard options.identity.verifyWorker() else { break }
                let sequence = try capture.currentSequence()
                if !sentFrame || sequence == nil || sequence != previousSequence {
                    let frame = try capture.capture()
                    guard options.identity.verifyWorker() else { break }
                    let info = ConsoleFrameInfo(frame)
                    try info.validate(pixelCount: frame.bgra.count)
                    controls.setLayout(frame.layout)
                    try transport.send(ConsoleMessage(kind: .frame, frame: info), pixels: frame.bgra)
                    previousSequence = sequence; sentFrame = true
                    heartbeat = .now + .seconds(1)
                } else if ContinuousClock.now >= heartbeat {
                    try transport.send(ConsoleMessage(kind: .heartbeat))
                    heartbeat = .now + .seconds(1)
                }
                // Capture coalesces while IPC is busy; no queue of old frames.
                try await Task.sleep(for: .nanoseconds(1_000_000_000 / options.fps))
            }
        } catch {
            controls.stop(); transport.shutdown(); reader.cancel()
            await reader.value; capture.stop()
            throw error
        }
        controls.stop(); transport.shutdown(); reader.cancel()
        await reader.value; capture.stop()
    }
}

private final class ConsoleWorkerControls: @unchecked Sendable {
    let identity: ConsoleIdentity
    let capture: ConsoleDisplayCapture
    let shared: SharedInputController
    private let rootInput: ConsoleRootInput?
    private let lock = NSLock()
    private var clients: [UUID: InputController] = [:]
    private var layout: VirtualDisplayLayout?
    private var didStop = false
    var stopped: Bool { lock.withLock { didStop } }

    init(identity: ConsoleIdentity, capture: ConsoleDisplayCapture) throws {
        self.identity = identity; self.capture = capture
        // Console input includes login credentials. Keep warnings, but never
        // print keysyms or typed characters, including with --verbose.
        let rootInput = identity.uid == 0 ? try ConsoleRootInput(identity: identity) : nil
        self.rootInput = rootInput
        let logger = ServerLogger(verbose: false)
        let input = if let rootInput {
            MacInputController(logger: logger, postEvent: { _, event in rootInput.post(event) })
        } else { MacInputController(logger: logger) }
        shared = SharedInputController(input: input)
    }
    func setLayout(_ layout: VirtualDisplayLayout) { lock.withLock { self.layout = layout } }
    func apply(_ message: ConsoleMessage) throws {
        guard identity.verifyWorker() else { throw CLIError.commandFailed("console session changed; input rejected") }
        try lock.withLock {
            guard !didStop else { return }
            if message.kind == .heartbeat { return }
            if message.kind == .fps, let fps = message.fps, (1...120).contains(fps) {
                capture.updateCaptureRate(fps, consumer: ObjectIdentifier(self), reconfigureCapture: true)
                return
            }
            guard let clientID = message.client else { throw RFBError.protocolError("missing console input owner") }
            if message.kind == .release {
                clients.removeValue(forKey: clientID)?.releaseKeys()
                try rootInput?.checkDelivery()
                return
            }
            guard let layout else { return }
            guard clients.count < 32 || clients[clientID] != nil else { throw RFBError.protocolError("too many console input owners") }
            let client = clients[clientID] ?? shared.makeClient()
            clients[clientID] = client
            capture.requestRecoveryAfterInput()
            switch message.kind {
            case .key:
                guard let down = message.down, let keysym = message.keysym, let apple = message.apple else {
                    throw RFBError.protocolError("incomplete console key event")
                }
                client.key(down: down, keysym: keysym, mapAltToCommand: apple)
            case .pointer:
                guard let mask = message.mask, let x = message.x, let y = message.y else {
                    throw RFBError.protocolError("incomplete console pointer event")
                }
                client.pointer(buttonMask: mask, x: x, y: y, layout: layout)
            default: throw RFBError.protocolError("unexpected console control message")
            }
            try rootInput?.checkDelivery()
        }
    }
    func stop() {
        lock.withLock {
            guard !didStop else { return }
            didStop = true
            for client in clients.values { client.releaseKeys() }
            clients.removeAll()
        }
    }
}
