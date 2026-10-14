import Foundation

/// Coalesces notifications: a busy encoder never accumulates a queue of ticks.
final class FrameWakeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var pending = false
    func signal() {
        lock.lock()
        if !pending { pending = true; semaphore.signal() }
        lock.unlock()
    }
    func wait(until deadline: DispatchTime) {
        if semaphore.wait(timeout: deadline) == .success {
            lock.withLock { pending = false }
        }
    }
}

final class FrameChangeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: @Sendable () -> Void] = [:]
    private var sequence: UInt64 = 0
    func nextSequence() -> UInt64 {
        lock.withLock {
            sequence &+= 1
            return sequence
        }
    }
    func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = callback }
        return id
    }
    func remove(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
    func signal() {
        let callbacks = lock.withLock { Array(observers.values) }
        for callback in callbacks { callback() }
    }
}

struct FramePacer {
    private(set) var next: UInt64 = 0
    private var interval: UInt64 = 0
    mutating func started(at now: UInt64, interval seconds: TimeInterval) {
        let step = max(1, UInt64(seconds * 1_000_000_000))
        // Preserve the cadence when on time; skip missed slots, never catch up
        // with a burst of frames that are already obsolete.
        if interval != step || next == 0 || now >= next &+ step {
            next = now &+ step
        } else {
            next = next &+ step
        }
        interval = step
    }
}

/// One cached resampling result per session. Nil source sequences are never
/// cached; an embedded cursor must also match even if the capture is unchanged.
struct ScaledFramebufferCache {
    private var source: Framebuffer?
    private var result: Framebuffer?
    private var factor: CGFloat = 0
    private var rounded = false
    private var cursor: CursorSnapshot?
    mutating func frame(_ original: Framebuffer, factor: CGFloat, rounded: Bool,
                        cursor: CursorSnapshot?) throws -> Framebuffer {
        let sameCursor = self.cursor?.image == cursor?.image && self.cursor?.position == cursor?.position
        if let sequence = original.sequence, source?.sequence == sequence,
           source?.layout == original.layout, source?.width == original.width,
           source?.height == original.height, self.factor == factor,
           self.rounded == rounded, sameCursor, let result { return result }
        let composited = try cursor?.composited(over: original) ?? original
        let result = try FramebufferResampling.scale(composited, factor: factor, roundPixelDimensions: rounded)
        self.source = original; self.result = result; self.factor = factor
        self.rounded = rounded; self.cursor = cursor
        return result
    }
}
