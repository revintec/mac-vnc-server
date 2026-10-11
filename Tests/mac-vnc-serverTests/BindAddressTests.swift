import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

struct BindAddressTests {
    @Test(arguments: ["127.0.0.1", "127.0.0.2", "0.0.0.0", "192.0.2.1"])
    func literalAddressIsPreserved(address: String) throws {
        #expect(try BindAddress.resolve(address) == address)
    }

    @Test func interfaceBindsItsAddressAndAcceptsConnections() throws {
        let name = ProcessInfo.processInfo.environment["MAC_VNC_TEST_BIND_INTERFACE"] ?? "lo0"
        let resolved = try BindAddress.resolve(name)
        if name == "lo0" { #expect(resolved == "127.0.0.1") }
        let listener = try ListeningSocket(bindAddress: name, port: 0)
        #expect(listener.bindAddress == resolved)
        var address = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        try #require(withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener.fd, $0, &size) }
        } == 0)
        var expected = in_addr()
        try #require(inet_pton(AF_INET, resolved, &expected) == 1)
        #expect(address.sin_addr.s_addr == expected.s_addr)
        let peer = socket(AF_INET, SOCK_STREAM, 0)
        try #require(peer >= 0)
        defer { close(peer) }
        try #require(withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(peer, $0, size) }
        } == 0)
        let accepted = try #require(try listener.acceptClient(timeout: 1))
        try accepted.writeAll([42])
        var byte: UInt8 = 0
        #expect(Darwin.read(peer, &byte, 1) == 1 && byte == 42)
    }

    @Test(arguments: ["", "no-such-vnc-interface", "127.invalid", "::1"])
    func unavailableTargetsNeverFallBack(target: String) {
        #expect(throws: (any Error).self) { try ListeningSocket(bindAddress: target, port: 0) }
    }

    @Test func interfaceNameSurvivesServiceRegistrationAndOptionsCanBeReversed() throws {
        let args = ["--bind", "utun99", "--encryption", "--no-file-transfer", "--no-clipboard-sync"]
        guard case .service(let config, let saved) = try CLI.parse(arguments: ["--service"] + args) else {
            Issue.record("expected service command"); return
        }
        #expect(saved == args)
        #expect(config.bindAddress == "utun99") // Resolve at launch, not installation.
        #expect(config.allowEncryption && !config.fileTransfer && !config.clipboardSync)
        guard case .run(let reversed) = try CLI.parse(arguments: args + [
            "--no-encryption", "--file-transfer", "--clipboard-sync"
        ]) else { Issue.record("expected run command"); return }
        #expect(!reversed.allowEncryption && reversed.fileTransfer && reversed.clipboardSync)
    }

    @Test func authenticationGuardUsesTheResolvedAddress() throws {
        #expect(BindAddress.isLoopback("127.0.0.2"))
        #expect(!BindAddress.isLoopback("127.invalid"))
        #expect(!BindAddress.isLoopback("192.0.2.1"))
        #expect(throws: (any Error).self) {
            try CLI.parse(arguments: ["--bind", "192.0.2.1", "--no-password"])
        }
        #expect(throws: (any Error).self) {
            try CLI.parse(arguments: ["--bind", "127.invalid", "--no-password"])
        }
        guard case .run(let config) = try CLI.parse(arguments: [
            "--bind", "192.0.2.1", "--no-password", "--insecure-allow-no-auth"
        ]) else { Issue.record("expected run command"); return }
        #expect(config.insecureAllowNoAuth)
    }
}
