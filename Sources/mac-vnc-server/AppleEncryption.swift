import CommonCrypto
import Foundation
import Security

/// Apple's legacy RFB record format, using a wrapping key established by
/// security type 30. This protocol does not authenticate the server's identity.
enum AppleEncryption {
    static let maxCiphertextBytes = 65_520
    static let maxPayloadBytes = maxCiphertextBytes - 22

    struct Keys {
        let key: [UInt8]
        let iv: [UInt8]

        static func random() throws -> Keys {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw RFBError.protocolError("could not generate Apple encryption keys")
            }
            return Keys(key: Array(bytes.prefix(16)), iv: Array(bytes.suffix(16)))
        }

        func update(wrappingKey: [UInt8]) throws -> [UInt8] {
            // One zero-geometry framebuffer rectangle, encoding 1103. The
            // leading word is the cipher method (AES=1), not a sequence number.
            let wrapped = try AppleEncryption.ecb(key + iv, key: wrappingKey, encrypt: true)
            return [0, 0, 0, 1] + [UInt8](repeating: 0, count: 8)
                + UInt32(1103).beBytes + UInt32(1).beBytes + wrapped
        }
    }

    static func ecb(_ bytes: [UInt8], key: [UInt8], encrypt: Bool) throws -> [UInt8] {
        guard key.count == 16, !bytes.isEmpty, bytes.count % 16 == 0 else {
            throw RFBError.protocolError("invalid Apple encryption key or block size")
        }
        var output = [UInt8](repeating: 0, count: bytes.count)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode), key, key.count, nil, bytes, bytes.count,
            &output, output.count, &moved)
        guard status == kCCSuccess, moved == bytes.count else {
            throw RFBError.protocolError("Apple AES block operation failed")
        }
        return output
    }

    /// Fixed-size EncryptedInputEvent (0x10), under the current ECB key.
    /// Native rekey replaces this key together with the record ciphers. The
    /// markers distinguish key/pointer/empty events; validate both before input.
    struct InputEvent {
        struct Key: Equatable { let down: Bool; let keysym: UInt32 }
        struct Pointer: Equatable { let mask: UInt8; let x: UInt16; let y: UInt16 }
        let key: Key?
        let pointer: Pointer?

        init(ciphertext: [UInt8], key: [UInt8]) throws {
            guard ciphertext.count == 16 else {
                throw RFBError.protocolError("invalid Apple encrypted input size")
            }
            let bytes = try AppleEncryption.ecb(ciphertext, key: key, encrypt: false)
            guard (bytes[0] == 0 || bytes[0] == 0xff), (bytes[10] == 0 || bytes[10] == 0xff) else {
                throw RFBError.protocolError("invalid Apple encrypted input markers")
            }
            self.key = bytes[0] == 0xff
                ? Key(down: bytes[1] != 0, keysym: UInt32.be(bytes[2], bytes[3], bytes[4], bytes[5])) : nil
            pointer = bytes[10] == 0xff
                ? Pointer(mask: bytes[11], x: UInt16.be(bytes[12], bytes[13]), y: UInt16.be(bytes[14], bytes[15])) : nil
        }
    }

    /// Owned by one reader or writer. CBC chaining and the integrity sequence
    /// continue across records; each direction has its own instance.
    final class Cipher {
        private let cryptor: CCCryptorRef
        private let encrypting: Bool
        private var sequence: UInt32 = 0

        init(keys: Keys, encrypt: Bool) throws {
            guard keys.key.count == 16, keys.iv.count == 16 else {
                throw RFBError.protocolError("invalid Apple record key or IV")
            }
            var value: CCCryptorRef?
            let status = CCCryptorCreate(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES), 0, keys.key, 16, keys.iv, &value)
            guard status == kCCSuccess, let value else {
                throw RFBError.protocolError("could not initialize Apple record cipher")
            }
            cryptor = value
            encrypting = encrypt
        }

        deinit { CCCryptorRelease(cryptor) }

        func seal(_ payload: [UInt8]) throws -> [UInt8] {
            guard encrypting, !payload.isEmpty, payload.count <= maxPayloadBytes else {
                throw RFBError.protocolError("invalid Apple record payload size")
            }
            var body = UInt16(payload.count).beBytes + payload
            body += [UInt8](repeating: 0, count: (16 - (body.count + 20) % 16) % 16)
            body += digest(body)
            let ciphertext = try transform(body)
            sequence &+= 1
            return UInt16(ciphertext.count).beBytes + ciphertext
        }

        func open(_ ciphertext: [UInt8]) throws -> [UInt8] {
            guard !encrypting, ciphertext.count >= 32, ciphertext.count <= maxCiphertextBytes,
                  ciphertext.count % 16 == 0 else {
                throw RFBError.protocolError("invalid Apple encrypted record size")
            }
            let body = try transform(ciphertext)
            let signed = Array(body.dropLast(20))
            let expected = digest(signed)
            let difference = zip(expected, body.suffix(20)).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
            guard difference == 0 else {
                throw RFBError.protocolError("Apple encrypted record integrity check failed")
            }
            let count = Int(UInt16.be(body[0], body[1]))
            guard count > 0, count <= signed.count - 2, signed.count - 2 - count < 16 else {
                throw RFBError.protocolError("invalid Apple decrypted payload size")
            }
            sequence &+= 1
            return Array(body[2..<(2 + count)])
        }

        private func digest(_ bytes: [UInt8]) -> [UInt8] {
            let input = sequence.beBytes + bytes
            var output = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            _ = CC_SHA1(input, CC_LONG(input.count), &output)
            return output
        }

        private func transform(_ bytes: [UInt8]) throws -> [UInt8] {
            var output = [UInt8](repeating: 0, count: bytes.count)
            var moved = 0
            let status = CCCryptorUpdate(cryptor, bytes, bytes.count, &output, output.count, &moved)
            guard status == kCCSuccess, moved == bytes.count else {
                throw RFBError.protocolError("Apple record cipher failed")
            }
            return output
        }
    }
}
