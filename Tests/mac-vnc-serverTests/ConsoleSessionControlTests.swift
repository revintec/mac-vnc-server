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
}
