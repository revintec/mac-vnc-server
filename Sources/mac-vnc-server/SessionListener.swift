import Darwin
import Foundation

protocol SessionWorkerConnection: AnyObject, Sendable {
    var isRunning: Bool { get }
    func send(client: ClientSocket, admission: SessionAdmission) throws
    func stop()
}

/// One worker per UID + audit session on this listening endpoint. Creation and
/// retirement share the admission lock, so simultaneous logins cannot fork two
/// owners of the same desktop. Workers are retained until logout or shutdown.
final class SessionWorkerPool: @unchecked Sendable {
    private let lock = NSLock()
    private var workers: [ConsoleIdentity: any SessionWorkerConnection] = [:]
    private var stopped = false
    private let create: @Sendable (ConsoleIdentity) throws -> any SessionWorkerConnection

    init(create: @escaping @Sendable (ConsoleIdentity) throws -> any SessionWorkerConnection) { self.create = create }

    func handOff(client: ClientSocket, admission: SessionAdmission) throws {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            // Retire an old login generation before its replacement starts,
            // including release of the old loginwindow capture service.
            for (identity, old) in workers where identity.uid == admission.identity.uid && identity != admission.identity {
                old.stop(); workers[identity] = nil
            }
            if let previous = workers[admission.identity], !previous.isRunning {
                previous.stop(); workers[admission.identity] = nil
            }
            let worker: any SessionWorkerConnection
            if let existing = workers[admission.identity] { worker = existing }
            else {
                guard workers.count < 32 else { throw RFBError.protocolError("session worker limit reached") }
                worker = try create(admission.identity)
                workers[admission.identity] = worker
            }
            do { try worker.send(client: client, admission: admission) }
            catch {
                // A descriptor may have arrived before a metadata write failed.
                // Retire the stream instead of reusing a partial admission.
                worker.stop(); workers[admission.identity] = nil
                throw error
            }
        }
    }

    func reap() {
        // The accept loop must not wait behind a worker's capture/permission
        // startup. Admission threads wait for readiness independently.
        guard lock.try() else { return }
        defer { lock.unlock() }
        for (identity, worker) in workers where !worker.isRunning {
            worker.stop(); workers[identity] = nil
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            for worker in workers.values { worker.stop() }
            workers.removeAll()
        }
    }
}

final class SessionListener: @unchecked Sendable {
    let config: ServerConfig
    private let logger: ServerLogger
    private let pool: SessionWorkerPool
    private let lock = NSLock()
    private var stopped = false
    private var pending: [ObjectIdentifier: ClientSocket] = [:]
    private let authentications = DispatchGroup()
    private let verify: @Sendable (String, String) throws -> ConsoleIdentity

    init(config: ServerConfig, pool: SessionWorkerPool? = nil,
         verify: @escaping @Sendable (String, String) throws -> ConsoleIdentity = AccountAuthentication.verify) {
        self.config = config
        logger = ServerLogger(verbose: config.verbose)
        self.verify = verify
        self.pool = pool ?? SessionWorkerPool { identity in try AccountSessionChild(identity: identity, config: config) }
    }

    func run(listener supplied: ListeningSocket? = nil) throws {
        let access = try AccountListenerAccess.resolve()
        guard config.password == nil, !config.passwordFromEnvironment else {
            throw CLIError.invalidArgument("account listeners do not accept a shared password")
        }
        switch access {
        case .allAccounts:
            logger.info("Account listener privileges: root; ordinary accounts select their user sessions; root selects the current console owner (loginwindow or user desktop)")
        case .ownAccount(let uid):
            logger.warning("Account listener is running without root (uid=\(uid)); only its own existing user session is available. Other accounts and root/console access require starting the listener with sudo")
        }
        let listener = try supplied ?? ListeningSocket(bindAddress: config.bindAddress, port: config.port)
        if access == .allAccounts {
            do { try ConsoleCaptureService.recoverOrphans() }
            catch { logger.warning(error.localizedDescription) }
        }
        logger.info("mac-vnc-server \(AppVersion.current) account listener pid=\(getpid()) uid=\(geteuid())")
        logger.info("Listening on \(listener.bindAddress):\(config.port); macOS username/password; VNC_PASSWORD is not used")
        logger.info("One worker per account session; workers own client sockets and all desktop traffic")
        if !config.allowEncryption {
            logger.info("Session-record encryption disabled; Apple account input uses the authentication key for keyboard/mouse messages")
        }
        logger.info("Connect with vnc://\(listener.bindAddress):\(config.port)/")
        defer { stop(); authentications.wait(); pool.stop() }
        var nextReap = ContinuousClock.now
        while !lock.withLock({ stopped }) {
            if ContinuousClock.now >= nextReap { pool.reap(); nextReap = .now + .seconds(1) }
            guard let client = try listener.acceptClient(timeout: 0.25) else { continue }
            let id = ObjectIdentifier(client)
            let allowed = lock.withLock {
                guard !stopped, pending.count < 16 else { return false }
                pending[id] = client
                return true
            }
            guard allowed else { client.shutdown(); continue }
            authentications.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { _ = lock.withLock { pending.removeValue(forKey: id) }; authentications.leave() }
                do {
                    try client.configureTCP()
                    let admission = try AccountHandshake.authenticate(socket: client, verify: verify)
                    do {
                        try pool.handOff(client: client, admission: admission)
                        logger.info("Client handed to session uid=\(admission.identity.uid) audit=\(admission.identity.auditID)")
                        // Drop our reference/descriptor without shutdown(2): that
                        // would also tear down the worker's copy of the socket.
                    } catch {
                        try? AccountHandshake.reject(socket: client, version: admission.version, error: error)
                        throw error
                    }
                } catch {
                    client.shutdown()
                    logger.warning("account connection ended: \(error.localizedDescription)")
                    // Bound password attempts as well as concurrent handshakes.
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            for client in pending.values { client.shutdown() }
        }
        // Pool teardown belongs to run's defer, outside a cancellation callback.
    }
}

private final class AccountSessionChild: SessionWorkerConnection, @unchecked Sendable {
    private let process: Process
    private let channel: SessionChannel
    private let service: ConsoleCaptureService?
    private let token: UUID
    private var didStop = false

    var isRunning: Bool { process.isRunning }

    init(identity: ConsoleIdentity, config: ServerConfig) throws {
        let session = try AccountAuthentication.session(uid: identity.uid)
        guard session == identity else { throw RFBError.authenticationFailed }
        let service = identity.uid == 0 ? try ConsoleCaptureService(identity: identity) : nil
        do {
            let (channel, childInput) = try SessionChannel.pair()
            defer { try? childInput.close() }
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
            var workerConfig = config
            workerConfig.sessionTarget = identity.uid == 0 ? .console : .user
            if identity.uid == 0 { workerConfig.clipboardSync = false; workerConfig.fileTransfer = false; workerConfig.cursorMode = .embedded }
            let options = SessionWorkerOptions(identity: identity, config: workerConfig)
            try options.validate()
            let encoded = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
            let process = Process()
            if geteuid() == 0 {
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["asuser", String(identity.uid), executable.path, "--session-worker", encoded]
            } else {
                guard identity.uid == getuid() else { throw RFBError.authenticationFailed }
                process.executableURL = executable
                process.arguments = ["--session-worker", encoded]
            }
            // No credentials, loader variables, or terminal secrets inherited.
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            process.standardInput = childInput
            process.standardOutput = FileHandle.standardError
            process.standardError = FileHandle.standardError
            try process.run()
            let token = ProcessShutdown.shared.register(process)
            try? childInput.close()
            do { try channel.waitUntilReady() }
            catch {
                channel.shutdown()
                Self.terminate(process)
                ProcessShutdown.shared.unregister(token)
                throw error
            }
            self.process = process; self.channel = channel; self.service = service; self.token = token
            ServerLogger(verbose: config.verbose).info("Session worker ready: uid=\(identity.uid) audit=\(identity.auditID) pid=\(process.processIdentifier)")
        } catch { service?.stop(); throw error }
    }

    func send(client: ClientSocket, admission: SessionAdmission) throws {
        guard isRunning else { throw RFBError.socketError("session worker exited") }
        try channel.send(client: client, admission: admission)
    }

    func stop() {
        guard !didStop else { return }
        didStop = true
        channel.shutdown()
        Self.terminate(process)
        ProcessShutdown.shared.unregister(token)
        service?.stop()
    }

    private static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning, ContinuousClock.now < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
