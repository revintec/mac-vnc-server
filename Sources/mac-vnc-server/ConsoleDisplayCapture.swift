import CoreGraphics
import CoreVideo
import CVNCSession
import Foundation
import IOSurface

/// Request only display IDs valid in the attached worker's graphics session.
/// CoreGraphics can itself proxy through ScreenCaptureKit on newer macOS; this
/// backend does not establish that loginwindow capture is available. Never
/// substitute another session's display when the requested stream fails.
final class ConsoleDisplayCapture: @unchecked Sendable, FramebufferSource, FramebufferSequenceSource, CaptureFrameRateController {
    let includesCursor = true
    private let store: StreamingFrameStore
    private let outputs: [ConsoleDisplayOutput]
    private let lock = NSLock()
    private var streams: [VNCConsoleCaptureRef]
    private var rates: [ObjectIdentifier: Int] = [:]
    private let fps: Int
    private let logger: ServerLogger
    private var waking = false
    private var stopped = false
    private let changes = FrameChangeHub()
    var frameChanges: FrameChangeHub? { changes }

    init(scale: Double, fps: Int, displaySelection: DisplaySelection, logger: ServerLogger) throws {
        self.fps = fps; self.logger = logger
        let available = try MacScreenCapture.activeDisplayIDs()
        let selected: [CGDirectDisplayID]
        if case .display(let index) = displaySelection {
            guard available.indices.contains(index - 1) else {
                throw RFBError.captureFailed("console display \(index) is unavailable")
            }
            selected = [available[index - 1]]
        } else { selected = available }
        let displays = selected.map { id in
            VirtualDisplay(id: id, bounds: CGDisplayBounds(id),
                pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id))
        }
        let layout = try Self.makeLayout(displays: displays, scale: scale)
        let store = StreamingFrameStore(layout: layout, expectedDisplayIDs: Set(selected),
            acceptedFrameRate: fps, changes: changes)
        self.store = store
        var streams: [VNCConsoleCaptureRef] = []
        var outputs: [ConsoleDisplayOutput] = []
        do {
            for display in displays {
                let width = max(1, Int(ceil(display.bounds.width * scale)))
                let height = max(1, Int(ceil(display.bounds.height * scale)))
                let output = ConsoleDisplayOutput(displayID: display.id, width: width, height: height, store: store)
                outputs.append(output)
                var error = VNCConsoleCaptureError()
                logger.verbose("Console capture: starting CoreGraphics display \(display.id) (\(width)x\(height)) bounds=\(display.bounds)")
                guard let stream = VNCConsoleCaptureStart(display.id, width, height, Int32(fps),
                    { context, status, surface in
                        guard let context else { return }
                        Unmanaged<ConsoleDisplayOutput>.fromOpaque(context).takeUnretainedValue()
                            .receive(status: status, surface: surface)
                    }, Unmanaged.passUnretained(output).toOpaque(), &error) else {
                    throw RFBError.captureFailed("console display \(display.id): \(Self.describe(error)); no user-desktop fallback")
                }
                streams.append(stream)
            }
        } catch {
            for stream in streams { VNCConsoleCaptureStop(stream) }
            throw error
        }
        self.streams = streams
        self.outputs = outputs
    }

    deinit { for stream in streams { VNCConsoleCaptureStop(stream) } }

    static func describe(_ error: VNCConsoleCaptureError) -> String {
        switch error.stage {
        case VNCConsoleCaptureStageCreate:
            return "CGDisplayStreamCreateWithDispatchQueue returned NULL before start (macOS supplied no error code); loginwindow capture is not available through this request"
        case VNCConsoleCaptureStageStart:
            return "CGDisplayStreamStart failed (CGError \(error.code))"
        case VNCConsoleCaptureStageSymbols:
            return "CoreGraphics display-stream symbols are unavailable"
        case VNCConsoleCaptureStageArguments:
            return "invalid display-stream arguments (errno \(error.code))"
        case VNCConsoleCaptureStageAllocation:
            return "display-stream allocation failed (errno \(error.code))"
        default:
            return "display-stream setup failed at an unknown stage (\(error.stage.rawValue))"
        }
    }

    static func makeLayout(displays: [VirtualDisplay], scale: Double) throws -> VirtualDisplayLayout {
        guard !displays.isEmpty, displays.count <= 32, scale.isFinite, scale > 0, scale <= 4,
              displays.allSatisfy({
                  $0.bounds.origin.x.isFinite && $0.bounds.origin.y.isFinite &&
                  $0.bounds.size.width.isFinite && $0.bounds.size.height.isFinite &&
                  $0.bounds.size.width > 0 && $0.bounds.size.height > 0 &&
                  (1...65535).contains($0.pixelWidth) && (1...65535).contains($0.pixelHeight)
              }) else { throw RFBError.captureFailed("console has no valid CoreGraphics display geometry") }
        let union = displays.dropFirst().reduce(displays[0].bounds) { $0.union($1.bounds) }
        let width = ceil(union.width * scale), height = ceil(union.height * scale)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 65535, height <= 65535, max(1, width) * max(1, height) * 4 <= Double(ConsoleTransport.maximumPixels) else {
            throw RFBError.captureFailed("console display layout exceeds framebuffer limits")
        }
        return VirtualDisplayLayout(displays: displays, scaleOverride: scale)
    }

    func waitUntilReady() async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !store.waitForFirstFrames(timeout: 0) {
            try Task.checkCancellation()
            try checkStreams()
            guard ContinuousClock.now < deadline else {
                throw RFBError.captureFailed("console display stream did not deliver a frame within 8 seconds")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func checkStreams() throws {
        if let failure = outputs.compactMap({ $0.failure }).first { throw RFBError.captureFailed(failure) }
        guard !lock.withLock({ stopped }) else { throw CancellationError() }
    }
    func capture() throws -> Framebuffer { try checkStreams(); return try store.snapshot() }
    func currentSequence() throws -> UInt64? { try checkStreams(); return try store.currentSequence() }

    func stop() {
        let old = lock.withLock { stopped = true; let old = streams; streams = []; return old }
        for stream in old { VNCConsoleCaptureStop(stream) }
        if !old.isEmpty { logger.verbose("Console capture: stopped") }
    }

    func requestRecoveryAfterInput() {
        guard outputs.contains(where: { $0.isBlank }) else { return }
        let start = lock.withLock {
            guard !waking, !stopped else { return false }
            waking = true; return true
        }
        if start {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { lock.withLock { waking = false } }
                do { try DisplayWakeup.signal() }
                catch { logger.warning("console display wake failed: \(error.localizedDescription)") }
            }
        }
    }

    func registerCaptureRateConsumer(_ consumer: ObjectIdentifier, fps: Int) {
        updateCaptureRate(fps, consumer: consumer, reconfigureCapture: true)
    }
    func updateCaptureRate(_ fps: Int, consumer: ObjectIdentifier, reconfigureCapture: Bool) {
        let target = lock.withLock { rates[consumer] = fps; return rates.values.max() ?? self.fps }
        store.setAcceptedFrameRate(target)
    }
    func unregisterCaptureRateConsumer(_ consumer: ObjectIdentifier) {
        let target = lock.withLock { rates.removeValue(forKey: consumer); return rates.values.max() ?? fps }
        store.setAcceptedFrameRate(target)
    }
}

final class ConsoleDisplayOutput: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let width: Int, height: Int
    let store: StreamingFrameStore
    private let lock = NSLock()
    private var error: String?
    private var blank = false
    var failure: String? { lock.withLock { error } }
    var isBlank: Bool { lock.withLock { blank } }

    init(displayID: CGDirectDisplayID, width: Int, height: Int, store: StreamingFrameStore) {
        self.displayID = displayID; self.width = width; self.height = height; self.store = store
    }

    func receive(status: Int32, surface: IOSurfaceRef?) {
        if status == 3 { // kCGDisplayStreamFrameStatusStopped
            lock.withLock { error = "console display \(displayID) stream stopped" }
            return
        }
        var buffer: CVPixelBuffer?
        if status == 2 { // kCGDisplayStreamFrameStatusFrameBlank
            guard !isBlank else { return }
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                nil, &buffer) == kCVReturnSuccess, let buffer,
                CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
            memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
        } else {
            guard status == 0, let surface else { return } // complete, not idle
            var created: Unmanaged<CVPixelBuffer>?
            let result = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &created)
            buffer = created?.takeRetainedValue()
            guard result == kCVReturnSuccess else {
                lock.withLock { error = "could not read console display \(displayID) surface" }
                return
            }
        }
        guard let buffer else { return }
        lock.withLock { blank = status == 2 }
        // StreamingFrameStore copies synchronously; the IOSurface is not kept
        // beyond this callback and can be reused by WindowServer immediately.
        store.update(displayID: displayID, pixelBuffer: buffer, dirtyRects: nil,
            presentationTime: status == 0 ? ProcessInfo.processInfo.systemUptime : nil)
    }
}
