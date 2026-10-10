import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

struct SocketTimeoutTests {
    @Test func acceptedTCPConnectionConfiguresLivenessTimeouts() throws {
        let listener = try ListeningSocket(bindAddress: "127.0.0.1", port: 0)
        var address = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener.fd, $0, &size) }
        }
        try #require(nameResult == 0)
        let peer = socket(AF_INET, SOCK_STREAM, 0)
        try #require(peer >= 0)
        defer { close(peer) }
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(peer, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(connectResult == 0)
        let accepted = try #require(try listener.acceptClient(timeout: 1))
        try accepted.configureTCP()
        for (level, name, expected): (Int32, Int32, Int32) in [
            (SOL_SOCKET, SO_KEEPALIVE, 1),
            (IPPROTO_TCP, TCP_KEEPALIVE, 3),
            (IPPROTO_TCP, TCP_KEEPINTVL, 1),
            (IPPROTO_TCP, TCP_KEEPCNT, 3),
            (IPPROTO_TCP, TCP_RXT_CONNDROPTIME, 6),
        ] {
            var value: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            try #require(getsockopt(accepted.fd, level, name, &value, &length) == 0)
            if level == SOL_SOCKET && name == SO_KEEPALIVE {
                // Darwin returns the enabled option bit rather than boolean 1.
                #expect(value != 0)
            } else {
                #expect(value == expected)
            }
        }
    }

    @Test func partialProgressDoesNotExtendReadDeadline() throws {
        let (reader, peer) = try pair()
        defer { close(peer) }
        var byte: UInt8 = 42
        try reader.withReadTimeout(0.05, operation: "test message") {
            try #require(Darwin.write(peer, &byte, 1) == 1)
            #expect(try reader.readExact(1) == [42])
            Thread.sleep(forTimeInterval: 0.08)
            try #require(Darwin.write(peer, &byte, 1) == 1)
            // A second field cannot start a new timeout, even if it is buffered.
            #expect(throws: (any Error).self) { try reader.readExact(1) }
        }
        // Exiting the scope restores unlimited waiting between messages.
        #expect(try reader.readExact(1) == [42])
    }

    @Test func stalledReadTimesOutAndScopeRestoresDeadlineAfterError() throws {
        let (reader, peer) = try pair()
        defer { close(peer) }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try reader.withReadTimeout(0.05, operation: "test message") {
                try reader.readExact(2)
            }
            Issue.record("stalled read did not time out")
        } catch {
            #expect(error.localizedDescription.contains("test message timed out"))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        #expect(elapsed >= 0.04 && elapsed < 1)
        var byte: UInt8 = 7
        try #require(Darwin.write(peer, &byte, 1) == 1)
        #expect(try reader.readExact(1) == [7])
    }

    @Test func suspendedWaitPreservesTheRemainingOuterBudget() throws {
        let (reader, peer) = try pair()
        defer { close(peer) }
        var byte: UInt8 = 42
        try reader.withReadTimeout(0.3, operation: "outer handshake") {
            Thread.sleep(forTimeInterval: 0.15)
            try reader.withReadTimeout(1, operation: "password entry", suspendingOuterDeadline: true) {
                Thread.sleep(forTimeInterval: 0.4)
                try #require(Darwin.write(peer, &byte, 1) == 1)
                #expect(try reader.readExact(1) == [42])
            }
            try #require(Darwin.write(peer, &byte, 1) == 1)
            #expect(try reader.readExact(1) == [42], "the outer budget must be paused during credential entry")
            Thread.sleep(forTimeInterval: 0.2)
            try #require(Darwin.write(peer, &byte, 1) == 1)
            #expect(throws: (any Error).self) { try reader.readExact(1) }
        }
        #expect(try reader.readExact(1) == [42])
    }

    private func pair() throws -> (ClientSocket, Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        do { return (try ClientSocket(fd: descriptors[0]), descriptors[1]) }
        catch { close(descriptors[1]); throw error }
    }
}
