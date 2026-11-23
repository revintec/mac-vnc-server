import Foundation
import Testing
@testable import mac_vnc_server

struct RemoteSessionStatusTests {
    private let own = ConsoleIdentity(uid: 501, auditID: 2)
    private let other = ConsoleIdentity(uid: 502, auditID: 3)
    private let loginWindow = ConsoleIdentity(uid: 0, auditID: 4)

    @MainActor @Test func activityChangesDoNotBlockConnectionThreadsBehindTheUI() async {
        let activity = SessionActivity()
        let deliveries = ActivityNotificationCount()
        let token = NotificationCenter.default.addObserver(
            forName: SessionActivity.didChangeNotification, object: nil, queue: .main) { _ in
                deliveries.increment()
            }
        defer { NotificationCenter.default.removeObserver(token) }
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            activity.changed()
            activity.changed()
            returned.signal()
        }
        // Keep the UI occupied while both connection-thread notifications are
        // sent. They must return before the main queue can deliver either one.
        func connectionReturnedWithoutRunningUI() -> Bool {
            returned.wait(timeout: .now() + 1) == .success
        }
        #expect(connectionReturnedWithoutRunningUI())
        for _ in 0..<100 {
            if deliveries.value != 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        withExtendedLifetime(activity) { #expect(deliveries.value == 1) }
    }

    private func state(console: ConsoleIdentity?, onConsole: Bool?, locked: Bool? = nil,
                       stable: Bool = true, verified: Bool = true) -> PhysicalDisplayState {
        PhysicalDisplayState.resolve(uid: 501,
            session: .init(identity: own, onConsole: onConsole, locked: locked), console: console,
            observationsStable: stable, sessionVerified: verified)
    }

    @Test func onlyVerifiedOffConsoleSessionsCanUseTheNormalIcon() {
        for console in [other, loginWindow] {
            for locked: Bool? in [false, true, nil] {
                let hidden = state(console: console, onConsole: false, locked: locked)
                #expect(hidden.isConfirmedHidden)
                #expect(!hidden.canSwitchToLoginWindow)
                var indicator = PhysicalDisplayIndicator()
                #expect(indicator.showsEye)
                indicator.update(hidden, at: 1)
                #expect(indicator.showsEye)
                indicator.update(hidden, at: 1.5)
                #expect(!indicator.showsEye)
            }
        }
    }

    @Test func owningConsoleShowsEyeEvenWhenLockedOrIdle() {
        for locked: Bool? in [false, true, nil] {
            let onConsole = state(console: own, onConsole: true, locked: locked)
            #expect(!onConsole.isConfirmedHidden)
            var indicator = PhysicalDisplayIndicator()
            indicator.update(onConsole, at: 1)
            indicator.update(onConsole, at: 30)
            #expect(indicator.showsEye) // No client-count exception exists.
            #expect(onConsole.canSwitchToLoginWindow)
        }
    }

    @Test func missingContradictoryOrChangingEvidenceNeverConfirmsHidden() {
        let uncertain = [
            state(console: nil, onConsole: false),
            state(console: loginWindow, onConsole: nil),
            state(console: loginWindow, onConsole: true),
            state(console: own, onConsole: false),
            state(console: loginWindow, onConsole: false, stable: false),
            state(console: loginWindow, onConsole: false, verified: false),
            state(console: .init(uid: 501, auditID: 99), onConsole: false),
            state(console: .init(uid: 0, auditID: 0), onConsole: false)
        ]
        for value in uncertain {
            #expect(value.visibility == .unknown)
            #expect(!value.canSwitchToLoginWindow)
            var indicator = PhysicalDisplayIndicator()
            indicator.update(value, at: 1)
            indicator.update(value, at: 2)
            #expect(indicator.showsEye)
        }
        for identity: ConsoleIdentity? in [nil, .init(uid: 502, auditID: 2), .init(uid: 501, auditID: 0)] {
            let value = PhysicalDisplayState.resolve(uid: 501,
                session: .init(identity: identity, onConsole: false, locked: true), console: loginWindow,
                observationsStable: true, sessionVerified: true)
            #expect(value.visibility == .unknown)
        }
    }

    @Test func staleHiddenEvidenceIsDiscardedImmediately() {
        let hidden = state(console: loginWindow, onConsole: false)
        let unknown = state(console: nil, onConsole: false)
        var indicator = PhysicalDisplayIndicator()
        indicator.update(hidden, at: 1)
        indicator.update(hidden, at: 1.5)
        #expect(!indicator.showsEye)
        indicator.update(unknown, at: 1.6)
        #expect(indicator.showsEye)
        indicator.update(hidden, at: 1.7)
        indicator.update(hidden, at: 2.1)
        #expect(indicator.showsEye)
        indicator.update(hidden, at: 2.2)
        #expect(!indicator.showsEye)
        indicator.invalidate() // Console/session/wake notification.
        #expect(indicator.showsEye)
        indicator.update(hidden, at: 3)
        #expect(indicator.showsEye)
        indicator.update(hidden, at: 3.5)
        #expect(!indicator.showsEye)
        indicator.update(state(console: other, onConsole: false), at: 3.6)
        #expect(indicator.showsEye)
        indicator.update(state(console: own, onConsole: true, locked: false), at: 3.7)
        #expect(indicator.showsEye)
    }

    @Test func venturaLoginwindowInsideLockedUserSessionIsNeverConfirmedHidden() {
        // The Mac mini probe found loginwindow, Finder and the worker all in
        // UID 501/audit 100005, while the device itself was owned by root.
        let locked = state(console: loginWindow, onConsole: true, locked: true)
        #expect(locked.visibility == .unknown)
        #expect(!locked.isConfirmedHidden)
        #expect(!locked.canSwitchToLoginWindow)
        var indicator = PhysicalDisplayIndicator()
        indicator.update(locked, at: 1)
        indicator.update(locked, at: 30)
        #expect(indicator.showsEye)
    }

    @Test func missingOrInvalidDictionaryValuesRemainUnknown() {
        let absent = PhysicalSessionSnapshot(dictionary: nil)
        #expect(absent.identity == nil && absent.onConsole == nil && absent.locked == nil)
        let base: [String: Any] = ["kCGSSessionUserIDKey": 501, "kCGSSessionAuditIDKey": 2]
        let missingFlags = PhysicalSessionSnapshot(dictionary: base)
        #expect(missingFlags.identity == own)
        #expect(missingFlags.onConsole == nil && missingFlags.locked == nil)
        for flag: Any in [2, -1, 0.5, "false"] {
            var values = base
            values["kCGSSessionOnConsoleKey"] = flag
            values["CGSSessionScreenIsLocked"] = flag
            let decoded = PhysicalSessionSnapshot(dictionary: values)
            #expect(decoded.onConsole == nil && decoded.locked == nil)
        }
        for value: Any in [-1, 501.5, true, "501"] {
            var values = base; values["kCGSSessionUserIDKey"] = value
            #expect(PhysicalSessionSnapshot(dictionary: values).identity == nil)
        }
        for flag: Any in [false, 0, NSNumber(value: false)] {
            var values = base; values["kCGSSessionOnConsoleKey"] = flag
            #expect(PhysicalSessionSnapshot(dictionary: values).onConsole == false)
        }
    }

    @Test func sessionDetailsExplainIdentitiesFlagsAndUncertainty() {
        let hidden = state(console: loginWindow, onConsole: false)
        #expect(hidden.sessionDetails.contains("Worker session: UID 501, audit 2"))
        #expect(hidden.sessionDetails.contains("Console owner session (device): loginwindow — UID 0, audit 4"))
        #expect(hidden.sessionDetails.contains("Worker session lock flag: Unknown"))
        #expect(hidden.sessionDetails.contains(hidden.reason))
        let unknown = state(console: nil, onConsole: nil)
        #expect(unknown.sessionDetails.contains("Console owner session (device): Unavailable"))
        #expect(unknown.sessionDetails.contains("Worker session on console: Unknown"))
        #expect(unknown.description.contains("unconfirmed"))
    }

    @Test func switchingRequiresVerifiedOwnershipOfThisAuditSession() {
        #expect(state(console: own, onConsole: true, locked: false).canSwitchToLoginWindow)
        #expect(state(console: own, onConsole: true, locked: true).canSwitchToLoginWindow)
        #expect(!state(console: own, onConsole: true, verified: false).canSwitchToLoginWindow)
        #expect(!state(console: .init(uid: 501, auditID: 99), onConsole: true).canSwitchToLoginWindow)
        #expect(!PhysicalDisplayState.resolve(uid: 0,
            session: .init(identity: loginWindow, onConsole: true, locked: false), console: loginWindow,
            observationsStable: true, sessionVerified: true).canSwitchToLoginWindow)
    }

    @Test func consoleControlsRequirePrivilegesAndConfirmedOffConsoleState() {
        #expect(state(console: other, onConsole: false).canUseConsoleControls(privileged: true))
        #expect(state(console: loginWindow, onConsole: false).canUseConsoleControls(privileged: true))
        #expect(!state(console: other, onConsole: false).canUseConsoleControls(privileged: false))
        #expect(!state(console: own, onConsole: true).canUseConsoleControls(privileged: true))
        #expect(!state(console: loginWindow, onConsole: true, locked: true).canUseConsoleControls(privileged: true))
        #expect(!state(console: other, onConsole: false, stable: false).canUseConsoleControls(privileged: true))
        #expect(!state(console: other, onConsole: false, verified: false).canUseConsoleControls(privileged: true))
    }
}

private final class ActivityNotificationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
