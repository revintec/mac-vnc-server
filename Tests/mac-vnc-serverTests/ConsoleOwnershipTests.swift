import CoreFoundation
import CVNCSession
import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

struct ConsoleOwnershipTests {
    private func session(uid: UInt32, audit: Int32, onConsole: Bool) -> [String: Any] {
        ["kCGSSessionUserIDKey": uid, "kCGSSessionAuditIDKey": audit,
         "kSCSecuritySessionID": audit, "kCGSSessionOnConsoleKey": onConsole]
    }

    private func state(uid: UInt32, sessions: [[String: Any]]) -> [String: Any] {
        ["UID": uid, "Name": uid == 0 ? "loginwindow" : "revin", "SessionInfo": sessions]
    }

    private func resolve(_ state: [String: Any], deviceOwner: UInt32,
                         expectedError: Int32 = 0) -> ConsoleIdentity? {
        var result = VNCConsoleIdentity(uid: 999, audit_id: 999)
        let error = VNCConsoleResolveIdentity(state as CFDictionary, deviceOwner, &result)
        #expect(error == expectedError)
        guard error == 0 else {
            #expect(result.uid == 999 && result.audit_id == 999) // Never expose a partial selection.
            return nil
        }
        return ConsoleIdentity(uid: result.uid, auditID: result.audit_id)
    }

    @Test func venturaDeviceOwnerDoesNotOverrideGraphicsRouting() {
        // Exact UID/audit/OnConsole combination reported by the Mac mini.
        let rows = [session(uid: 0, audit: 100154, onConsole: false),
                    session(uid: 501, audit: 100005, onConsole: true)]
        #expect(resolve(state(uid: 0, sessions: rows), deviceOwner: 0)
                == ConsoleIdentity(uid: 0, auditID: 100154))
        var output = VNCConsoleIdentity(uid: 999, audit_id: 999)
        #expect(VNCConsoleResolveCaptureIdentity(state(uid: 0, sessions: rows) as CFDictionary,
            rows as CFArray, 0, &output) == ESTALE)
        #expect(output.uid == 999 && output.audit_id == 999)
        // Once ownership agrees with graphics, the user route is valid again.
        #expect(resolve(state(uid: 501, sessions: rows), deviceOwner: 501)
                == ConsoleIdentity(uid: 501, auditID: 100005))
        #expect(VNCConsoleResolveCaptureIdentity(state(uid: 501, sessions: rows) as CFDictionary,
            rows as CFArray, 501, &output) == 0)
        #expect(output.uid == 501 && output.audit_id == 100005)
    }

    @Test func captureRequiresUnambiguousConsoleFlags() {
        let root = session(uid: 0, audit: 7, onConsole: true)
        let user = session(uid: 501, audit: 8, onConsole: false)
        var output = VNCConsoleIdentity()
        #expect(VNCConsoleResolveCaptureIdentity(state(uid: 0, sessions: [root, user]) as CFDictionary,
            [root, user] as CFArray, 0, &output) == 0)
        #expect(output.uid == 0 && output.audit_id == 7)
        for rows in [[root, session(uid: 501, audit: 8, onConsole: true)],
                     [session(uid: 0, audit: 7, onConsole: false), user],
                     [root, session(uid: 0, audit: 7, onConsole: false)]] {
            output = VNCConsoleIdentity(uid: 999, audit_id: 999)
            #expect(VNCConsoleResolveCaptureIdentity(state(uid: 0, sessions: rows) as CFDictionary,
                rows as CFArray, 0, &output) == ESTALE)
            #expect(output.uid == 999 && output.audit_id == 999)
        }
    }

    @Test func staleConfigdFlagsDoNotRejectTheVerifiedGraphicsConsole() {
        // Reproduced on Tahoe after switching to loginwindow: configd still
        // marks the user on-console while IORegistry correctly marks root.
        let staleRows = [session(uid: 0, audit: 100907, onConsole: false),
                         session(uid: 501, audit: 100021, onConsole: true)]
        let liveRows = [session(uid: 0, audit: 100907, onConsole: true),
                        session(uid: 501, audit: 100021, onConsole: false)]
        var output = VNCConsoleIdentity()
        #expect(VNCConsoleResolveCaptureIdentity(state(uid: 0, sessions: staleRows) as CFDictionary,
            liveRows as CFArray, 0, &output) == 0)
        #expect(output.uid == 0 && output.audit_id == 100907)
        // The reverse transition also follows live graphics flags, preserving
        // root login's ability to select the ordinary user's desktop.
        #expect(VNCConsoleResolveCaptureIdentity(state(uid: 501, sessions: liveRows) as CFDictionary,
            staleRows as CFArray, 501, &output) == 0)
        #expect(output.uid == 501 && output.audit_id == 100021)
    }

    @Test func registryEvidenceMustMatchTheOwnerAndAuditAndBeComplete() {
        let root = session(uid: 0, audit: 7, onConsole: true)
        let snapshot = state(uid: 0, sessions: [root]) as CFDictionary
        var output = VNCConsoleIdentity(uid: 999, audit_id: 999)
        #expect(VNCConsoleResolveCaptureIdentity(snapshot, nil, 0, &output) == ENXIO)
        #expect(output.uid == 999 && output.audit_id == 999)
        for rows in [[], [session(uid: 0, audit: 8, onConsole: true)],
                     [session(uid: 501, audit: 7, onConsole: true)]] {
            #expect(VNCConsoleResolveCaptureIdentity(snapshot, rows as CFArray, 0, &output) == ESTALE)
            #expect(output.uid == 999 && output.audit_id == 999)
        }
        var missingFlag = root; missingFlag.removeValue(forKey: "kCGSSessionOnConsoleKey")
        var invalidFlag = root; invalidFlag["kCGSSessionOnConsoleKey"] = 2
        var inconsistentAudit = root; inconsistentAudit["kSCSecuritySessionID"] = 8
        for row in [missingFlag, invalidFlag, inconsistentAudit] {
            #expect(VNCConsoleResolveCaptureIdentity(snapshot, [row] as CFArray, 0, &output) == EINVAL)
            #expect(output.uid == 999 && output.audit_id == 999)
        }
    }

    @Test func consistentConsoleFlagsContinueToSelectThePhysicalOwner() {
        let rows = [session(uid: 0, audit: 7, onConsole: true),
                    session(uid: 501, audit: 8, onConsole: false)]
        #expect(resolve(state(uid: 0, sessions: rows), deviceOwner: 0)
                == ConsoleIdentity(uid: 0, auditID: 7))
        #expect(resolve(state(uid: 501, sessions: rows.reversed()), deviceOwner: 501)
                == ConsoleIdentity(uid: 501, auditID: 8))
    }

    @Test func independentOwnerDisagreementCannotSelectADesktop() {
        let rows = [session(uid: 0, audit: 7, onConsole: false),
                    session(uid: 501, audit: 8, onConsole: true)]
        #expect(resolve(state(uid: 501, sessions: rows), deviceOwner: 0, expectedError: ESTALE) == nil)
        #expect(resolve(state(uid: 0, sessions: rows), deviceOwner: 501, expectedError: ESTALE) == nil)
    }

    @Test func missingAndAmbiguousAuditSessionsAreRejectedEvenWithAnOnConsoleFlag() {
        let root = session(uid: 0, audit: 7, onConsole: false)
        #expect(resolve(state(uid: 0, sessions: [session(uid: 501, audit: 8, onConsole: true)]),
                        deviceOwner: 0, expectedError: ENXIO) == nil)
        #expect(resolve(state(uid: 0, sessions: [root, session(uid: 0, audit: 9, onConsole: true)]),
                        deviceOwner: 0, expectedError: EEXIST) == nil)
        #expect(resolve(state(uid: 0, sessions: [root, root]), deviceOwner: 0)
                == ConsoleIdentity(uid: 0, auditID: 7))
    }

    @Test func malformedOwnerOrAuditDataCannotProduceAnIdentity() {
        let root = session(uid: 0, audit: 7, onConsole: false)
        let good = state(uid: 0, sessions: [root])
        for value: Any in [true, "0", -1, 0.5, UInt64(UInt32.max) + 1] {
            var invalid = good; invalid["UID"] = value
            #expect(resolve(invalid, deviceOwner: 0, expectedError: EINVAL) == nil)
        }
        for value: Any in [false, "7", -1, 0, 7.5, Int64(Int32.max) + 1] {
            var row = root; row["kCGSSessionAuditIDKey"] = value
            #expect(resolve(state(uid: 0, sessions: [row]), deviceOwner: 0, expectedError: EINVAL) == nil)
        }
        var row = root; row["kSCSecuritySessionID"] = 9
        #expect(resolve(state(uid: 0, sessions: [row]), deviceOwner: 0, expectedError: EINVAL) == nil)
        var invalid = good; invalid["SessionInfo"] = "unavailable"
        #expect(resolve(invalid, deviceOwner: 0, expectedError: ENXIO) == nil)
        invalid = good; invalid.removeValue(forKey: "SessionInfo")
        #expect(resolve(invalid, deviceOwner: 0, expectedError: ENXIO) == nil)
        invalid = state(uid: 501, sessions: [session(uid: 501, audit: 8, onConsole: true)])
        invalid["Name"] = "loginwindow"
        #expect(resolve(invalid, deviceOwner: 501, expectedError: EINVAL) == nil)
    }
}
