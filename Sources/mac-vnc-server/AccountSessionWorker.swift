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
        // Both identities use the same capture, cursor and delivery pipeline.
        // The listener has already installed loginwindow's capture service in
        // user/0; the attached worker must never fall back to another desktop.
        let capture = try await StreamingScreenCapture(scale: config.scale, fps: config.fps,
            displaySelection: config.displaySelection,
            logger: logger, cursorMode: config.cursorMode,
            consoleIdentity: options.identity.uid == 0 ? options.identity : nil)
        let rootInput: ConsoleRootInput?
        do { rootInput = options.identity.uid == 0 ? try ConsoleRootInput(identity: options.identity) : nil }
        catch { await capture.stop(); throw error }
        let inputs: SharedInputController
        if let rootInput {
            inputs = SharedInputController(input: MacInputController(logger: ServerLogger(verbose: false),
                postEvent: { _, event in rootInput.post(event) }))
        } else { inputs = SharedInputController(input: MacInputController(logger: logger)) }
        let server = RFBServer(config: config, capture: capture, makeInput: { inputs.makeClient() },
            makeClipboard: {
                if options.identity.uid == 0 { return DisabledClipboard() }
                return MacClipboard()
            },
            logger: logger, transferInbox: transferInbox)
        SessionActivity.shared.attach(server)
        do {
            try await withTaskCancellationHandler {
                try channel.ready()
                while !Task.isCancelled {
                    try rootInput?.checkDelivery()
                    // A locked/background user session remains alive. A logout,
                    // replacement audit session, or root console change does not.
                    guard (try? AccountAuthentication.session(uid: options.identity.uid)) == options.identity else { break }
                    if let (client, admission) = try channel.receive() {
                        try admission.validate(for: options.identity)
                        guard VNCSessionVerify(options.identity.native) == 0 else {
                            try? AccountHandshake.reject(socket: client, version: admission.version)
                            break
                        }
                        _ = server.serve(client: client, admission: admission)
                    }
                }
            } onCancel: { channel.shutdown(); server.stop() }
        } catch {
            server.stop(); server.waitForClients(); channel.shutdown()
            await capture.stop()
            throw error
        }
        server.stop(); server.waitForClients(); channel.shutdown()
        await capture.stop()
    }
}

final class SessionActivity: @unchecked Sendable {
    static let shared = SessionActivity()
    private let lock = NSLock()
    private weak var server: RFBServer?
    func attach(_ server: RFBServer) { lock.withLock { self.server = server } }
    var clientCount: Int { lock.withLock { server?.activeClientCount ?? 0 } }
}
