import CoreGraphics
import CoreMedia
import CoreVideo
import AppKit
import Foundation
import ScreenCaptureKit

final class StreamingScreenCapture: @unchecked Sendable, FramebufferSource, FramebufferSequenceSource, InputRecoverySource, CaptureFrameRateController {
    let includesCursor: Bool
    private let changes = FrameChangeHub()
    var frameChanges: FrameChangeHub? { changes }
    private let cursorMonitor: MacCursorMonitor?
    var cursorSnapshot: CursorSnapshot? { cursorMonitor?.snapshot }
    private let scale: CGFloat
    private let fps: Int
    private let displaySelection: DisplaySelection
    private let logger: ServerLogger
    private let streamEventSink: StreamEventSink
    private let stateLock = NSLock()
    private let recoveryLock = NSLock()
    private var store: StreamingFrameStore
    private var streams: [SCStream]
    private var streamConfigurations: [SCStreamConfiguration]
    private var outputs: [ScreenCaptureStreamOutput]
    private var delegates: [ScreenCaptureStreamDelegate]
    private let captureRateLock = NSLock()
    private var captureRateRequests: [ObjectIdentifier: Int] = [:]
    private var desiredCaptureFPS: Int
    private var captureRateTask: Task<Void, Never>?
    private var captureRateStopped = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var recoveryScheduled = false
    private var recoveryNeeded = false
    private var recoveryRequestSerial: UInt64 = 0
    private var recoveryReason = ""
    private var displayWakeScheduled = false
    private var stopping = false
    private var recoveryTask: Task<Void, Never>?

    init(
        scale: Double,
        fps: Int,
        displaySelection: DisplaySelection,
        logger: ServerLogger,
        cursorMode: CursorMode = .auto
    ) async throws {
        self.scale = CGFloat(scale)
        self.fps = fps
        self.displaySelection = displaySelection
        self.logger = logger
        desiredCaptureFPS = fps
        captureRateTask = nil

        cursorMonitor = cursorMode == .embedded ? nil : await MacCursorMonitor.start()
        includesCursor = cursorMonitor == nil
        logger.info("cursor: \(includesCursor ? "embedded in framebuffer" : "client-rendered shapes; embedded fallback for viewers without RichCursor")")

        let eventSink = StreamEventSink()
        let started = try await Self.start(
            scale: self.scale,
            fps: fps,
            displaySelection: displaySelection,
            includesCursor: includesCursor,
            eventSink: eventSink,
            changes: changes,
            logger: logger
        )

        guard started.store.waitForFirstFrames(timeout: 5) else {
            await Self.stopStreams(started.streams, logger: logger)
            throw RFBError.captureFailed("ScreenCaptureKit did not produce frames; check Screen Recording permission")
        }

        streamEventSink = eventSink
        store = started.store
        streams = started.streams
        streamConfigurations = started.configurations
        outputs = started.outputs
        delegates = started.delegates
        eventSink.attach(owner: self)
        // Fast User Switching can replace display IDs without stopping every
        // SCStream. Re-enumerate the displays in this user's session on both
        // transitions, including when the old stream silently stops delivering.
        for (notification, reason) in [
            (NSWorkspace.screensDidWakeNotification, "screens did wake"),
            (NSWorkspace.sessionDidResignActiveNotification, "user session moved off console"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "user session returned to console")
        ] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: notification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.scheduleRecovery(reason: reason)
            })
        }
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func stop() async {
        let recovery = recoveryLock.withLock {
            stopping = true
            recoveryTask?.cancel()
            return recoveryTask
        }
        let rateUpdate = captureRateLock.withLock {
            captureRateStopped = true
            captureRateTask?.cancel()
            return captureRateTask
        }
        await recovery?.value
        await rateUpdate?.value
        await Self.stopStreams(currentStreams(), logger: logger)
        logger.verbose("ScreenCaptureKit: capture stopped")
    }

    func capture() throws -> Framebuffer {
        try currentStore().snapshot()
    }

    func capture(displayIndex: Int) throws -> Framebuffer {
        try currentStore().snapshot(displayIndex: displayIndex)
    }

    func currentSequence() throws -> UInt64? {
        try currentStore().currentSequence()
    }

    func currentSequence(displayIndex: Int) throws -> UInt64? {
        try currentStore().currentSequence(displayIndex: displayIndex)
    }

    func requestRecoveryAfterInput() {
        recoveryLock.lock()
        let needed = recoveryNeeded
        recoveryLock.unlock()

        guard needed else {
            return
        }
        scheduleDisplayWakeup()
        scheduleRecovery(reason: "input received")
    }

    func registerCaptureRateConsumer(_ consumer: ObjectIdentifier, fps: Int) {
        captureRateLock.lock()
        captureRateRequests[consumer] = fps
        let target = effectiveCaptureFPSLocked()
        let shouldSchedule = target != desiredCaptureFPS
        desiredCaptureFPS = target
        captureRateLock.unlock()

        updateFrameAcceptanceRate(target)
        if shouldSchedule {
            scheduleCaptureRateUpdate()
        }
    }

    func updateCaptureRate(
        _ fps: Int,
        consumer: ObjectIdentifier,
        reconfigureCapture: Bool
    ) {
        captureRateLock.lock()
        captureRateRequests[consumer] = fps
        let target = effectiveCaptureFPSLocked()
        let shouldSchedule = target != desiredCaptureFPS
        desiredCaptureFPS = target
        captureRateLock.unlock()

        updateFrameAcceptanceRate(target)
        if shouldSchedule, reconfigureCapture {
            scheduleCaptureRateUpdate()
        }
    }

    func unregisterCaptureRateConsumer(_ consumer: ObjectIdentifier) {
        captureRateLock.lock()
        captureRateRequests.removeValue(forKey: consumer)
        let target = effectiveCaptureFPSLocked()
        let shouldSchedule = target != desiredCaptureFPS
        desiredCaptureFPS = target
        captureRateLock.unlock()

        updateFrameAcceptanceRate(target)
        if shouldSchedule {
            scheduleCaptureRateUpdate()
        }
    }

    private func updateFrameAcceptanceRate(_ fps: Int) {
        currentStore().setAcceptedFrameRate(fps)
    }

    private func scheduleDisplayWakeup() {
        recoveryLock.lock()
        guard !stopping, !displayWakeScheduled else {
            recoveryLock.unlock()
            return
        }
        displayWakeScheduled = true
        recoveryLock.unlock()

        Task.detached { [weak self] in
            guard let self else {
                return
            }
            defer { self.finishDisplayWakeup() }

            do {
                try DisplayWakeup.signal()
                self.logger.info("Sent display wake signal after remote input.")
            } catch {
                self.logger.warning("display wake signal failed: \(error.localizedDescription)")
            }
        }
    }

    private func finishDisplayWakeup() {
        recoveryLock.lock()
        displayWakeScheduled = false
        recoveryLock.unlock()
    }

    private func currentStore() -> StreamingFrameStore {
        stateLock.lock()
        defer { stateLock.unlock() }
        return store
    }

    private func effectiveCaptureFPSLocked() -> Int {
        captureRateRequests.values.max() ?? fps
    }

    private func scheduleCaptureRateUpdate() {
        captureRateLock.lock()
        guard !captureRateStopped, captureRateTask == nil else {
            captureRateLock.unlock()
            return
        }
        captureRateTask = Task { [weak self] in
            await self?.applyCaptureRateUpdates()
        }
        captureRateLock.unlock()
    }

    private func applyCaptureRateUpdates() async {
        while !Task.isCancelled {
            let target = captureRateTarget()
            let (currentStreams, currentConfigurations) = streamConfigurationSnapshot()

            for (stream, configuration) in zip(currentStreams, currentConfigurations) {
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(target))
                do {
                    try await CaptureOperation.run("update configuration") { complete in
                        stream.updateConfiguration(configuration) { error in
                            complete(error.map { .failure($0) } ?? .success(()))
                        }
                    }
                } catch {
                    logger.warning("ScreenCaptureKit frame-rate update to \(target) FPS failed: \(error.localizedDescription)")
                }
            }

            if finishCaptureRateUpdateIfUnchanged(target) {
                return
            }
        }
    }

    private func captureRateTarget() -> Int {
        captureRateLock.lock()
        defer { captureRateLock.unlock() }
        return desiredCaptureFPS
    }

    private func streamConfigurationSnapshot() -> ([SCStream], [SCStreamConfiguration]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (streams, streamConfigurations)
    }

    private func finishCaptureRateUpdateIfUnchanged(_ target: Int) -> Bool {
        captureRateLock.lock()
        defer { captureRateLock.unlock() }
        guard desiredCaptureFPS == target else {
            return false
        }
        captureRateTask = nil
        return true
    }

    static func displayCount() async throws -> Int {
        let content = try await shareableContent(onScreenWindowsOnly: true)
        return content.displays.count
    }

    private static func shareableContent(onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        // The framework's immutable snapshot is read only after its callback.
        struct Content: @unchecked Sendable { let value: SCShareableContent }
        let content: Content = try await CaptureOperation.run("enumerate displays", timeout: 60) { complete in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: onScreenWindowsOnly) { content, error in
                if let error { complete(.failure(error)) }
                else if let content { complete(.success(Content(value: content))) }
                else { complete(.failure(RFBError.captureFailed("ScreenCaptureKit returned no shareable content"))) }
            }
        }
        return content.value
    }

    private static func start(
        scale: CGFloat,
        fps: Int,
        displaySelection: DisplaySelection,
        includesCursor: Bool,
        eventSink: StreamEventSink,
        changes: FrameChangeHub,
        logger: ServerLogger
    ) async throws -> StartedCapture {
        logger.verbose("ScreenCaptureKit: enumerating displays")
        let content = try await shareableContent(onScreenWindowsOnly: false)
        let selectedDisplays = try selectDisplays(from: orderedDisplays(content.displays), displaySelection: displaySelection)
        let displays = selectedDisplays.map { display in
            VirtualDisplay(
                id: display.displayID,
                bounds: CGDisplayBounds(display.displayID),
                pixelWidth: display.width,
                pixelHeight: display.height
            )
        }
        guard !displays.isEmpty else {
            throw RFBError.captureFailed("ScreenCaptureKit found no displays")
        }

        let layout = VirtualDisplayLayout(displays: displays, scaleOverride: scale)
        let store = StreamingFrameStore(
            layout: layout,
            expectedDisplayIDs: Set(displays.map(\.id)),
            acceptedFrameRate: fps,
            changes: changes
        )
        var streams: [SCStream] = []
        var configurations: [SCStreamConfiguration] = []
        var outputs: [ScreenCaptureStreamOutput] = []
        var delegates: [ScreenCaptureStreamDelegate] = []

        do {
            for display in selectedDisplays {
                let bounds = CGDisplayBounds(display.displayID)
                let width = max(1, Int(bounds.width * scale))
                let height = max(1, Int(bounds.height * scale))
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                config.queueDepth = 3
                config.showsCursor = includesCursor

                let delegate = ScreenCaptureStreamDelegate(eventSink: eventSink)
                let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
                let output = ScreenCaptureStreamOutput(displayID: display.displayID, store: store)
                try stream.addStreamOutput(
                    output,
                    type: .screen,
                    sampleHandlerQueue: DispatchQueue(label: "mac-vnc-server.sck.\(display.displayID)")
                )
                streams.append(stream)
                configurations.append(config)
                outputs.append(output)
                delegates.append(delegate)
                logger.verbose("ScreenCaptureKit: starting display \(display.displayID) (\(width)x\(height))")
                try await CaptureOperation.run("start display \(display.displayID)") { complete in
                    stream.startCapture { error in
                        complete(error.map { .failure($0) } ?? .success(()))
                    }
                }
            }
        } catch {
            await stopStreams(streams, logger: logger)
            throw error
        }

        return StartedCapture(
            store: store,
            streams: streams,
            configurations: configurations,
            outputs: outputs,
            delegates: delegates
        )
    }

    private func scheduleRecovery(reason: String) {
        recoveryLock.lock()
        guard !stopping else {
            recoveryLock.unlock()
            return
        }
        recoveryNeeded = true
        recoveryRequestSerial &+= 1
        recoveryReason = reason
        guard !recoveryScheduled else {
            recoveryLock.unlock()
            return
        }
        recoveryScheduled = true
        recoveryTask = Task { [weak self] in
            guard let self else {
                return
            }

            while true {
                // Coalesce the stream errors and workspace notification from
                // one transition. A further transition during a rebuild must
                // cause another pass instead of being cleared by that rebuild.
                do { try await Task.sleep(for: .seconds(1)) } catch { }
                let request = recoveryLock.withLock { (recoveryRequestSerial, recoveryReason) }
                var recovered = false
                do {
                    try await restartCapture(reason: request.1)
                    recovered = true
                } catch is CancellationError {
                    // The capture owner is shutting down.
                } catch {
                    logger.error("ScreenCaptureKit recovery failed: \(error.localizedDescription)")
                }
                if finishRecoveryScheduling(requestSerial: request.0, recovered: recovered) {
                    return
                }
            }
        }
        recoveryLock.unlock()
    }

    private func restartCapture(reason: String) async throws {
        try Task.checkCancellation()
        logger.info("ScreenCaptureKit: rebuilding capture after \(reason)")

        let oldStreams = currentStreams()
        await Self.stopStreams(oldStreams, logger: logger)

        var lastError: Error?
        for attempt in 1...3 {
            do {
                let started = try await Self.start(
                    scale: scale,
                    fps: fps,
                    displaySelection: displaySelection,
                    includesCursor: includesCursor,
                    eventSink: streamEventSink,
                    changes: changes,
                    logger: logger
                )
                guard started.store.waitForFirstFrames(timeout: 5) else {
                    await Self.stopStreams(started.streams, logger: logger)
                    throw RFBError.captureFailed("ScreenCaptureKit did not produce frames during recovery")
                }

                if Task.isCancelled {
                    await Self.stopStreams(started.streams, logger: logger)
                    throw CancellationError()
                }
                install(started)

                logger.info("ScreenCaptureKit: capture recovered")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                logger.warning("ScreenCaptureKit recovery attempt \(attempt)/3 failed: \(error.localizedDescription)")
                if attempt < 3 {
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }

        throw lastError ?? RFBError.captureFailed("ScreenCaptureKit recovery failed")
    }

    private func currentStreams() -> [SCStream] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streams
    }

    fileprivate func streamDidStop(_ stream: SCStream, reason: String) {
        stateLock.lock()
        let isCurrentStream = streams.contains { $0 === stream }
        stateLock.unlock()

        guard isCurrentStream else {
            return
        }
        scheduleRecovery(reason: "stream stopped: \(reason)")
    }

    private func install(_ started: StartedCapture) {
        started.store.setAcceptedFrameRate(captureRateTarget())
        stateLock.lock()
        store = started.store
        streams = started.streams
        streamConfigurations = started.configurations
        outputs = started.outputs
        delegates = started.delegates
        stateLock.unlock()
        scheduleCaptureRateUpdate()
    }

    private func finishRecoveryScheduling(requestSerial: UInt64, recovered: Bool) -> Bool {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        guard stopping || recoveryRequestSerial == requestSerial else {
            return false
        }
        recoveryNeeded = !recovered
        recoveryScheduled = false
        recoveryTask = nil
        return true
    }

    private static func stopStreams(_ streams: [SCStream], logger: ServerLogger) async {
        // Cleanup must still call the framework when the owning task is cancelled.
        struct Streams: @unchecked Sendable { let value: [SCStream] }
        let captured = Streams(value: streams)
        await Task.detached {
            for stream in captured.value {
                do {
                    try await CaptureOperation.run("stop capture", timeout: 5) { complete in
                        stream.stopCapture { error in
                            complete(error.map { .failure($0) } ?? .success(()))
                        }
                    }
                } catch {
                    logger.warning("ScreenCaptureKit stream stop failed: \(error.localizedDescription)")
                }
            }
        }.value
    }

    private static func selectDisplays(from displays: [SCDisplay], displaySelection: DisplaySelection) throws -> [SCDisplay] {
        guard !displays.isEmpty else {
            throw RFBError.captureFailed("ScreenCaptureKit found no displays")
        }

        switch displaySelection {
        case .automatic, .all:
            return displays
        case .display(let index):
            guard displays.indices.contains(index - 1) else {
                throw RFBError.captureFailed("display \(index) is not available; found \(displays.count) display(s)")
            }
            return [displays[index - 1]]
        }
    }

    private static func orderedDisplays(_ displays: [SCDisplay]) -> [SCDisplay] {
        guard let activeDisplayIDs = try? MacScreenCapture.activeDisplayIDs() else {
            return displays
        }

        let order = Dictionary(uniqueKeysWithValues: activeDisplayIDs.enumerated().map { ($0.element, $0.offset) })
        return displays.sorted {
            (order[$0.displayID] ?? Int.max, $0.displayID) < (order[$1.displayID] ?? Int.max, $1.displayID)
        }
    }
}

private struct StartedCapture {
    let store: StreamingFrameStore
    let streams: [SCStream]
    let configurations: [SCStreamConfiguration]
    let outputs: [ScreenCaptureStreamOutput]
    let delegates: [ScreenCaptureStreamDelegate]
}

private final class StreamEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private weak var owner: StreamingScreenCapture?
    private var pendingEvents: [(stream: SCStream, reason: String)] = []

    func attach(owner: StreamingScreenCapture) {
        lock.lock()
        self.owner = owner
        let pendingEvents = pendingEvents
        self.pendingEvents.removeAll(keepingCapacity: true)
        lock.unlock()

        for event in pendingEvents {
            owner.streamDidStop(event.stream, reason: event.reason)
        }
    }

    func streamDidStop(_ stream: SCStream, error: Error) {
        let reason = error.localizedDescription

        lock.lock()
        guard let owner else {
            pendingEvents.append((stream: stream, reason: reason))
            lock.unlock()
            return
        }
        lock.unlock()

        owner.streamDidStop(stream, reason: reason)
    }
}

private final class ScreenCaptureStreamDelegate: NSObject, SCStreamDelegate {
    private let eventSink: StreamEventSink

    init(eventSink: StreamEventSink) {
        self.eventSink = eventSink
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        eventSink.streamDidStop(stream, error: error)
    }
}

private struct DisplayFrame {
    let sequence: UInt64
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bgra: [UInt8]
    let dirtyRects: [Rect]?
}

final class StreamingFrameStore: @unchecked Sendable {
    private let condition = NSCondition()
    private let layout: VirtualDisplayLayout
    private let expectedDisplayIDs: Set<CGDirectDisplayID>
    private var frames: [CGDirectDisplayID: DisplayFrame] = [:]
    private var displaySequences: [CGDirectDisplayID: UInt64] = [:]
    private var acceptedFrameInterval: TimeInterval
    private var nextPresentationTimes: [CGDirectDisplayID: TimeInterval] = [:]
    private let changes: FrameChangeHub
    private var droppedFramePending: [CGDirectDisplayID: Bool] = [:]
    private var sequence: UInt64 = 0

    init(
        layout: VirtualDisplayLayout,
        expectedDisplayIDs: Set<CGDirectDisplayID>,
        acceptedFrameRate: Int,
        changes: FrameChangeHub = FrameChangeHub()
    ) {
        self.layout = layout
        self.changes = changes
        self.expectedDisplayIDs = expectedDisplayIDs
        acceptedFrameInterval = 1.0 / Double(max(1, acceptedFrameRate))
    }

    func setAcceptedFrameRate(_ fps: Int) {
        condition.lock()
        acceptedFrameInterval = 1.0 / Double(max(1, fps))
        nextPresentationTimes.removeAll()
        condition.unlock()
    }

    func update(
        displayID: CGDirectDisplayID,
        pixelBuffer: CVPixelBuffer,
        dirtyRects: [Rect]?,
        presentationTime: TimeInterval?
    ) {
        let acceptedDirtyRects: [Rect]?
        condition.lock()
        if dirtyRects?.isEmpty == true, frames[displayID] != nil,
           droppedFramePending[displayID] != true {
            condition.unlock()
            return
        }
        if let time = presentationTime {
            let next = nextPresentationTimes[displayID] ?? time
            if time + 0.0005 < next, time > next - 1 {
                droppedFramePending[displayID] = true
                condition.unlock()
                return
            }
            // Accumulate the requested cadence instead of rounding 45 FPS down
            // to 30 when capture delivers at 60 Hz. Rebase after discontinuities.
            nextPresentationTimes[displayID] = abs(time - next) > acceptedFrameInterval
                ? time + acceptedFrameInterval : next + acceptedFrameInterval
        }
        acceptedDirtyRects = droppedFramePending.removeValue(forKey: displayID) == true
            ? nil
            : dirtyRects
        condition.unlock()

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            condition.withLock { droppedFramePending[displayID] = true }
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            condition.lock()
            droppedFramePending[displayID] = true
            condition.unlock()
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let byteCount = bytesPerRow * height
        // The copy initializes every byte. Avoid zero-filling the entire image
        // before overwriting it, and do not retain scarce SCStream surfaces.
        let bytes = [UInt8](unsafeUninitializedCapacity: byteCount) { destination, initialized in
            memcpy(destination.baseAddress!, baseAddress, byteCount)
            initialized = byteCount
        }

        condition.lock()
        // The hub survives stream recovery. Never reuse an old sequence/cache
        // identity when ScreenCaptureKit restarts at the same dimensions.
        let sequences = changes.nextSequences(displayID: displayID)
        sequence = sequences.0
        let displaySequence = sequences.1
        displaySequences[displayID] = displaySequence
        frames[displayID] = DisplayFrame(
            sequence: displaySequence,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bgra: bytes,
            dirtyRects: acceptedDirtyRects
        )
        condition.broadcast()
        condition.unlock()
        changes.signal()
    }

    func waitForFirstFrames(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while !expectedDisplayIDs.isSubset(of: Set(frames.keys)) {
            if !condition.wait(until: deadline) {
                return false
            }
        }
        return true
    }

    func snapshot() throws -> Framebuffer {
        condition.lock()
        let currentFrames = frames
        let currentSequence = sequence
        condition.unlock()

        guard !currentFrames.isEmpty else {
            throw RFBError.captureFailed("no ScreenCaptureKit frame available yet")
        }

        if layout.displays.count == 1,
           let display = layout.displays.first,
           let frame = currentFrames[display.id],
           frame.width == layout.width,
           frame.height == layout.height {
            return Framebuffer(
                width: layout.width,
                height: layout.height,
                bytesPerRow: frame.bytesPerRow,
                bgra: frame.bgra,
                layout: layout,
                sequence: currentSequence,
                dirtyRects: frame.dirtyRects
            )
        }

        let bytesPerRow = layout.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * layout.height)
        var combinedDirtyRects: [Rect] = []
        var hasUnknownDirtyRects = false

        for display in layout.displays {
            guard let frame = currentFrames[display.id] else {
                hasUnknownDirtyRects = true
                continue
            }

            let rect = layout.framebufferRect(for: display)
            let destinationX = max(0, Int(rect.minX.rounded(.down)))
            let destinationY = max(0, Int(rect.minY.rounded(.down)))
            let copyWidth = min(frame.width, layout.width - destinationX)
            let copyHeight = min(frame.height, layout.height - destinationY)
            guard copyWidth > 0, copyHeight > 0 else {
                continue
            }

            if let dirtyRects = frame.dirtyRects {
                combinedDirtyRects.append(contentsOf: dirtyRects.map {
                    Rect(
                        x: destinationX + $0.x,
                        y: destinationY + $0.y,
                        width: $0.width,
                        height: $0.height
                    )
                })
            } else {
                hasUnknownDirtyRects = true
            }

            for row in 0..<copyHeight {
                let sourceOffset = row * frame.bytesPerRow
                let destinationOffset = (destinationY + row) * bytesPerRow + destinationX * 4
                _ = pixels.withUnsafeMutableBytes { destination in
                    frame.bgra.withUnsafeBytes { source in
                        memcpy(
                            destination.baseAddress!.advanced(by: destinationOffset),
                            source.baseAddress!.advanced(by: sourceOffset),
                            copyWidth * 4
                        )
                    }
                }
            }
        }

        return Framebuffer(
            width: layout.width,
            height: layout.height,
            bytesPerRow: bytesPerRow,
            bgra: pixels,
            layout: layout,
            sequence: currentSequence,
            dirtyRects: hasUnknownDirtyRects ? nil : combinedDirtyRects
        )
    }

    func currentSequence() throws -> UInt64? {
        condition.lock()
        defer { condition.unlock() }
        guard !frames.isEmpty else {
            throw RFBError.captureFailed("no ScreenCaptureKit frame available yet")
        }
        return sequence
    }

    func currentSequence(displayIndex: Int) throws -> UInt64? {
        condition.lock()
        defer { condition.unlock() }
        guard layout.displays.indices.contains(displayIndex - 1) else {
            throw RFBError.captureFailed("display \(displayIndex) is not available")
        }
        let display = layout.displays[displayIndex - 1]
        guard let frame = frames[display.id] else {
            throw RFBError.captureFailed("no ScreenCaptureKit frame available for display \(displayIndex)")
        }
        return frame.sequence
    }

    func snapshot(displayIndex: Int) throws -> Framebuffer {
        condition.lock()
        let currentFrames = frames
        condition.unlock()

        guard layout.displays.indices.contains(displayIndex - 1) else {
            throw RFBError.captureFailed("display \(displayIndex) is not available")
        }

        let display = layout.displays[displayIndex - 1]
        guard let frame = currentFrames[display.id] else {
            throw RFBError.captureFailed("no ScreenCaptureKit frame available for display \(displayIndex)")
        }

        let displayLayout = VirtualDisplayLayout(displays: [display], scaleOverride: layout.scale)
        if frame.width == displayLayout.width, frame.height == displayLayout.height {
            return Framebuffer(
                width: displayLayout.width,
                height: displayLayout.height,
                bytesPerRow: frame.bytesPerRow,
                bgra: frame.bgra,
                layout: displayLayout,
                sequence: frame.sequence,
                dirtyRects: frame.dirtyRects
            )
        }

        let bytesPerRow = displayLayout.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * displayLayout.height)
        let copyWidth = min(frame.width, displayLayout.width)
        let copyHeight = min(frame.height, displayLayout.height)

        for row in 0..<copyHeight {
            let sourceOffset = row * frame.bytesPerRow
            let destinationOffset = row * bytesPerRow
            _ = pixels.withUnsafeMutableBytes { destination in
                frame.bgra.withUnsafeBytes { source in
                    memcpy(
                        destination.baseAddress!.advanced(by: destinationOffset),
                        source.baseAddress!.advanced(by: sourceOffset),
                        copyWidth * 4
                    )
                }
            }
        }

        return Framebuffer(
            width: displayLayout.width,
            height: displayLayout.height,
            bytesPerRow: bytesPerRow,
            bgra: pixels,
            layout: displayLayout,
            sequence: frame.sequence,
            dirtyRects: frame.dirtyRects
        )
    }
}

final class SelectedDisplayFramebufferSource: @unchecked Sendable, FramebufferSource, FramebufferSequenceSource, InputRecoverySource, CaptureFrameRateController {
    private let source: StreamingScreenCapture
    private let displayIndex: Int?

    var includesCursor: Bool { source.includesCursor }
    var frameChanges: FrameChangeHub? { source.frameChanges }
    var cursorSnapshot: CursorSnapshot? { source.cursorSnapshot }

    init(source: StreamingScreenCapture, displayIndex: Int?) {
        self.source = source
        self.displayIndex = displayIndex
    }

    func capture() throws -> Framebuffer {
        if let displayIndex {
            return try source.capture(displayIndex: displayIndex)
        }

        return try source.capture()
    }

    func currentSequence() throws -> UInt64? {
        if let displayIndex {
            return try source.currentSequence(displayIndex: displayIndex)
        }
        return try source.currentSequence()
    }

    func requestRecoveryAfterInput() {
        source.requestRecoveryAfterInput()
    }

    func registerCaptureRateConsumer(_ consumer: ObjectIdentifier, fps: Int) {
        source.registerCaptureRateConsumer(consumer, fps: fps)
    }

    func updateCaptureRate(
        _ fps: Int,
        consumer: ObjectIdentifier,
        reconfigureCapture: Bool
    ) {
        source.updateCaptureRate(
            fps,
            consumer: consumer,
            reconfigureCapture: reconfigureCapture
        )
    }

    func unregisterCaptureRateConsumer(_ consumer: ObjectIdentifier) {
        source.unregisterCaptureRateConsumer(consumer)
    }
}

private final class ScreenCaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let store: StreamingFrameStore
    private struct Delivery {
        let pixelBuffer: CVPixelBuffer
        var dirtyRects: [Rect]?
        let presentationTime: TimeInterval?
    }
    private let deliveryLock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "mac-vnc.capture-copy", qos: .userInteractive)
    private var pending: Delivery?
    private var copying = false

    init(displayID: CGDirectDisplayID, store: StreamingFrameStore) {
        self.displayID = displayID
        self.store = store
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }
        if let entries = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let status = entries.first?[.status] as? Int,
           status != SCFrameStatus.complete.rawValue { return }
        let dirtyRects = Self.dirtyRects(
            from: sampleBuffer,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationSeconds = presentationTime.isValid
            ? CMTimeGetSeconds(presentationTime)
            : nil
        let delivery = Delivery(pixelBuffer: pixelBuffer, dirtyRects: dirtyRects,
            presentationTime: presentationSeconds?.isFinite == true ? presentationSeconds : nil)
        deliveryLock.lock()
        var newest = delivery
        if pending != nil { newest.dirtyRects = nil }
        pending = newest
        let start = !copying
        copying = true
        deliveryLock.unlock()
        if start { deliveryQueue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            deliveryLock.lock()
            guard let next = pending else {
                copying = false
                deliveryLock.unlock()
                return
            }
            pending = nil
            deliveryLock.unlock()
            autoreleasepool {
                store.update(displayID: displayID, pixelBuffer: next.pixelBuffer,
                    dirtyRects: next.dirtyRects, presentationTime: next.presentationTime)
            }
        }
    }

    private static func dirtyRects(
        from sampleBuffer: CMSampleBuffer,
        width: Int,
        height: Int
    ) -> [Rect]? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let frameInfo = attachments.first,
        let values = frameInfo[.dirtyRects] as? [NSValue] else {
            return nil
        }

        var rects: [Rect] = []
        for value in values {
            let rect = value.rectValue
            let x = max(0, Int(rect.minX.rounded(.down)))
            let y = max(0, Int(rect.minY.rounded(.down)))
            let right = min(width, Int(rect.maxX.rounded(.up)))
            let bottom = min(height, Int(rect.maxY.rounded(.up)))
            guard right > x, bottom > y else {
                continue
            }

            let rectWidth = right - x
            let rectHeight = bottom - y
            rects.append(Rect(x: x, y: y, width: rectWidth, height: rectHeight))

            let flippedY = max(0, height - bottom)
            if flippedY != y {
                rects.append(Rect(x: x, y: flippedY, width: rectWidth, height: rectHeight))
            }
        }
        return rects
    }
}
