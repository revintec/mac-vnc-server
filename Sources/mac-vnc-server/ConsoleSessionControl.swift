import CVNCSession
import Darwin
import Foundation

struct ConsoleControlRequest: Codable, Sendable {
    enum Action: String, Codable, Sendable { case bringToConsole, viewConsole }
    let action: Action
}

private struct ConsoleControlReply: Codable {
    let error: String?
    var identity: ConsoleIdentity? = nil
}

/// Weak indirection avoids a pool/worker/control-service ownership cycle.
final class ConsoleDesktopBroker: @unchecked Sendable {
    weak var pool: SessionWorkerPool?
    func connect(to identity: ConsoleIdentity) throws -> ClientSocket {
        guard let pool else { throw CancellationError() }
        let (viewer, worker) = try ClientSocket.localPair()
        var admission = SessionAdmission(identity: identity, version: "RFB 003.008\n", wrappingKey: [UInt8](repeating: 0, count: 16))
        admission.consoleBridge = true
        try pool.handOff(client: worker, admission: admission)
        return viewer
    }
}

/// Requests have no caller-selected UID/audit/graphics ID. The listener binds
/// every operation to the identity of the child it launched on this socket.
final class ConsoleControlService: @unchecked Sendable {
    private let channel: SessionChannel
    private let identity: ConsoleIdentity
    private let broker: ConsoleDesktopBroker
    private let logger: ServerLogger
    private let lock = NSLock()
    private var stopping = false

    init(channel: SessionChannel, identity: ConsoleIdentity, broker: ConsoleDesktopBroker, logger: ServerLogger) {
        self.channel = channel; self.identity = identity; self.broker = broker; self.logger = logger
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                while true {
                    guard let (reply, request) = try channel.receiveControl() else { continue }
                    defer { reply.shutdown() }
                    let endpoint: (ClientSocket, ConsoleIdentity)?
                    do { endpoint = try handle(request) }
                    catch {
                        let bytes = Array(try JSONEncoder().encode(ConsoleControlReply(error: error.localizedDescription)))
                        try? reply.writeAll(UInt32(bytes.count).beBytes + bytes)
                        continue
                    }
                    do {
                        let bytes = Array(try JSONEncoder().encode(ConsoleControlReply(error: nil, identity: endpoint?.1)))
                        try reply.writeAll(UInt32(bytes.count).beBytes + bytes)
                        if let (client, target) = endpoint {
                            let transport = try SessionChannel(fd: dup(reply.fd))
                            try transport.send(client: client, admission: SessionAdmission(identity: target,
                                version: "RFB 003.008\n", wrappingKey: [UInt8](repeating: 0, count: 16)))
                        }
                    } catch {
                        // A partial success reply cannot be followed by a new
                        // JSON reply: the peer is already expecting a descriptor.
                        logger.verbose("Console-control reply failed: \(error.localizedDescription)")
                    }
                }
            } catch is CancellationError {
                // Listener/worker teardown closes the inherited channel.
            } catch {
                logger.verbose("Session console-control channel ended: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        lock.withLock { stopping = true }
        channel.shutdown()
        // The handler may be waiting to enter the worker pool. Never join it
        // while pool teardown holds its admission lock; shutdown wakes its I/O.
    }

    private func handle(_ request: ConsoleControlRequest) throws -> (ClientSocket, ConsoleIdentity)? {
        guard getuid() == 0, geteuid() == 0, identity.uid != 0,
              !lock.withLock({ stopping }),
              try AccountAuthentication.session(uid: identity.uid) == identity,
              let console = ConsoleIdentity.current(), console != identity else {
            throw CLIError.commandFailed("Console controls require a root listener and a verified off-console user session.")
        }
        switch request.action {
        case .bringToConsole:
            let result = VNCSessionSwitchToConsole(identity.native)
            guard result == 0 else {
                throw CLIError.commandFailed("macOS could not bring this desktop to the console (code \(result)).")
            }
            // The private API can acknowledge before switching, including when
            // macOS refuses a request. Success must mean verified ownership.
            let deadline = ContinuousClock.now + .seconds(10)
            while ConsoleIdentity.current() != identity {
                if lock.withLock({ stopping }) { throw CancellationError() }
                guard ContinuousClock.now < deadline else {
                    throw CLIError.commandFailed("macOS did not confirm the console switch. This desktop may still require sign-in at the Mac.")
                }
                usleep(100_000)
            }
            logger.info("Brought session uid=\(identity.uid) audit=\(identity.auditID) to the physical console")
            return nil
        case .viewConsole:
            let client = try broker.connect(to: console)
            guard ConsoleIdentity.current() == console else {
                client.shutdown()
                throw CLIError.commandFailed("The physical console changed during the switch. Try again.")
            }
            return (client, console)
        }
    }
}

/// AppKit and the account loop share the same writer so control messages cannot
/// interleave. Each reply has a private socket; admissions retain their reader.
final class SessionConsoleControl: @unchecked Sendable {
    static let shared = SessionConsoleControl()
    private let lock = NSLock()
    private var channel: SessionChannel?
    private var bringAvailable = false

    func attach(_ channel: SessionChannel?, canBringToConsole: Bool = false) {
        lock.withLock { self.channel = channel; bringAvailable = canBringToConsole }
        SessionActivity.shared.changed()
    }
    var isAvailable: Bool { lock.withLock { channel != nil } }
    var canBringToConsole: Bool { lock.withLock { channel != nil && bringAvailable } }

    func request(_ action: ConsoleControlRequest.Action) throws -> ConsoleFramebufferBridge? {
        guard let channel = lock.withLock({ channel }) else {
            throw CLIError.commandFailed("Console controls are unavailable. Start the server with sudo.")
        }
        let (response, inherited) = try SessionChannel.pair()
        let reply = try ClientSocket(fd: dup(inherited.fileDescriptor))
        try inherited.close()
        defer { response.shutdown(); reply.shutdown() }
        try channel.sendControl(reply: reply, request: .init(action: action))
        let result = try response.socket.withReadTimeout(60, operation: "console session switch") {
            let h = try response.socket.readExact(4)
            let length = Int(UInt32.be(h[0], h[1], h[2], h[3]))
            guard (1...4096).contains(length) else { throw RFBError.protocolError("invalid console-control reply") }
            return try JSONDecoder().decode(ConsoleControlReply.self, from: Data(response.socket.readExact(length)))
        }
        if let error = result.error { throw CLIError.commandFailed(error) }
        guard action == .viewConsole else { return nil }
        guard let identity = result.identity, let (client, admission) = try response.receive(timeout: 5),
              identity == admission.identity else { throw RFBError.protocolError("missing console desktop connection") }
        return try ConsoleFramebufferBridge(socket: client, identity: identity)
    }
}
