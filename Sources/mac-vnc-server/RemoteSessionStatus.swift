import AppKit
import CoreGraphics
import CVNCSession
import Darwin
import Foundation

struct PhysicalDisplayState: Equatable {
    enum Visibility: Equatable { case visible, locked, otherUser, unknown }
    let visibility: Visibility
    let canSwitchToLoginWindow: Bool

    static func read(uid: UInt32 = getuid()) -> Self {
        let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = dictionary?["CGSSessionScreenIsLocked"] as? Bool == true
        return resolve(uid: uid, console: ConsoleIdentity.current(), locked: locked)
    }

    static func resolve(uid: UInt32, console: ConsoleIdentity?, locked: Bool) -> Self {
        guard let console else { return Self(visibility: .unknown, canSwitchToLoginWindow: false) }
        let ownsConsole = uid != 0 && console.uid == uid
        if console.uid == 0 || (console.uid == uid && locked) {
            return Self(visibility: .locked, canSwitchToLoginWindow: ownsConsole)
        }
        return Self(visibility: console.uid == uid ? .visible : .otherUser, canSwitchToLoginWindow: ownsConsole)
    }

    var description: String {
        switch visibility {
        case .visible: return "Physical display: unlocked — this desktop is visible"
        case .locked: return "Physical display: locked / login window"
        case .otherUser: return "Physical display: another user — this desktop is hidden"
        case .unknown: return "Physical display: state unavailable"
        }
    }

    func showsEye(clientCount: Int) -> Bool { visibility == .visible && clientCount > 0 }
}

enum LoginWindowSwitch {
    static func request() throws {
        guard getuid() != 0, let identity = ConsoleIdentity.current(), identity.uid == getuid(),
              VNCSessionVerify(identity.native) == 0 else {
            throw CLIError.commandFailed("This user session no longer owns the physical display.")
        }
        guard let library = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY | RTLD_LOCAL) else {
            throw CLIError.commandFailed("Login-window switching is unavailable on this version of macOS.")
        }
        defer { dlclose(library) }
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
    }
}

@MainActor
final class RemoteSessionStatus: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let displayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let connectionsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginWindowItem = NSMenuItem(title: "Switch to Login Window", action: #selector(switchToLoginWindow), keyEquivalent: "")
    private let showFiles: (() -> Void)?
    private let logger: ServerLogger
    private var timer: Timer?
    private var blink = false
    private var switchingToLoginWindow = false
    private var lastDisplayState: PhysicalDisplayState?
    private var lastClientCount = -1

    init(showFiles: (() -> Void)?, logger: ServerLogger) {
        self.showFiles = showFiles
        self.logger = logger
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(displayItem)
        menu.addItem(connectionsItem)
        menu.addItem(.separator())
        loginWindowItem.target = self
        menu.addItem(loginWindowItem)
        let files = NSMenuItem(title: "Received Files…", action: #selector(openFiles), keyEquivalent: "")
        files.target = self; files.isEnabled = showFiles != nil
        menu.autoenablesItems = false
        displayItem.isEnabled = false; connectionsItem.isEnabled = false
        menu.addItem(files)
        item.menu = menu
        item.button?.setAccessibilityLabel("Remote VNC session")
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }
    @objc private func openFiles() { showFiles?() }

    @objc private func switchToLoginWindow() {
        guard !switchingToLoginWindow, PhysicalDisplayState.read().canSwitchToLoginWindow else { refresh(); return }
        switchingToLoginWindow = true
        refresh()
        Task {
            defer { switchingToLoginWindow = false; refresh() }
            do {
                // The session agent performs synchronous IPC. Keep that wait
                // off AppKit's event loop so remote input/UI remain responsive.
                try await Task.detached(priority: .userInitiated) { try LoginWindowSwitch.request() }.value
                logger.info("Requested Fast User Switching to loginwindow; the user VNC session remains running")
            } catch {
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

    private func refresh() {
        let state = PhysicalDisplayState.read()
        let count = SessionActivity.shared.clientCount
        displayItem.title = state.description
        connectionsItem.title = "VNC clients connected: \(count)"
        loginWindowItem.title = switchingToLoginWindow ? "Switching to Login Window…" : "Switch to Login Window"
        loginWindowItem.isEnabled = state.canSwitchToLoginWindow && !switchingToLoginWindow
        let eye = state.showsEye(clientCount: count)
        blink.toggle()
        item.button?.image = eye
            ? (blink ? RemoteSessionIcon.eyeBright : RemoteSessionIcon.eyeDim)
            : RemoteSessionIcon.remoteDisplay
        item.button?.contentTintColor = nil
        item.button?.toolTip = state.description
        if state != lastDisplayState || count != lastClientCount {
            logger.verbose("VNC menu: \(state.description); clients=\(count) icon=\(eye ? "blinking-red-eye" : "remote-display") visible=\(item.isVisible)")
            lastDisplayState = state
            lastClientCount = count
        }
    }
}
