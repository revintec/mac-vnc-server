import Foundation
import Testing
@testable import mac_vnc_server

struct CaptureOperationTests {
    @Test func discardedCallbackFailsInsteadOfLeakingContinuation() async {
        do {
            let _: Int = try await CaptureOperation.run("test discarded reply") { _ in }
            Issue.record("A discarded callback must fail")
        } catch { #expect(error.localizedDescription.contains("discarded its completion handler without replying")) }
    }

    @Test func retainedCallbackTimesOutAndLateReplyIsIgnored() async {
        let reply = StoredCaptureReply<Int>()
        do {
            let _ = try await CaptureOperation.run("test missing reply", timeout: 0.02, begin: reply.store)
            Issue.record("A retained callback that never replies must time out")
        } catch {
            #expect(error.localizedDescription.contains("test missing reply timed out"))
        }
        reply.send(.success(42))
        reply.clear()
    }

    @Test func synchronousAndDuplicateRepliesResumeOnlyOnce() async throws {
        let value: Int = try await CaptureOperation.run("test duplicate") { complete in
            complete(.success(42))
            complete(.failure(CancellationError()))
            complete(.success(99))
        }
        #expect(value == 42)
    }

    @Test func asynchronousSuccessAndFrameworkErrorArePreserved() async throws {
        let value: Int = try await CaptureOperation.run("test async") { complete in
            DispatchQueue.global().async { complete(.success(42)) }
        }
        #expect(value == 42)
        do {
            let _: Int = try await CaptureOperation.run("test error") { complete in
                complete(.failure(NSError(domain: "capture-test", code: 4097)))
            }
            Issue.record("Framework errors must reach the caller")
        } catch {
            #expect((error as NSError).domain == "capture-test")
            #expect((error as NSError).code == 4097)
        }
    }

    @Test func cancellationBeforeRegistrationDoesNotBeginCapture() async {
        let reply = StoredCaptureReply<Int>()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CaptureOperation.run("test cancelled", begin: reply.store)
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(!reply.isStored)
    }

    @Test func cancellationWhileWaitingIgnoresLateReply() async {
        let reply = StoredCaptureReply<Int>()
        let task = Task { try await CaptureOperation.run("test cancel pending", begin: reply.store) }
        while !reply.isStored { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        reply.send(.success(42))
        reply.clear()
    }
}

private final class StoredCaptureReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Result<Value, Error>) -> Void)?
    var isStored: Bool { lock.withLock { callback != nil } }
    func store(_ callback: @escaping @Sendable (Result<Value, Error>) -> Void) {
        lock.withLock { self.callback = callback }
    }
    func send(_ result: Result<Value, Error>) { lock.withLock { callback }?(result) }
    func clear() {
        let old = lock.withLock { let old = callback; callback = nil; return old }
        withExtendedLifetime(old) {}
    }
}
