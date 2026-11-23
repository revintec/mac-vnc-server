import AppKit
import CoreGraphics
import CVNCSession
import Darwin
import Foundation

struct PhysicalSessionSnapshot: Equatable {
    let identity: ConsoleIdentity?
    let onConsole: Bool?
    let locked: Bool?

    init(identity: ConsoleIdentity?, onConsole: Bool?, locked: Bool?) {
        self.identity = identity; self.onConsole = onConsole; self.locked = locked
    }

    init(dictionary: [String: Any]?) {
        func integer(_ key: String) -> Int64? {
            guard let value = dictionary?[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue == Double(value.int64Value) else { return nil }
            return value.int64Value
        }
        func flag(_ key: String) -> Bool? {
            guard let value = dictionary?[key] as? NSNumber else { return nil }
            switch value.doubleValue {
            case 0: return false
            case 1: return true
            default: return nil
            }
        }
        if let rawUID = integer("kCGSSessionUserIDKey"), let uid = UInt32(exactly: rawUID),
           let rawAudit = integer("kCGSSessionAuditIDKey"), let audit = Int32(exactly: rawAudit), audit > 0 {
            identity = ConsoleIdentity(uid: uid, auditID: audit)
        } else { identity = nil }
        onConsole = flag("kCGSSessionOnConsoleKey")
        locked = flag("CGSSessionScreenIsLocked")
    }

    static func read() -> Self { Self(dictionary: CGSessionCopyCurrentDictionary() as? [String: Any]) }
}

struct PhysicalDisplayState: Equatable {
    enum Visibility: Equatable { case visible, hidden, unknown }
    let visibility: Visibility
    let canSwitchToLoginWindow: Bool
    let session: PhysicalSessionSnapshot
    let console: ConsoleIdentity?
    let reason: String

    static func read(uid: UInt32 = getuid()) -> Self {
        let consoleBefore = ConsoleIdentity.physicalOwner()
        let before = PhysicalSessionSnapshot.read()
        let verified = before.identity.map { VNCSessionVerify($0.native) == 0 } ?? false
        let session = PhysicalSessionSnapshot.read()
        let console = ConsoleIdentity.physicalOwner()
        return resolve(uid: uid, session: session, console: console,
            observationsStable: before == session && consoleBefore == console, sessionVerified: verified)
    }

    static func resolve(uid: UInt32, session: PhysicalSessionSnapshot, console: ConsoleIdentity?,
                        observationsStable: Bool, sessionVerified: Bool) -> Self {
        func state(_ visibility: Visibility, _ reason: String, canSwitch: Bool = false) -> Self {
            Self(visibility: visibility, canSwitchToLoginWindow: canSwitch,
                 session: session, console: console, reason: reason)
        }
        guard observationsStable else { return state(.unknown, "Session observations changed during the check.") }
        guard let own = session.identity, own.uid == uid, own.auditID > 0, sessionVerified else {
            return state(.unknown, "The worker's session identity could not be verified.")
        }
        guard let console, console.auditID > 0 else { return state(.unknown, "The physical console owner is unavailable.") }
        guard let onConsole = session.onConsole else { return state(.unknown, "This session's console flag is unavailable.") }
        if console == own {
            guard onConsole else { return state(.unknown, "Console ownership and this session's console flag disagree.") }
            let canSwitch = uid != 0
            if session.locked == false {
                return state(.visible, "This session owns the physical console and reports an unlocked screen.", canSwitch: canSwitch)
            }
            return state(.unknown, session.locked == true
                ? "Lock reported; this session still owns the console."
                : "This session owns the console; its screen-lock state is unavailable.", canSwitch: canSwitch)
        }
        guard !onConsole else {
            if console.uid == 0, session.locked == true {
                return state(.unknown, "Loginwindow owns the console device, but this user session is still on console and locked. Off-console desktop access is not established.")
            }
            return state(.unknown, "Another console owner is reported while this session also reports on-console.")
        }
        guard uid != 0, console.uid != uid else { return state(.unknown, "The reported console and worker session identities conflict.") }
        return state(.hidden, console.uid == 0
            ? "Loginwindow owns the console; this user session is confirmed off console."
            : "Another user owns the console; this user session is confirmed off console.")
    }

    var isConfirmedHidden: Bool { visibility == .hidden }

    func canUseConsoleControls(privileged: Bool) -> Bool {
        privileged && isConfirmedHidden
    }

    var description: String {
        switch visibility {
        case .visible: return "Physical display: this desktop is visible"
        case .hidden: return "Physical display: this desktop is hidden"
        case .unknown:
            if session.onConsole == true, session.locked == true {
                return "Physical display: session reports locked on console"
            }
            return "Physical display: visibility unconfirmed"
        }
    }

    var sessionDetails: [String] {
        func identity(_ value: ConsoleIdentity?) -> String {
            guard let value else { return "Unavailable" }
            return "\(value.uid == 0 ? "loginwindow — " : "")UID \(value.uid), audit \(value.auditID)"
        }
        func flag(_ value: Bool?) -> String { value.map { $0 ? "Yes" : "No" } ?? "Unknown" }
        return ["Worker session: \(identity(session.identity))",
                "Console owner session (device): \(identity(console))",
                "Worker session on console: \(flag(session.onConsole))",
                "Worker session lock flag: \(flag(session.locked))",
                reason]
    }
}

/// Never retain a hidden indication across missing/contradictory observations.
/// Two consistent samples at least half a second apart confirm the normal icon.
struct PhysicalDisplayIndicator {
    private var candidate: PhysicalDisplayState?
    private var candidateSince: TimeInterval = 0
    private(set) var showsEye = true

    mutating func invalidate() { candidate = nil; showsEye = true }

    mutating func update(_ state: PhysicalDisplayState, at now: TimeInterval) {
        guard state.isConfirmedHidden, now.isFinite else { invalidate(); return }
        if candidate != state || now < candidateSince {
            candidate = state; candidateSince = now
        }
        showsEye = now - candidateSince < 0.5
    }
}

/// NotificationCenter is thread-safe; tokens are installed once on the main actor.
private final class SessionTransitionObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    private var activityToken: NSObjectProtocol?
    @MainActor init(changed: @escaping @Sendable () -> Void) {
        center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.screensDidWakeNotification, NSWorkspace.screensDidSleepNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in changed() })
        }
        activityToken = NotificationCenter.default.addObserver(
            forName: SessionActivity.didChangeNotification, object: nil, queue: .main) { _ in changed() }
    }
    deinit {
        for token in tokens { center.removeObserver(token) }
        if let activityToken { NotificationCenter.default.removeObserver(activityToken) }
    }
}

enum LoginWindowSwitch {
    static func request(logger: ServerLogger) async throws {
        guard getuid() != 0, let identity = ConsoleIdentity.current(), identity.uid == getuid(),
              VNCSessionVerify(identity.native) == 0 else {
            throw CLIError.commandFailed("This user session no longer owns the physical display.")
        }
        guard let library = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY | RTLD_LOCAL) else {
            throw CLIError.commandFailed("Login-window switching is unavailable on this version of macOS.")
        }
        defer { dlclose(library) }
        // Control Center's Login Window action calls this same entry point
        // from an async dispatch closure on the inspected macOS 27.2.1 host.
        // macOS's Fast User Switching request. This is distinct from
        // SACLockScreenImmediate; never substitute a lock-screen operation.
        // The inspected C entry point takes no arguments and returns OSStatus.
        guard let symbol = dlsym(library, "SACSwitchToLoginWindow") else {
            throw CLIError.commandFailed("Login-window switching is unavailable on this version of macOS.")
        }
        guard ConsoleIdentity.current() == identity else {
            throw CLIError.commandFailed("The physical display changed sessions before the request could be sent.")
        }
        let perform = unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
        let result = perform()
        guard result == 0 else {
            throw CLIError.commandFailed("macOS could not switch to the login window (code \(result)).")
        }
        let started = ProcessInfo.processInfo.systemUptime
        logger.info("Login-window switch requested: source_uid=\(identity.uid) source_audit=\(identity.auditID); waiting for physical console ownership")
        let target = try await waitForCompletion(from: identity)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        logger.info("Physical console switched to loginwindow: audit=\(target.auditID) wait_s=\(String(format: "%.1f", elapsed)); the user VNC session remains running")
    }

    /// SACSwitchToLoginWindow acknowledges creation before the new login UI is
    /// ready. Keep the action pending until graphics-console ownership agrees.
    static func waitForCompletion(
        from identity: ConsoleIdentity,
        timeout: TimeInterval = 60,
        readConsole: () -> ConsoleIdentity? = ConsoleIdentity.current,
        verifySession: (ConsoleIdentity) throws -> Void = { identity in
            guard VNCSessionVerify(identity.native) == 0 else {
                throw CLIError.commandFailed("This user session ended while waiting for loginwindow.")
            }
        },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async throws -> ConsoleIdentity {
        let deadline = now() + timeout
        while true {
            try Task.checkCancellation()
            try verifySession(identity)
            if let console = readConsole(), console.auditID > 0 {
                if console.uid == 0 { return console }
                guard console == identity else {
                    throw CLIError.commandFailed("Another user session took the physical display before loginwindow could be confirmed.")
                }
            }
            guard now() < deadline else {
                throw CLIError.commandFailed("macOS accepted the request, but loginwindow did not take the physical display within \(Int(timeout)) seconds. macOS may still be starting the login screen; your VNC connection remains open.")
            }
            try await pause()
        }
    }
}

@MainActor
final class RemoteSessionStatus: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let displayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailsMenu = NSMenu(title: "Session Details")
    private let connectionsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginWindowItem = NSMenuItem(title: "Switch to Login Window", action: #selector(switchToLoginWindow), keyEquivalent: "")
    private let bringToConsoleItem = NSMenuItem(title: "Bring This Session to Console", action: #selector(bringToConsole), keyEquivalent: "")
    private let viewConsoleItem = NSMenuItem(title: "View Console Session", action: #selector(viewConsole), keyEquivalent: "")
    private let returnToAccountItem = NSMenuItem(title: "Return to Account Session", action: #selector(returnToAccount), keyEquivalent: "")
    private let returnRemoteItem = NSMenuItem(title: "Return Remote Viewers to Their Accounts", action: #selector(returnRemoteViewers), keyEquivalent: "")
    private let showFiles: (() -> Void)?
    private let logger: ServerLogger
    private var timer: Timer?
    private var transitionObservation: SessionTransitionObservation?
    private var indicator = PhysicalDisplayIndicator()
    private var blink = false
    private var switchingToLoginWindow = false
    private var switchingConsole = false
    private var lastDisplayState: PhysicalDisplayState?
    private var lastClientCount = -1
    private var lastEye: Bool?

    init(showFiles: (() -> Void)?, logger: ServerLogger) {
        self.showFiles = showFiles
        self.logger = logger
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(displayItem)
        menu.addItem(connectionsItem)
        let details = NSMenuItem(title: "Session Details", action: nil, keyEquivalent: "")
        details.submenu = detailsMenu
        detailsMenu.autoenablesItems = false
        menu.addItem(details)
        menu.addItem(.separator())
        loginWindowItem.target = self
        menu.addItem(loginWindowItem)
        bringToConsoleItem.target = self
        viewConsoleItem.target = self
        menu.addItem(bringToConsoleItem)
        menu.addItem(viewConsoleItem)
        viewConsoleItem.toolTip = "Keep viewers connected while showing the console. Clipboard and file transfers pause in this view."
        returnToAccountItem.target = self; menu.addItem(returnToAccountItem)
        returnRemoteItem.target = self; menu.addItem(returnRemoteItem)
        let files = NSMenuItem(title: "Received Files…", action: #selector(openFiles), keyEquivalent: "")
        files.target = self; files.isEnabled = showFiles != nil
        menu.autoenablesItems = false
        displayItem.isEnabled = false; connectionsItem.isEnabled = false
        menu.addItem(files)
        item.menu = menu
        item.button?.setAccessibilityLabel("Remote VNC session")
        item.button?.image = RemoteSessionIcon.eyeBright
        transitionObservation = SessionTransitionObservation { [weak self] in
            MainActor.assumeIsolated {
                self?.indicator.invalidate()
                self?.refresh()
            }
        }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }
    @objc private func openFiles() { showFiles?() }

    @objc private func switchToLoginWindow() {
        guard !switchingToLoginWindow, !switchingConsole,
              PhysicalDisplayState.read().canSwitchToLoginWindow else { refresh(); return }
        switchingToLoginWindow = true
        refresh()
        let logger = logger
        Task {
            do {
                // The session agent performs synchronous IPC. Keep that wait
                // off AppKit's event loop so remote input/UI remain responsive.
                try await Task.detached(priority: .userInitiated) { try await LoginWindowSwitch.request(logger: logger) }.value
                switchingToLoginWindow = false
                refresh()
            } catch {
                switchingToLoginWindow = false
                refresh()
                logger.warning("Switch to Login Window failed: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "Couldn’t Switch to Login Window"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc private func bringToConsole() { requestConsoleSwitch(.bringToConsole) }

    @objc private func viewConsole() { requestConsoleSwitch(.viewConsole) }
    @objc private func returnToAccount() { SessionActivity.shared.returnHome(); refresh() }
    @objc private func returnRemoteViewers() { SessionActivity.shared.returnRemoteViewers(); refresh() }

    private var consoleControlsEnabled: Bool {
        !switchingConsole && !switchingToLoginWindow
            && PhysicalDisplayState.read().canUseConsoleControls(privileged: SessionConsoleControl.shared.isAvailable)
    }

    private func requestConsoleSwitch(_ action: ConsoleControlRequest.Action) {
        guard consoleControlsEnabled else { refresh(); return }
        let count = SessionActivity.shared.clientCount
        guard action != .viewConsole || count > 0 else { refresh(); return }
        switchingConsole = true
        refresh()
        let logger = logger
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if let bridge = try SessionConsoleControl.shared.request(action, logger: logger) {
                        try SessionActivity.shared.install(bridge)
                        logger.info("Console view installed; existing viewers remain connected")
                    }
                }.value
                switchingConsole = false
                refresh()
            } catch {
                // Restore actions before entering AppKit's modal event loop.
                // Otherwise the entire error dialog lifetime looks like a
                // console switch that is still running.
                switchingConsole = false
                refresh()
                logger.warning("Console session switch failed: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "Couldn’t Switch Console Sessions"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func refresh() {
        let state = PhysicalDisplayState.read()
        let count = SessionActivity.shared.clientCount
        indicator.update(state, at: ProcessInfo.processInfo.systemUptime)
        let eye = indicator.showsEye
        let confirmingHidden = state.isConfirmedHidden && eye
        // Preserve the physical-visibility warning even with no viewers. Idle
        // workers show a static icon and refresh on notifications/menu opening;
        // a hidden transition still needs its second confirmation sample.
        if count == 0 && !confirmingHidden {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                MainActor.assumeIsolated { self.refresh() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        displayItem.title = confirmingHidden ? "Physical display: confirming hidden session…" : state.description
        let details = ["Worker account: \(NSUserName()) — PID \(getpid()), UID \(getuid())"]
            + state.sessionDetails
            + [confirmingHidden ? "Indicator: awaiting stable hidden-session confirmation"
                : (eye ? "Indicator: red eye — visibility possible or unconfirmed" : "Indicator: normal — hidden session confirmed")]
        if detailsMenu.items.map(\.title) != details {
            detailsMenu.removeAllItems()
            for title in details {
                let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                entry.isEnabled = false
                detailsMenu.addItem(entry)
            }
        }
        connectionsItem.title = "VNC clients connected: \(count)"
        loginWindowItem.title = switchingToLoginWindow ? "Switching to Login Window…" : "Switch to Login Window"
        loginWindowItem.isEnabled = state.canSwitchToLoginWindow && !switchingToLoginWindow && !switchingConsole
        let controls = SessionConsoleControl.shared
        viewConsoleItem.title = switchingConsole ? "Switching Console Sessions…" : "View Console Session"
        bringToConsoleItem.isHidden = !controls.canBringToConsole || !state.isConfirmedHidden
        viewConsoleItem.isHidden = !controls.isAvailable || !state.isConfirmedHidden
        let canSwitch = state.canUseConsoleControls(privileged: controls.isAvailable)
            && !switchingConsole && !switchingToLoginWindow
        bringToConsoleItem.isEnabled = canSwitch && controls.canBringToConsole
        viewConsoleItem.isEnabled = canSwitch && count > 0 && !SessionActivity.shared.isViewingConsole
        returnToAccountItem.isHidden = !SessionActivity.shared.isViewingConsole
        returnToAccountItem.isEnabled = !switchingConsole
        returnRemoteItem.isHidden = SessionActivity.shared.consoleBridgeCount == 0
        returnRemoteItem.isEnabled = !switchingConsole
        if count > 0 { blink.toggle() } else { blink = true }
        item.button?.image = eye
            ? (blink ? RemoteSessionIcon.eyeBright : RemoteSessionIcon.eyeDim)
            : RemoteSessionIcon.remoteDisplay
        item.button?.contentTintColor = nil
        item.button?.toolTip = displayItem.title + "\n" + state.reason
        if state != lastDisplayState || count != lastClientCount || eye != lastEye {
            let icon = eye ? (count > 0 ? "blinking-red-eye" : "red-eye") : "remote-display"
            logger.verbose("VNC menu: \(state.description); clients=\(count) reason=\(state.reason) sessions=\(state.sessionDetails.prefix(4).joined(separator: "; ")) icon=\(icon) visible=\(item.isVisible)")
            lastDisplayState = state
            lastClientCount = count
            lastEye = eye
        }
    }
}
