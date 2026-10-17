import CVNCSession
import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

struct SessionChannelTests {
    private func pair() throws -> (SessionChannel, SessionChannel) {
        let (sender, input) = try SessionChannel.pair()
        defer { try? input.close() }
        return (sender, try SessionChannel(fd: dup(input.fileDescriptor)))
    }

    @Test func listenerClosingIdleChannelEndsWorkerNormally() throws {
        let (listener, worker) = try pair()
        defer { listener.shutdown(); worker.shutdown() }
        listener.shutdown()
        #expect(throws: CancellationError.self) { try worker.receive(timeout: 1) }
    }

    @Test func malformedDescriptorStillReportsAProtocolFailure() throws {
        let (listener, worker) = try pair()
        defer { listener.shutdown(); worker.shutdown() }
        try listener.socket.writeAll([70]) // Admission marker without a descriptor.
        do {
            _ = try worker.receive(timeout: 1)
            Issue.record("Malformed admission was accepted")
        } catch {
            #expect(!(error is CancellationError))
            #expect(error is RFBError)
        }
    }

    @Test func listenerClosingPartwayThroughAdmissionStillReportsFailure() throws {
        let (listener, worker) = try pair()
        let (client, peer) = try pair()
        defer { listener.shutdown(); worker.shutdown(); client.shutdown(); peer.shutdown() }
        #expect(VNCSessionSendDescriptor(listener.socket.fd, client.socket.fd) == 0)
        try listener.socket.writeAll(UInt32(20).beBytes + Array("{\"identity\":".utf8))
        // Preserve buffered bytes while delivering EOF to the reader.
        #expect(Darwin.shutdown(listener.socket.fd, SHUT_WR) == 0)
        do {
            _ = try worker.receive(timeout: 1)
            Issue.record("Truncated admission was accepted")
        } catch {
            #expect(!(error is CancellationError))
            #expect(error is RFBError)
        }
    }

    @Test func taskCancellationInterruptsAnIncompleteAdmissionCleanly() async throws {
        let (listener, worker) = try pair()
        let (client, peer) = try pair()
        defer { listener.shutdown(); worker.shutdown(); client.shutdown(); peer.shutdown() }
        #expect(VNCSessionSendDescriptor(listener.socket.fd, client.socket.fd) == 0)
        try listener.socket.writeAll(UInt32(20).beBytes + Array("{\"identity\":".utf8))
        let task = Task.detached {
            try await withTaskCancellationHandler {
                try worker.receive(timeout: 5)
            } onCancel: { worker.shutdown() }
        }
        defer { task.cancel() }
        // Wait until receive() consumes the descriptor and partial metadata,
        // so cancellation interrupts its blocked read rather than an idle poll.
        let deadline = ContinuousClock.now + .seconds(2)
        var pending = true
        while pending, ContinuousClock.now < deadline {
            var descriptor = pollfd(fd: worker.socket.fd, events: Int16(POLLIN), revents: 0)
            let count = poll(&descriptor, 1, 0)
            #expect(count >= 0)
            pending = count != 0
            if pending { try await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(!pending)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled receive succeeded")
        } catch { #expect(error is CancellationError) }
    }

    @Test func idleTimeoutKeepsTheWorkerAvailable() throws {
        let (listener, worker) = try pair()
        defer { listener.shutdown(); worker.shutdown() }
        #expect(try worker.receive(timeout: 0.01) == nil)
    }
}
