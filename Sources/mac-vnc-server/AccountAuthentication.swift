import CVNCSession
import Darwin
import Foundation
import OpenDirectory

enum AccountListenerAccess: Equatable {
    case allAccounts
    case ownAccount(UInt32)

    static func resolve(realUID: UInt32 = getuid(), effectiveUID: UInt32 = geteuid()) throws -> Self {
        // Worker attachment expects normal process credentials, not a setuid
        // executable. Check this before advertising account-routing capability.
        guard realUID == effectiveUID else {
            throw CLIError.commandFailed("account listener requires matching real and effective user IDs; start it normally or with sudo")
        }
        return effectiveUID == 0 ? .allAccounts : .ownAccount(effectiveUID)
    }

    func permits(uid: UInt32) -> Bool {
        switch self {
        case .allAccounts: return true
        case .ownAccount(let ownUID): return uid == ownUID
        }
    }
}

enum AccountAuthentication {
    // OpenDirectory checks password and account policies (disabled/expired/
    // locked accounts included). Never invoke a shell or macOS GUI login.
    static func verify(username: String, password: String) throws -> ConsoleIdentity {
        let uid: UInt32
        do {
            let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: username,
                                         attributes: [kODAttributeTypeUniqueID])
            try record.verifyPassword(password)
            let identifiers = try record.values(forAttribute: kODAttributeTypeUniqueID)
            guard let value = identifiers.first as? String, let identifier = UInt32(value) else {
                throw RFBError.authenticationFailed
            }
            uid = identifier
        } catch {
            // Do not expose account existence, policy details, or credential text.
            throw RFBError.authenticationFailed
        }
        return try sessionForVerifiedAccount(uid: uid, access: AccountListenerAccess.resolve())
    }

    static func sessionForVerifiedAccount(uid: UInt32, access: AccountListenerAccess,
                                          console: () -> ConsoleIdentity? = ConsoleIdentity.current) throws -> ConsoleIdentity {
        // Check the authenticated account, not the selected desktop's UID.
        // A non-root listener cannot accept root even when the console belongs
        // to its own user; knowing root's password does not elevate a process.
        guard access.permits(uid: uid) else { throw RFBError.authenticationFailed }
        // Session selection happens only after password/account-policy checks.
        // Preserve its actionable error instead of calling a valid password bad.
        return try session(uid: uid, console: console)
    }

    static func session(uid: UInt32, console: () -> ConsoleIdentity? = ConsoleIdentity.current) throws -> ConsoleIdentity {
        if uid == 0 {
            // Root selects the console owner at authentication time. Returning
            // the user's real UID/audit identity lets the worker pool reuse that
            // desktop's ordinary user worker and permanently drop privileges.
            guard let identity = console() else { throw AccountSessionError.consoleUnavailable }
            return identity
        }
        var identity = VNCConsoleIdentity()
        guard VNCSessionForUser(uid, &identity) == 0 else { throw AccountSessionError.sessionUnavailable }
        return ConsoleIdentity(uid: identity.uid, auditID: identity.audit_id)
    }
}

enum AccountSessionError: Error, LocalizedError, Equatable {
    case consoleUnavailable
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .consoleUnavailable:
            return "The password was accepted, but the physical console session could not be verified. If the Mac is switching users, wait for that to finish before reconnecting."
        case .sessionUnavailable:
            return "The password was accepted, but the requested user has no available graphical session. Sign in as that user at the Mac first, then reconnect."
        }
    }
}

/// Only protocol state crosses the private socket, never account credentials.
/// The worker sends SecurityResult and ServerInit after it is ready to serve.
struct SessionAdmission: Codable, Sendable {
    let identity: ConsoleIdentity
    let version: String
    let wrappingKey: [UInt8]

    func validate(for identity: ConsoleIdentity) throws {
        guard self.identity == identity, wrappingKey.count == 16,
              [AppleRFB.version, "RFB 003.008\n", "RFB 003.007\n"].contains(version) else {
            throw RFBError.authenticationFailed
        }
    }
}

enum AccountHandshake {
    static func authenticate(socket: ClientSocket, handshakeTimeout: TimeInterval = 5,
                             authenticationTimeout: TimeInterval = 120,
                             verify: (String, String) throws -> ConsoleIdentity = AccountAuthentication.verify) throws -> SessionAdmission {
        try socket.withReadTimeout(handshakeTimeout, operation: "account RFB handshake") {
            try socket.writeString(AppleRFB.version)
            let version = String(decoding: try socket.readExact(12), as: UTF8.self)
            guard [AppleRFB.version, "RFB 003.008\n", "RFB 003.007\n"].contains(version) else {
                let reason = Array("This endpoint requires username/password authentication (ARD security type 30).".utf8)
                if version == "RFB 003.003\n" {
                    try socket.writeAll(UInt32(0).beBytes + UInt32(reason.count).beBytes + reason)
                }
                throw RFBError.protocolError("viewer does not support account authentication")
            }
            try socket.writeAll([1, 30])
            let deadline = DispatchTime.now() + authenticationTimeout
            func humanResponse(_ count: Int) throws -> [UInt8] {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline.uptimeNanoseconds else { throw RFBError.authenticationFailed }
                let remaining = Double(deadline.uptimeNanoseconds - now) / 1_000_000_000
                let first = try socket.withReadTimeout(remaining, operation: "account password entry", suspendingOuterDeadline: true) {
                    try socket.readExact(1)
                }
                return try first + socket.readExact(count - 1)
            }
            do {
                guard try humanResponse(1) == [30] else { throw RFBError.authenticationFailed }
                let exchange = try AppleAuth.Exchange()
                try socket.writeAll(exchange.challenge)
                let credentials = try humanResponse(128)
                let peer = try socket.readExact(AppleAuth.prime.count)
                let (identity, key) = try exchange.authenticateAccount(credentials: credentials, peerKey: peer, verify: verify)
                return SessionAdmission(identity: identity, version: version, wrappingKey: key)
            } catch {
                try? reject(socket: socket, version: version, error: error)
                throw error
            }
        }
    }

    static func reject(socket: ClientSocket, version: String, error: (any Error)? = nil) throws {
        var bytes = UInt32(1).beBytes
        if version == "RFB 003.008\n" {
            // Only our post-authentication session errors may expose detail.
            let message = (error as? AccountSessionError)?.errorDescription
                ?? "Authentication failed or the requested session is unavailable."
            let reason = Array(message.utf8)
            bytes += UInt32(reason.count).beBytes + reason
        }
        try socket.writeAll(bytes)
    }
}
