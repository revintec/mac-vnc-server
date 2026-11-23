import CVNCSession
import Darwin
import Foundation

enum AccountSessionWorker {
    static func run(_ options: SessionWorkerOptions, transferInbox: TransferInbox?) async throws {
        try options.verifyAttachment()
        let channel = try SessionChannel(fd: dup(STDIN_FILENO))
        let config = options.config
        let logger = ServerLogger(verbose: config.verbose)
        logger.verbose("Session worker attached: uid=\(options.identity.uid) audit=\(options.identity.auditID) pid=\(getpid())")
        if options.identity.uid != 0 {
            let session = PhysicalSessionSnapshot.read()
            if session.identity == options.identity, session.onConsole == true, session.locked == true {
                logger.warning("Selected user session is still locked on console; VNC may show loginwindow in that same session. Account authentication has not moved this desktop off console or unlocked it.")
            }
        }
        var desktop: AccountSessionDesktop?
        do {
            try await withTaskCancellationHandler {
                try channel.ready()
                if options.consoleControls == true {
                    SessionConsoleControl.shared.attach(channel, canBringToConsole: options.canBringToConsole == true)
                }
                defer { SessionConsoleControl.shared.attach(nil) }
                while !Task.isCancelled {
                    try desktop?.rootInput?.checkDelivery()
                    if let desktop, desktop.server.consoleBridgeCount > 0,
                       ConsoleIdentity.current() != options.identity { desktop.server.disconnectConsoleBridges() }
                    // A locked/background user session remains alive. A logout,
                    // replacement audit session, or root console change does not.
                    guard (try? AccountAuthentication.session(uid: options.identity.uid)) == options.identity else { break }
                    if let (client, admission) = try channel.receive() {
                        try admission.validate(for: options.identity)
                        if admission.consoleBridge == true, ConsoleIdentity.current() != options.identity {
                            try? ConsoleFramebufferBridge.rejectStartup(socket: client,
                                error: CLIError.commandFailed("The console owner changed before capture started. Try again."))
                            client.shutdown(); continue
                        }
                        guard VNCSessionVerify(options.identity.native) == 0 else {
                            try? AccountHandshake.reject(socket: client, version: admission.version)
                            break
                        }
                        if desktop == nil {
                            do {
                                desktop = try await AccountSessionDesktop(options: options,
                                    transferInbox: transferInbox, logger: logger)
                            } catch {
                                guard admission.consoleBridge == true else { throw error }
                                logger.warning("Console desktop startup failed: uid=\(options.identity.uid) audit=\(options.identity.auditID): \(CLI.errorMessage(for: error))")
                                try? ConsoleFramebufferBridge.rejectStartup(socket: client, error: error)
                                client.shutdown()
                                // Retire the failed target so a retry gets fresh
                                // framework connections and capture service state.
                                // The originating viewer and worker remain alive.
                                throw error
                            }
                            SessionActivity.shared.attach(desktop?.server, router: desktop?.router)
                        }
                        try Task.checkCancellation()
                        _ = desktop?.server.serve(client: client, admission: admission)
                    }
                    // Admission and retirement run on this one task. A reconnect
                    // waits in the channel until the former capture has stopped;
                    // it can never race shutdown or use a stale desktop frame.
                    if let idle = desktop, idle.server.activeClientCount == 0 {
                        await idle.stop()
                        desktop = nil
                        SessionActivity.shared.attach(nil)
                        logger.verbose("Session worker idle: capture and cursor sampling released")
                    }
                }
            } onCancel: { channel.shutdown() }
        } catch {
            channel.shutdown()
            await desktop?.stop()
            SessionActivity.shared.attach(nil)
            throw error
        }
        channel.shutdown()
        await desktop?.stop()
        SessionActivity.shared.attach(nil)
    }
}

/// Only the account worker persists between viewers. Releasing this desktop
/// also releases its frame store, stream outputs, cursor task and observers.
private final class AccountSessionDesktop {
    let capture: any SessionScreenCapture
    let rootInput: ConsoleRootInput?
    let router: SessionDesktopRouter
    let server: RFBServer

    init(options: SessionWorkerOptions, transferInbox: TransferInbox?, logger: ServerLogger) async throws {
        let config = options.config
        switch SessionCaptureBackend.select(uid: options.identity.uid) {
        case .coreGraphics:
            capture = try await CoreGraphicsConsoleCapture(scale: config.scale, fps: config.fps,
                displaySelection: config.displaySelection, identity: options.identity,
                logger: logger, cursorMode: config.cursorMode)
        case .screenCaptureKit:
            capture = try await StreamingScreenCapture(scale: config.scale, fps: config.fps,
                displaySelection: config.displaySelection,
                logger: logger, cursorMode: config.cursorMode,
                consoleIdentity: options.identity.uid == 0 ? options.identity : nil)
        }
        do { rootInput = options.identity.uid == 0 ? try ConsoleRootInput(identity: options.identity) : nil }
        catch { await capture.stop(); throw error }
        let inputs: SharedInputController
        if let rootInput {
            inputs = SharedInputController(input: MacInputController(logger: ServerLogger(verbose: false),
                postEvent: { _, event in rootInput.post(event) }))
        } else { inputs = SharedInputController(input: MacInputController(logger: logger)) }
        let makeClipboard: @Sendable () -> ClipboardBridge = {
            options.identity.uid == 0 ? DisabledClipboard() : MacClipboard()
        }
        let router = SessionDesktopRouter(capture: capture, makeInput: { inputs.makeClient() }, makeClipboard: makeClipboard)
        self.router = router
        server = RFBServer(config: config, capture: router, makeInput: { router.makeInput() },
            makeClipboard: { router.makeClipboard() }, logger: logger, transferInbox: transferInbox,
            onClientCountChange: { SessionActivity.shared.changed() })
    }

    func stop() async {
        router.stop()
        server.stop(); server.waitForClients()
        await capture.stop()
    }
}

final class SessionActivity: @unchecked Sendable {
    static let shared = SessionActivity()
    static let didChangeNotification = Notification.Name("mac-vnc-server.session-activity-changed")
    private let lock = NSLock()
    private weak var server: RFBServer?
    private weak var router: SessionDesktopRouter?
    private var notificationPending = false
    func attach(_ server: RFBServer?, router: SessionDesktopRouter? = nil) {
        lock.withLock { self.server = server; self.router = router }
        changed()
    }
    func changed() {
        let enqueue = lock.withLock {
            guard !notificationPending else { return false }
            notificationPending = true
            return true
        }
        guard enqueue else { return }
        // Status refresh queries WindowServer. Never make admission, client
        // cleanup or capture retirement wait for AppKit's event loop.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.notificationPending = false }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
    var clientCount: Int { lock.withLock { server?.activeClientCount ?? 0 } }
    var isViewingConsole: Bool { lock.withLock { router }?.isRemote ?? false }
    var consoleBridgeCount: Int { lock.withLock { server }?.consoleBridgeCount ?? 0 }
    func install(_ bridge: ConsoleFramebufferBridge) throws {
        guard let router = lock.withLock({ router }) else { bridge.stop(); throw CancellationError() }
        do { try router.install(bridge) } catch { bridge.stop(); throw error }
    }
    func returnHome() { lock.withLock { router }?.returnHome() }
    func returnRemoteViewers() { lock.withLock { server }?.disconnectConsoleBridges() }
}
