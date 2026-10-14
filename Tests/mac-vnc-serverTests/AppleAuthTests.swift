import Testing
@testable import mac_vnc_server

struct AppleAuthTests {
    @Test func authenticationChecksTheWholePasswordAndInitializesMatchingKeys() throws {
        #expect(AppleAuth.prime.count == 256)
        let server = try AppleAuth.Exchange()
        let client = try AppleAuth.Exchange()
        let key = try client.wrappingKey(peerKey: server.publicKey)
        #expect(try server.wrappingKey(peerKey: client.publicKey) == key)
        let password = "eightchr-and-the-rest"
        var credentials = [UInt8](repeating: 0xa5, count: 128)
        credentials.replaceSubrange(0..<8, with: Array("fixture".utf8) + [0])
        credentials.replaceSubrange(64..<(65 + password.utf8.count), with: Array(password.utf8) + [0])
        let encrypted = try AppleEncryption.ecb(credentials, key: key, encrypt: true)
        let authenticated = try server.authenticateAccount(credentials: encrypted, peerKey: client.publicKey, verify: { name, actual in
            #expect(name == "fixture" && actual == password)
            return name
        })
        #expect(authenticated.1 == key)
        for wrong in ["", "wrong", "eightchr", "eightchr-and-the-reST", password + "x"] {
            #expect(throws: (any Error).self) {
                try server.authenticateAccount(credentials: encrypted, peerKey: client.publicKey, verify: { _, actual in
                    guard actual == wrong else { throw RFBError.authenticationFailed }; return actual
                })
            }
        }
        credentials[0..<64] = ArraySlice(repeating: 1, count: 64)
        let invalidName = try AppleEncryption.ecb(credentials, key: key, encrypt: true)
        #expect(throws: (any Error).self) {
            try server.authenticateAccount(credentials: invalidName, peerKey: client.publicKey, verify: { _, _ in Issue.record("malformed credentials reached verifier"); return 0 })
        }
        credentials.replaceSubrange(0..<8, with: Array("fixture".utf8) + [0])
        credentials[64...] = ArraySlice(repeating: 1, count: 64)
        let invalidPassword = try AppleEncryption.ecb(credentials, key: key, encrypt: true)
        #expect(throws: (any Error).self) {
            try server.authenticateAccount(credentials: invalidPassword, peerKey: client.publicKey, verify: { _, _ in Issue.record("malformed credentials reached verifier"); return 0 })
        }
    }

    @Test func invalidPublicKeysAreRejected() throws {
        let server = try AppleAuth.Exchange()
        let zero = [UInt8](repeating: 0, count: 256)
        var one = zero; one[255] = 1
        var minusOne = AppleAuth.prime; minusOne[255] -= 1
        for key in [[], zero, one, minusOne, AppleAuth.prime] {
            #expect(throws: (any Error).self) { try server.wrappingKey(peerKey: key) }
        }
    }
}
