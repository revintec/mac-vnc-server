import CVNCSession
import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

struct ConsoleSessionControlTests {
    private let own = ConsoleIdentity(uid: 501, auditID: 12)
    private let console = ConsoleIdentity(uid: 502, auditID: 19)

    @Test func graphicsIDResolutionChecksTheAuditSessionAndUsesGraphicsNotAuditID() {
        func row(_ uid: UInt32, _ audit: Int32, _ graphics: Any) -> [String: Any] {
            ["kCGSSessionUserIDKey": uid, "kCGSSessionAuditIDKey": audit, "kCGSSessionIDKey": graphics]
        }
        let valid = row(own.uid, own.auditID, 257)
        var graphics: Int32 = -1
        #expect(VNCSessionResolveGraphicsID([valid, row(502, 19, 258)] as CFArray, own.native, &graphics) == 0)
        #expect(graphics == 257)
        #expect(VNCSessionResolveGraphicsID([row(501, 99, 257)] as CFArray, own.native, &graphics) == ESTALE)
        #expect(VNCSessionResolveGraphicsID([valid, row(501, 12, 258)] as CFArray, own.native, &graphics) == EEXIST)
        for value: Any in [0, -1, true, "257", Double.infinity] {
            #expect(VNCSessionResolveGraphicsID([row(501, 12, value)] as CFArray, own.native, &graphics) == EINVAL)
        }
        #expect(VNCSessionResolveGraphicsID([] as CFArray, own.native, &graphics) == ENXIO)
        // This refusal is safe even when the test runner itself is root.
        #expect(VNCSessionSwitchToConsole(VNCConsoleIdentity(uid: 0, audit_id: 12)) == EPERM)
    }

    @Test func controlRequestsAndAdmissionsUseIndependentDirectionsAndReplySockets() throws {
        let (parent, inherited) = try SessionChannel.pair()
        let worker = try SessionChannel(fd: dup(inherited.fileDescriptor))
        try inherited.close()
        defer { parent.shutdown(); worker.shutdown() }
        let (client, peer) = try SessionChannel.pair()
        defer { client.shutdown(); try? peer.close() }
        let reply = try ClientSocket(fd: dup(peer.fileDescriptor))
        let admission = SessionAdmission(identity: own, version: "RFB 003.008\n", wrappingKey: [UInt8](repeating: 17, count: 16))
        try worker.ready()
        try parent.waitUntilReady()
        try parent.send(client: client.socket, admission: admission)
        try worker.sendControl(reply: reply, request: .init(action: .viewConsole))
        let (_, received) = try #require(try worker.receive(timeout: 1))
        #expect(received.identity == own && received.wrappingKey == admission.wrappingKey)
        let (response, request) = try #require(try parent.receiveControl(timeout: 1))
        #expect(request.action == .viewConsole)
        try response.writeAll([42])
        #expect(try client.socket.withReadTimeout(1, operation: "test reply") { try client.socket.readExact(1) } == [42])
    }

    @Test func rejectedControlRequestDoesNotDisconnectTheAdmissionChannel() throws {
        let (parent, inherited) = try SessionChannel.pair()
        let worker = try SessionChannel(fd: dup(inherited.fileDescriptor))
        try inherited.close()
        // uid=0 can never request either action; do not switch the test host.
        let service = ConsoleControlService(channel: parent, identity: .init(uid: 0, auditID: 1),
            broker: ConsoleDesktopBroker(), logger: ServerLogger(verbose: false))
        service.start()
        defer { worker.shutdown(); service.stop() }
        let control = SessionConsoleControl()
        control.attach(worker, canBringToConsole: true)
        defer { control.attach(nil) }
        for action: ConsoleControlRequest.Action in [.bringToConsole, .viewConsole] {
            #expect(throws: (any Error).self) { try control.request(action) }
        }
        #expect(try worker.receive(timeout: 0.01) == nil)
    }

    @Test func loginwindowStartupFailureIncludesItsUnderlyingReason() throws {
        let (viewer, worker) = try ClientSocket.localPair()
        defer { viewer.shutdown(); worker.shutdown() }
        try ConsoleFramebufferBridge.rejectStartup(socket: worker,
            error: CLIError.commandFailed("loginwindow HID input unavailable (code 13)"))
        do {
            _ = try ConsoleFramebufferBridge(socket: viewer, identity: .init(uid: 0, auditID: 101098), startupTimeout: 1)
            Issue.record("rejected loginwindow startup succeeded")
        } catch {
            #expect(error.localizedDescription.contains("loginwindow (audit 101098)"))
            #expect(error.localizedDescription.contains("HID input unavailable (code 13)"))
        }
    }

    @Test(arguments: [false, true])
    func consoleStartupClosureOrTimeoutIdentifiesTheFailedStage(closePeer: Bool) throws {
        let (viewer, worker) = try ClientSocket.localPair()
        defer { viewer.shutdown(); worker.shutdown() }
        if closePeer { worker.shutdown() }
        let start = ContinuousClock.now
        do {
            _ = try ConsoleFramebufferBridge(socket: viewer, identity: .init(uid: 0, auditID: 123), startupTimeout: 0.05)
            Issue.record("unavailable console startup succeeded")
        } catch {
            #expect(error.localizedDescription.contains("loginwindow (audit 123) while starting capture and input"))
            #expect(error.localizedDescription.contains(closePeer ? "disconnected" : "timed out"))
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test(arguments: [UInt32(0), UInt32(4097), UInt32.max])
    func consoleStartupRejectsInvalidErrorLengths(length: UInt32) throws {
        let (viewer, worker) = try ClientSocket.localPair()
        defer { viewer.shutdown(); worker.shutdown() }
        try worker.writeAll(UInt32(1).beBytes + length.beBytes)
        do {
            _ = try ConsoleFramebufferBridge(socket: viewer, identity: own, startupTimeout: 1)
            Issue.record("invalid error length accepted")
        } catch { #expect(error.localizedDescription.contains("invalid console desktop error length")) }
    }

    @Test(arguments: [
        [UInt16(0), 0, 1025, 1], // Oversized image, including maximum --scale.
        [UInt16(1), 0, 1, 1],   // Hotspot outside image.
        [UInt16(0), 0, 0, 1]    // Only one empty dimension.
    ])
    func bridgeRejectsMalformedCursorShapes(rect: [UInt16]) throws {
        try rejectCursorRectangle(rect, encoding: RFBPseudoEncoding.richCursor, reason: "cursor shape")
    }

    @Test(arguments: [[UInt16(2), 0, 0, 0], [UInt16(0), 0, 1, 0]])
    func bridgeRejectsMalformedCursorPositions(rect: [UInt16]) throws {
        try rejectCursorRectangle(rect, encoding: RFBPseudoEncoding.pointerPosition, reason: "cursor position")
    }

    private func rejectCursorRectangle(_ rect: [UInt16], encoding: Int32, reason: String) throws {
        let (viewer, worker) = try ClientSocket.localPair()
        defer { viewer.shutdown(); worker.shutdown() }
        let serverInit = [UInt8(0), 2, 0, 2] + PixelFormat.serverDefault.bytes + UInt32(0).beBytes
        try worker.writeAll(UInt32(0).beBytes + serverInit + [0, 0, 0, 1]
            + rect.flatMap(\.beBytes) + UInt32(bitPattern: encoding).beBytes)
        do {
            _ = try ConsoleFramebufferBridge(socket: viewer, identity: console, startupTimeout: 1)
            Issue.record("malformed cursor accepted")
        } catch { #expect(error.localizedDescription.contains("invalid internal \(reason)")) }
    }
}
