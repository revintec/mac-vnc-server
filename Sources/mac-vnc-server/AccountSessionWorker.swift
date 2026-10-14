import CVNCSession
import Darwin
import Foundation

enum AccountSessionWorker {
    static func run(_ options: SessionWorkerOptions, transferInbox: TransferInbox?) async throws {
        try options.verifyAttachment()
        let channel = try SessionChannel(fd: dup(STDIN_FILENO))
        let config = options.config
        let logger = ServerLogger(verbose: config.verbose)
        let capture: any FramebufferSource & Sendable
        let userCapture: StreamingScreenCapture?
        let rootCapture: ConsoleDisplayCapture?
        let rootInput: ConsoleRootInput?
        if options.identity.uid == 0 {
            let source = try ConsoleDisplayCapture(scale: config.scale, fps: config.fps,
                displaySelection: config.displaySelection, logger: logger)
            do { try await source.waitUntilReady() }
            catch { source.stop(); throw error }
            rootCapture = source; userCapture = nil; capture = source
            do { rootInput = try ConsoleRootInput(identity: options.identity) }
            catch { source.stop(); throw error }
        } else {
            let source = try await StreamingScreenCapture(scale: config.scale, fps: config.fps,
                displaySelection: config.displaySelection == .automatic ? .all : config.displaySelection,
                logger: logger, cursorMode: config.cursorMode)
            userCapture = source; rootCapture = nil; capture = source; rootInput = nil
        }
        let inputs: SharedInputController
        if let rootInput {
            inputs = SharedInputController(input: MacInputController(logger: ServerLogger(verbose: false),
                postEvent: { _, event in rootInput.post(event) }))
        } else { inputs = SharedInputController(input: MacInputController(logger: logger)) }
        let server = RFBServer(config: config, capture: capture, makeInput: { inputs.makeClient() },
            makeClipboard: {
                if options.identity.uid == 0 { return ConsoleClipboard() }
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
            rootCapture?.stop()
            await userCapture?.stop()
            throw error
        }
        server.stop(); server.waitForClients(); channel.shutdown()
        rootCapture?.stop()
        await userCapture?.stop()
    }
}

final class SessionActivity: @unchecked Sendable {
    static let shared = SessionActivity()
    private let lock = NSLock()
    private weak var server: RFBServer?
    func attach(_ server: RFBServer) { lock.withLock { self.server = server } }
    var clientCount: Int { lock.withLock { server?.activeClientCount ?? 0 } }
}
