import Foundation

/// ScreenCaptureKit can discard a completion handler when its replayd XPC
/// connection fails. The imported async API then leaks its continuation.
/// Own the continuation here so a dropped, missing, or late reply is safe.
enum CaptureOperation {
    static func run<Value: Sendable>(
        _ name: String,
        timeout: TimeInterval = 15,
        begin: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        let pending = PendingCaptureReply<Value>(name: name)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending.install(continuation, timeout: timeout) else { return }
                let lease = CaptureReplyLease(pending)
                begin { [lease] result in lease.pending.finish(result) }
            }
        } onCancel: {
            pending.finish(.failure(CancellationError()))
        }
    }
}

private final class PendingCaptureReply<Value: Sendable>: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var completed = false
    private var earlyResult: Result<Value, Error>?
    private var timer: DispatchSourceTimer?

    init(name: String) { self.name = name }

    func install(_ continuation: CheckedContinuation<Value, Error>, timeout: TimeInterval) -> Bool {
        lock.lock()
        if completed {
            let result = earlyResult!
            earlyResult = nil
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.fail("timed out after \(timeout) seconds")
        }
        self.timer = timer
        timer.resume()
        lock.unlock()
        return true
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil { earlyResult = result }
        let timer = timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result)
    }

    func fail(_ reason: String) {
        finish(.failure(RFBError.captureFailed(
            "ScreenCaptureKit \(name) \(reason). The macOS capture service may be unavailable; " +
            "stop older instances of this executable and retry. Also check Screen Recording permission."
        )))
    }
}

private final class CaptureReplyLease<Value: Sendable>: Sendable {
    let pending: PendingCaptureReply<Value>
    init(_ pending: PendingCaptureReply<Value>) { self.pending = pending }
    deinit { pending.fail("discarded its completion handler without replying") }
}
