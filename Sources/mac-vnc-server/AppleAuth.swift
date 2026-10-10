import CommonCrypto
import Darwin
import Foundation

/// Apple security type 30 establishes the wrapping key required by encoding
/// 1103. Classic VNC authentication does not initialize that key in the viewer.
/// The username is a display label; access uses this server's shared password,
/// never a macOS account password or a system login.
enum AppleAuth {
    // RFC 3526 group 14 (2048-bit safe prime, generator 2).
    static let prime: [UInt8] = {
        let hex = """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E08
        8A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD
        3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625
        E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A8
        99FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163
        BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3A
        D961C62F356208552BB9ED529077096966D670C354E4ABC9804
        F1746C08CA18217C32905E462E36CE3BE39E772C180E86039
        B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183
        995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF
        """.filter { !$0.isWhitespace }
        let chars = Array(hex)
        return stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        }
    }()

    final class Exchange {
        private let api: DHFunctions
        private let context: OpaquePointer
        let publicKey: [UInt8]

        init() throws {
            guard let api = DHFunctions.shared else {
                throw RFBError.protocolError("macOS Diffie-Hellman functions unavailable")
            }
            var context: OpaquePointer?
            guard api.create(2, prime, prime.count, 0, nil, 0, &context) == 0, let context else {
                throw RFBError.protocolError("could not initialize Apple authentication")
            }
            var bytes = [UInt8](repeating: 0, count: prime.count)
            var count = bytes.count
            guard api.generate(context, &bytes, &count) == 0, count > 0, count <= bytes.count else {
                api.destroy(context)
                throw RFBError.protocolError("could not generate Apple authentication key")
            }
            self.api = api
            self.context = context
            publicKey = [UInt8](repeating: 0, count: prime.count - count) + bytes.prefix(count)
        }

        deinit { api.destroy(context) }

        var challenge: [UInt8] { UInt16(2).beBytes + UInt16(prime.count).beBytes + prime + publicKey }

        func wrappingKey(peerKey: [UInt8]) throws -> [UInt8] {
            guard peerKey.count == prime.count else { throw RFBError.authenticationFailed }
            var secret = [UInt8](repeating: 0, count: prime.count)
            var count = secret.count
            // SecDH validates the peer's public value and computes the secret
            // using the system crypto implementation. ARD hashes the full-width
            // big-endian secret, including any leading zero bytes.
            guard api.compute(context, peerKey, peerKey.count, &secret, &count) == 0,
                  count > 0, count <= secret.count else { throw RFBError.authenticationFailed }
            var padded = [UInt8](repeating: 0, count: prime.count - count) + secret.prefix(count)
            defer { secret.withUnsafeMutableBytes { _ = memset_s($0.baseAddress!, $0.count, 0, $0.count) }
                padded.withUnsafeMutableBytes { _ = memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
            var key = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            _ = CC_MD5(padded, CC_LONG(padded.count), &key)
            return key
        }

        func authenticate(credentials: [UInt8], peerKey: [UInt8], password: String) throws -> [UInt8] {
            let key = try wrappingKey(peerKey: peerKey)
            guard credentials.count == 128 else { throw RFBError.authenticationFailed }
            var clear = try AppleEncryption.ecb(credentials, key: key, encrypt: false)
            defer { clear.withUnsafeMutableBytes { _ = memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
            guard clear[..<64].contains(0), let end = clear[64...].firstIndex(of: 0) else {
                throw RFBError.authenticationFailed
            }
            let expected = Array(password.utf8)
            guard expected.count < 64, !expected.contains(0) else { throw RFBError.authenticationFailed }
            var difference = UInt8(expected.count ^ (end - 64))
            for index in 0..<63 {
                let actual = index < end - 64 ? clear[64 + index] : 0
                difference |= actual ^ (index < expected.count ? expected[index] : 0)
            }
            guard difference == 0 else { throw RFBError.authenticationFailed }
            return key
        }
    }

    // These long-standing Security entry points remain exported on supported
    // macOS versions, but their header is absent from current public SDKs.
    // Resolve the C ABI explicitly and fail closed if a future OS removes it.
    // Signatures: apple-oss-distributions/Security, OSX/sec/Security/SecDH.h.
    private struct DHFunctions: @unchecked Sendable {
        typealias Create = @convention(c) (UInt32, UnsafePointer<UInt8>, Int, UInt32,
            UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<OpaquePointer?>) -> Int32
        typealias Generate = @convention(c) (OpaquePointer, UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<Int>) -> Int32
        typealias Compute = @convention(c) (OpaquePointer, UnsafePointer<UInt8>, Int,
            UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<Int>) -> Int32
        typealias Destroy = @convention(c) (OpaquePointer) -> Void
        let create: Create
        let generate: Generate
        let compute: Compute
        let destroy: Destroy

        static let shared: DHFunctions? = {
            guard let library = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL),
                  let create = dlsym(library, "SecDHCreate"),
                  let generate = dlsym(library, "SecDHGenerateKeypair"),
                  let compute = dlsym(library, "SecDHComputeKey"),
                  let destroy = dlsym(library, "SecDHDestroy") else { return nil }
            return DHFunctions(create: unsafeBitCast(create, to: Create.self),
                generate: unsafeBitCast(generate, to: Generate.self), compute: unsafeBitCast(compute, to: Compute.self),
                destroy: unsafeBitCast(destroy, to: Destroy.self))
        }()
    }
}
