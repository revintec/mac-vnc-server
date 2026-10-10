import Foundation
import Darwin
import Testing
@testable import mac_vnc_server

@Suite(.serialized)
struct AppleEncryptionTests {
    private var keys: AppleEncryption.Keys {
        .init(key: Array(0..<16), iv: Array(16..<32))
    }

    @Test func encryptedEventsMatchIndependentOpenSSLVectors() throws {
        // openssl enc -aes-128-ecb -K 000102030405060708090a0b0c0d0e0f -nopad
        #expect(try AppleEncryption.InputEvent(ciphertext: hex("4e78f6d11b6925fbd7855ee1f8427dd6"), key: keys.key).key
            == .init(down: true, keysym: 0x61))
        #expect(try AppleEncryption.InputEvent(ciphertext: hex("d7dfdfca82d68ed74e543160ebc093ff"), key: keys.key).pointer
            == .init(mask: 2, x: 0x123, y: 0x456))
        let combined = try AppleEncryption.InputEvent(ciphertext: hex("0f6a52f9b9c8da18d7555be78c837a16"), key: keys.key)
        #expect(combined.key == .init(down: true, keysym: 0x61))
        #expect(combined.pointer == .init(mask: 2, x: 0x123, y: 0x456))
        let empty = try AppleEncryption.InputEvent(ciphertext: hex("c6a13b37878f5b826f4f8162a1c8d879"), key: keys.key)
        #expect(empty.key == nil && empty.pointer == nil)
        for invalid in ["dce844d0483c127099f407bcc0dc06a2", "88b0798fa13787a3ed441b779030a546", "00"] {
            #expect(throws: (any Error).self) { try AppleEncryption.InputEvent(ciphertext: hex(invalid), key: keys.key) }
        }
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [0, 1, 2])
    func encryptedEventWithoutKeyOrWithInvalidMarkersClosesSession(kind: Int) throws {
        let peer = try ClipboardTestPeer(fileTransfer: kind != 0)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        var block = [UInt8](repeating: 0, count: 16)
        block[kind == 2 ? 10 : 0] = 1
        let key = peer.appleWrappingKey ?? keys.key
        try peer.write([0x10, 0] + AppleEncryption.ecb(block, key: key, encrypt: true))
        try #require(peer.hasData(timeout: 2))
        var byte: UInt8 = 0
        #expect(recv(peer.socket.fd, &byte, 1, MSG_PEEK) == 0)
    }

    @Test func recordsMatchIndependentOpenSSLVectorsAndChainAcrossMessages() throws {
        // Generated independently with hashlib SHA1 and openssl enc AES-128-CBC.
        let records = [
            hex("0020f1de5c8d9c2fe737360ed20f3e083177a0eb53d195a5f77c7fe01f5a2c2f69c1"),
            hex("0060af255eee9d103fae420222f483bdd12a4b3095a80e349d06f0fa0e8ca706faf13b9705798994833f89fd0e21e893c8beb7f7ab866e6f98a3942109465611f2ac4a1f76ff8a8ee3a3d5fc4d35952ef8f1b0b54fc44cfc3f29439bb2e2a875d262")
        ]
        let payloads: [[UInt8]] = [[0x0a, 0, 0, 1], Array(0..<60)]
        let sender = try AppleEncryption.Cipher(keys: keys, encrypt: true)
        let receiver = try AppleEncryption.Cipher(keys: keys, encrypt: false)
        for (payload, record) in zip(payloads, records) {
            #expect(try sender.seal(payload) == record)
            #expect(try receiver.open(Array(record.dropFirst(2))) == payload)
        }
    }

    @Test func tamperingReplayWrongKeyAndMalformedLengthsAreRejected() throws {
        let sender = try AppleEncryption.Cipher(keys: keys, encrypt: true)
        let record = Array(try sender.seal([0x0a, 0, 0, 1]).dropFirst(2))
        let receiver = try AppleEncryption.Cipher(keys: keys, encrypt: false)
        _ = try receiver.open(record)
        #expect(throws: (any Error).self) { try receiver.open(record) }
        for index in [0, 16, 31] {
            let fresh = try AppleEncryption.Cipher(keys: keys, encrypt: false)
            var tampered = record
            tampered[index] ^= 1
            #expect(throws: (any Error).self) { try fresh.open(tampered) }
        }
        let wrong = try AppleEncryption.Cipher(keys: .init(key: keys.iv, iv: keys.key), encrypt: false)
        #expect(throws: (any Error).self) { try wrong.open(record) }
        for length in [0, 16, 31, 33, 65_536] {
            let fresh = try AppleEncryption.Cipher(keys: keys, encrypt: false)
            #expect(throws: (any Error).self) { try fresh.open([UInt8](repeating: 0, count: length)) }
        }
    }

    @Test func maximumRecordFitsWireLength() throws {
        let sender = try AppleEncryption.Cipher(keys: keys, encrypt: true)
        let payload = [UInt8](repeating: 0xa5, count: AppleEncryption.maxPayloadBytes)
        let record = try sender.seal(payload)
        #expect(record.count == 65_522)
        #expect(record.prefix(2) == [0xff, 0xf0])
        #expect(try AppleEncryption.Cipher(keys: keys, encrypt: false).open(Array(record.dropFirst(2))) == payload)
        #expect(throws: (any Error).self) { try sender.seal(payload + [1]) }
    }

    @Test func chunkedSocketWritesCanSpanRecordsAndKeepTheNextMessageAligned() throws {
        let link = try EncryptedTestLink()
        let chunks = [[UInt8](repeating: 0, count: 16), [],
                      [UInt8](repeating: 0xab, count: 200_000), [1, 2, 3]]
        #expect(try link.transfer(chunks) == chunks.flatMap { $0 })
        #expect(try link.transfer([[0x14, 0, 0, 4], [0, 1, 0, 9]]) == [0x14, 0, 0, 4, 0, 1, 0, 9])
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [UInt16(0), 1])
    func negotiatedRecordsCarryClipboardAndSubsequentMessages(level: UInt16) throws {
        let peer = try ClipboardTestPeer(fileTransfer: true)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        let keys = try rekey(peer, level: level, wrappingKey: #require(peer.appleWrappingKey))
        try peer.write([0x12, 0, 0, 2, 0, 1, 0, 0])
        peer.socket.setAppleRecordWrites(try AppleEncryption.Cipher(keys: keys, encrypt: true))
        // enableAppleClipboard pipelines several messages in a single record.
        try peer.enableAppleClipboard()
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 42])
        #expect(try peer.readClipboard().1 == .text("initial"))

        // Rekey while connected; its reply uses the previous transport and the
        // previous key wraps the new pair. Both directions then restart CBC.
        let next = try rekey(peer, level: level, wrappingKey: keys.key)
        peer.socket.setAppleRecordWrites(try AppleEncryption.Cipher(keys: next, encrypt: true))
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 43])
        #expect(try peer.readClipboard().1 == .text("initial"))
    }

    @Test(.enabled(if: NativeTransferProcess.available))
    func oneClientMessageCanSpanRecords() throws {
        let peer = try ClipboardTestPeer(fileTransfer: true)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        let keys = try rekey(peer, level: 1, wrappingKey: #require(peer.appleWrappingKey))
        try peer.write([0x12, 0, 0, 2, 0, 1, 0, 0])
        let sender = try AppleEncryption.Cipher(keys: keys, encrypt: true)
        let fetch: [UInt8] = [0x0b, 0, 0, 0, 0, 0, 0, 42]
        for byte in fetch { try peer.write(sender.seal([byte])) }
        #expect(try peer.readClipboard().1 == .text("initial"))
    }

    @Test(.enabled(if: NativeTransferProcess.available))
    func partialEncryptedRecordTimesOutBeforeMessageDispatch() throws {
        let peer = try ClipboardTestPeer(fileTransfer: true, messageTimeout: 0.15)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        _ = try rekey(peer, level: 1, wrappingKey: #require(peer.appleWrappingKey))
        try peer.write([0x12, 0, 0, 2, 0, 1, 0, 0, 0])
        // Prove the server closes the socket, rather than passing merely
        // because the test's own response-read deadline expires.
        try #require(peer.hasData(timeout: 2))
        var byte: UInt8 = 0
        #expect(recv(peer.socket.fd, &byte, 1, MSG_PEEK) == 0)
    }

    @Test(.enabled(if: NativeTransferProcess.available))
    func largeClipboardCrossesRecordsInBothDirections() throws {
        let peer = try ClipboardTestPeer(fileTransfer: true)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        let keys = try rekey(peer, level: 1, wrappingKey: #require(peer.appleWrappingKey))
        try peer.write([0x12, 0, 0, 2, 0, 1, 0, 0])
        peer.socket.setAppleRecordWrites(try AppleEncryption.Cipher(keys: keys, encrypt: true))
        // Deterministic, poorly compressible text makes both the upload and
        // download span several encrypted records, without touching a pasteboard.
        var random: UInt32 = 42
        let bytes: [UInt8] = (0..<300_000).map { _ in
            random ^= random << 13; random ^= random >> 17; random ^= random << 5
            return 32 + UInt8(random % 95)
        }
        let content = ClipboardContent.text(String(decoding: bytes, as: UTF8.self))
        let upload = try AppleClipboard.message(content: content, requestID: 0, promises: false)
        #expect(upload.count > AppleEncryption.maxPayloadBytes * 2)
        try peer.write(upload)
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 42])
        #expect(try peer.readClipboard().1.supportedContent == content)
        #expect(peer.clipboard.currentContent() == content)
    }

    @Test(.enabled(if: NativeTransferProcess.available), arguments: [0, 1, 2])
    func malformedEncryptedInputClosesSession(kind: Int) throws {
        let peer = try ClipboardTestPeer(fileTransfer: true)
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        let keys = try rekey(peer, level: 1, wrappingKey: #require(peer.appleWrappingKey))
        try peer.write([0x12, 0, 0, 2, 0, 1, 0, 0])
        var record = try AppleEncryption.Cipher(keys: keys, encrypt: true).seal([0x0a, 0, 0, 1])
        if kind == 0 { record[2] ^= 1 }
        if kind == 1 { record = [0, 16] }
        if kind == 2 { record = [0xff, 0xff] }
        try peer.write(record)
        try #require(peer.hasData(timeout: 2))
        var byte: UInt8 = 0
        #expect(recv(peer.socket.fd, &byte, 1, MSG_PEEK) == 0)
    }

    private func rekey(_ peer: ClipboardTestPeer, level: UInt16, wrappingKey: [UInt8]) throws -> AppleEncryption.Keys {
        try peer.write([0x12, 0, 0, 1] + level.beBytes + [0, 1, 0, 0, 0, 1])
        #expect(try peer.read(20) == [0, 0, 0, 1] + [UInt8](repeating: 0, count: 8)
            + UInt32(1103).beBytes + UInt32(1).beBytes)
        let raw = try AppleEncryption.ecb(peer.read(32), key: wrappingKey, encrypt: false)
        let keys = AppleEncryption.Keys(key: Array(raw.prefix(16)), iv: Array(raw.suffix(16)))
        try peer.socket.prepareAppleRecordReads(keys: keys, timeout: 5)
        try peer.socket.enableAppleRecordReads(level == 1)
        return keys
    }

    private func hex(_ value: String) -> [UInt8] {
        let chars = Array(value)
        return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! }
    }
}

/// Bounded test-only transport. Each direction has one owner and transfer()
/// waits for the writer before returning or accepting another message.
final class EncryptedTestLink: @unchecked Sendable {
    private let lock = NSLock()
    private let sender: ClientSocket
    private let receiver: ClientSocket

    init() throws {
        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw RFBError.socketError("test socketpair failed")
        }
        for fd in fds {
            var enabled: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        }
        sender = try ClientSocket(fd: fds[0])
        receiver = try ClientSocket(fd: fds[1])
        let keys = try AppleEncryption.Keys.random()
        sender.setAppleRecordWrites(try AppleEncryption.Cipher(keys: keys, encrypt: true))
        try receiver.prepareAppleRecordReads(keys: keys, timeout: 3)
        try receiver.enableAppleRecordReads(true)
    }

    func transfer(_ chunks: [[UInt8]]) throws -> [UInt8] {
        try lock.withLock {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { [self] in
                defer { done.signal() }
                do { try sender.writeAll(chunks) }
                catch { Issue.record(error); sender.shutdown() }
            }
            defer { #expect(done.wait(timeout: .now() + 4) == .success) }
            return try receiver.withReadTimeout(3, operation: "encrypted test link") {
                try receiver.readExact(chunks.reduce(0) { $0 + $1.count })
            }
        }
    }
}
