import CoreGraphics
import CVNCSession
import Darwin
import Foundation

struct ConsoleIdentity: Codable, Hashable, Sendable {
    let uid: UInt32
    let auditID: Int32
    var native: VNCConsoleIdentity { VNCConsoleIdentity(uid: uid, audit_id: auditID) }

    static func current() -> ConsoleIdentity? {
        var value = VNCConsoleIdentity()
        guard VNCConsoleCurrent(&value) == 0 else { return nil }
        return ConsoleIdentity(uid: value.uid, auditID: value.audit_id)
    }
    func verifyWorker() -> Bool { VNCConsoleVerify(native) == 0 }
}
