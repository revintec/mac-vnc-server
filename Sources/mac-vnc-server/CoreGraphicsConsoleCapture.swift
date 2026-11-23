import CoreGraphics
import CoreVideo
import CVNCSession
import Foundation
import IOSurface

/// Ventura-only loginwindow capture. The RFB connection stays in the original
/// account worker; this source runs after root's fresh audit-session attachment.
final class CoreGraphicsConsoleCapture: @unchecked Sendable, SessionScreenCapture,
    FramebufferSequenceSource, InputRecoverySource, CaptureFrameRateController {
    let includesCursor: Bool
    private let cursorMonitor: MacCursorMonitor?
    var cursorSnapshot: CursorSnapshot? { cursorMonitor?.snapshot }
    let frames: ConsoleCaptureFrames
    var frameChanges: FrameChangeHub? { frames.changes }
    private let logger: ServerLogger
    private let displayIDs: [CGDirectDisplayID]
    private let lock = NSLock()
    private var streams: [OpaquePointer] = []
    private var consumers: [ObjectIdentifier: Int] = [:]
    private var waking = false
    private var stopped = false

    init(scale: Double, fps: Int, displaySelection: DisplaySelection,
         identity: ConsoleIdentity, logger: ServerLogger, cursorMode: CursorMode = .auto) async throws {
        guard identity.uid == 0 else { throw RFBError.captureFailed("CoreGraphics console capture requires a root loginwindow worker") }
        self.logger = logger
        let verify: @Sendable () throws -> Void = {
            guard identity.verifyWorker() else {
                throw RFBError.captureFailed("console identity changed; CoreGraphics capture stopped")
            }
        }
        try verify()
        let offered = try await CaptureDisplayDiscovery.run(logger: logger, backend: "CoreGraphics", verify: verify) {
            try verify()
            let ids = try MacDisplays.activeDisplayIDs()
            guard !ids.isEmpty else { throw CaptureDisplaysUnavailable.empty }
            return ids.map { VirtualDisplay(id: $0, bounds: CGDisplayBounds($0),
                pixelWidth: CGDisplayPixelsWide($0), pixelHeight: CGDisplayPixelsHigh($0)) }
        }
        _ = try StreamingScreenCapture.consoleLayout(displays: offered, scale: scale)
        let selected: [VirtualDisplay]
        switch displaySelection {
        case .all: selected = offered
        case .display(let index):
            guard offered.indices.contains(index - 1) else {
                throw RFBError.captureFailed("display \(index) is not available; found \(offered.count) display(s)")
            }
            selected = [offered[index - 1]]
        }
        let layout = try StreamingScreenCapture.consoleLayout(displays: selected, scale: scale)
        displayIDs = selected.map(\.id)
        try Self.wakeIfAsleep(verify: verify, isAsleep: { selected.contains { CGDisplayIsAsleep($0.id) != 0 } }, logger: logger)
        frames = ConsoleCaptureFrames(layout: layout, fps: fps) {
            try verify()
            let current = try MacDisplays.activeDisplayIDs().map {
                VirtualDisplay(id: $0, bounds: CGDisplayBounds($0),
                    pixelWidth: CGDisplayPixelsWide($0), pixelHeight: CGDisplayPixelsHigh($0))
            }
            try Self.validateGeometry(expected: offered, current: current)
        }
        let changes = frames.changes
        cursorMonitor = cursorMode == .embedded ? nil : await MacCursorMonitor.start(onChange: { changes.signal() })
        includesCursor = cursorMonitor == nil
        logger.info("CoreGraphics: starting verified loginwindow capture uid=0 audit=\(identity.auditID); no auxiliary replayd service")
        logger.info("cursor: \(includesCursor ? "embedded in framebuffer" : "client-rendered shapes; embedded fallback for viewers without RichCursor")")
        do {
            for display in selected {
                try verify()
                let size = layout.framebufferRect(for: display)
                let output = ConsoleDisplayOutput(displayID: display.id, frames: frames)
                var error: Int32 = 0
                let handle = VNCDisplayStreamCreate(display.id, UInt32(ceil(size.width)), UInt32(ceil(size.height)), Int32(fps),
                    includesCursor ? 1 : 0,
                    { context, status, seconds, surface in
                        guard let context else { return }
                        Unmanaged<ConsoleDisplayOutput>.fromOpaque(context).takeUnretainedValue()
                            .receive(status: status, seconds: seconds, surface: surface)
                    }, Unmanaged.passRetained(output).toOpaque(),
                    { context in if let context { Unmanaged<ConsoleDisplayOutput>.fromOpaque(context).release() } }, &error)
                guard let handle else {
                    if error == ENOTSUP { throw RFBError.captureFailed("the macOS CoreGraphics streaming API is unavailable") }
                    if error == VNCDisplayStreamCreateReturnedNull {
                        throw RFBError.captureFailed("CGDisplayStreamCreate returned no stream for display \(display.id); macOS supplied no reason")
                    }
                    throw RFBError.captureFailed("CoreGraphics could not start display \(display.id) (code \(error))")
                }
                streams.append(handle)
                logger.verbose("CoreGraphics: streaming display \(display.id) (\(Int(ceil(size.width)))x\(Int(ceil(size.height))))")
            }
            guard frames.waitForFirstFrames(timeout: 5) else {
                try frames.check()
                let asleep = selected.contains { CGDisplayIsAsleep($0.id) != 0 }
                throw RFBError.captureFailed("CoreGraphics did not produce a complete loginwindow frame within 5 seconds (display_asleep=\(asleep)); turn on the physical display and retry")
            }
            try frames.check()
            logger.info("CoreGraphics: first loginwindow frame ready")
        } catch {
            await stop()
            throw error
        }
    }

    static func wakeIfAsleep(verify: () throws -> Void, isAsleep: () -> Bool,
                            wake: () throws -> Void = DisplayWakeup.signal, logger: ServerLogger) throws {
        try verify()
        guard isAsleep() else { return }
        try verify()
        logger.info("CoreGraphics: physical display is asleep; requesting display wake before capture")
        try wake()
        try verify()
    }

    static func validateGeometry(expected: [VirtualDisplay], current: [VirtualDisplay]) throws {
        guard expected.count == current.count,
              expected.allSatisfy({ current.contains($0) }) else {
            throw RFBError.captureFailed("console display geometry changed; retry viewing the console")
        }
    }

    func capture() throws -> Framebuffer { try frames.snapshot() }
    func currentSequence() throws -> UInt64? { try frames.currentSequence() }

    func stop() async {
        cursorMonitor?.stop()
        let retired = lock.withLock {
            stopped = true
            let retired = streams; streams.removeAll()
            return retired
        }
        frames.stop()
        for stream in retired {
            let error = VNCDisplayStreamDestroy(stream)
            if error != 0 { logger.warning("CoreGraphics capture stop returned code \(error)") }
        }
        if !retired.isEmpty { logger.verbose("CoreGraphics: capture stopped") }
    }

    func requestRecoveryAfterInput() {
        guard frames.isBlank || displayIDs.contains(where: { CGDisplayIsAsleep($0) != 0 }) else { return }
        let start = lock.withLock { () -> Bool in
            guard !stopped, !waking else { return false }
            waking = true; return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { lock.withLock { waking = false } }
            do { try frames.check(); try DisplayWakeup.signal() }
            catch { logger.warning("CoreGraphics display wake failed: \(error.localizedDescription)") }
        }
    }

    func registerCaptureRateConsumer(_ consumer: ObjectIdentifier, fps: Int) { updateCaptureRate(fps, consumer: consumer) }
    func updateCaptureRate(_ fps: Int, consumer: ObjectIdentifier) {
        lock.withLock {
            consumers[consumer] = fps
            frames.store.setAcceptedFrameRate(consumers.values.max() ?? fps)
        }
    }
    func unregisterCaptureRateConsumer(_ consumer: ObjectIdentifier) {
        lock.withLock {
            consumers.removeValue(forKey: consumer)
            if let fps = consumers.values.max() { frames.store.setAcceptedFrameRate(fps) }
        }
    }
}

/// Copies borrowed display surfaces synchronously. Shared frame storage and RFB
/// pacing/encoding remain the same as ScreenCaptureKit's pipeline.
final class ConsoleCaptureFrames: @unchecked Sendable {
    let changes = FrameChangeHub()
    let store: StreamingFrameStore
    private let layout: VirtualDisplayLayout
    private let verify: @Sendable () throws -> Void
    private let lock = NSRecursiveLock()
    private var failure: (any Error)?
    private var stopped = false
    private var blankDisplays: Set<CGDirectDisplayID> = []
    private var completeDisplays: Set<CGDirectDisplayID> = []
    private let firstFrames = DispatchSemaphore(value: 0)
    var isBlank: Bool { lock.withLock { !blankDisplays.isEmpty } }

    init(layout: VirtualDisplayLayout, fps: Int, verify: @escaping @Sendable () throws -> Void) {
        self.layout = layout; self.verify = verify
        store = StreamingFrameStore(layout: layout, expectedDisplayIDs: Set(layout.displays.map(\.id)),
            acceptedFrameRate: fps, changes: changes)
    }

    func check() throws {
        try verify()
        try lock.withLock {
            if let failure { throw failure }
            if stopped { throw RFBError.captureFailed("CoreGraphics capture stopped") }
        }
    }
    func stop() { lock.withLock { stopped = true }; firstFrames.signal(); changes.signal() }
    func waitForFirstFrames(timeout: TimeInterval) -> Bool {
        let ready = { self.lock.withLock { self.completeDisplays.count == self.layout.displays.count && self.failure == nil && !self.stopped } }
        if ready() { return store.waitForFirstFrames(timeout: 0) }
        _ = firstFrames.wait(timeout: .now() + timeout)
        return ready() && store.waitForFirstFrames(timeout: 0)
    }
    func snapshot() throws -> Framebuffer {
        try check()
        let frame = try store.snapshot()
        try check()
        return frame
    }
    func currentSequence() throws -> UInt64? { try check(); return try store.currentSequence() }

    func receive(displayID: CGDirectDisplayID, status: Int, pixelBuffer: CVPixelBuffer?, seconds: Double?) {
        lock.withLock {
            guard !stopped, failure == nil else { return }
            do {
                try verify()
                guard let display = layout.displays.first(where: { $0.id == displayID }) else {
                    throw RFBError.captureFailed("CoreGraphics returned an unexpected display")
                }
                if status == VNCDisplayFrameIdle { return }
                if status == VNCDisplayFrameStopped {
                    throw RFBError.captureFailed("CoreGraphics display stream ended; retry viewing the console")
                }
                let rect = layout.framebufferRect(for: display)
                let width = Int(ceil(rect.width)), height = Int(ceil(rect.height))
                var buffer = pixelBuffer
                var timestamp = seconds
                if status == VNCDisplayFrameBlank {
                    guard !blankDisplays.contains(displayID) else { return }
                    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                          let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
                        throw RFBError.captureFailed("could not clear blank console display")
                    }
                    memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetBytesPerRow(buffer) * height)
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    blankDisplays.insert(displayID)
                    completeDisplays.remove(displayID)
                    timestamp = nil
                } else if status == VNCDisplayFrameComplete {
                    if blankDisplays.remove(displayID) != nil { timestamp = nil }
                } else { return }
                guard let buffer, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                      CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else {
                    throw RFBError.captureFailed("CoreGraphics frame geometry or pixel format changed; retry viewing the console")
                }
                store.update(displayID: displayID, pixelBuffer: buffer, dirtyRects: nil, presentationTime: timestamp)
                if status == VNCDisplayFrameComplete, completeDisplays.insert(displayID).inserted,
                   completeDisplays.count == layout.displays.count { firstFrames.signal() }
            } catch { failure = error; firstFrames.signal(); changes.signal() }
        }
    }
}

private final class ConsoleDisplayOutput: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let frames: ConsoleCaptureFrames
    init(displayID: CGDirectDisplayID, frames: ConsoleCaptureFrames) { self.displayID = displayID; self.frames = frames }
    func receive(status: Int32, seconds: Double, surface: IOSurfaceRef?) {
        var buffer: CVPixelBuffer?
        if status == VNCDisplayFrameComplete, let surface {
            var wrapped: Unmanaged<CVPixelBuffer>?
            if CVPixelBufferCreateWithIOSurface(nil, surface, nil, &wrapped) == kCVReturnSuccess {
                buffer = wrapped?.takeRetainedValue()
            }
        }
        frames.receive(displayID: displayID, status: Int(status), pixelBuffer: buffer, seconds: seconds)
    }
}
