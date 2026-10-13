import Darwin
import Foundation

enum ConsoleSessionServer {
    static func run(config: ServerConfig) async throws {
        guard geteuid() == 0 else {
            throw CLIError.commandFailed("--session console requires sudo; the default user session does not")
        }
        guard config.password != nil, !config.clipboardSync, !config.fileTransfer else {
            throw CLIError.commandFailed("console mode requires authentication and isolated display/input only")
        }
        let logger = ServerLogger(verbose: config.verbose)
        // Detect an older endpoint before a capture retry loop obscures the
        // port conflict. Do not accept connections until a frame is available.
        let listener: ListeningSocket
        do {
            listener = try ListeningSocket(bindAddress: config.bindAddress, port: config.port, startListening: false)
        } catch {
            throw RFBError.socketError("console endpoint cannot bind: \(error.localizedDescription). Stop the existing process on this port before retrying; rebuilding does not replace a running server")
        }
        logger.info("Console supervisor: pid=\(getpid()) capture=CoreGraphics-display-stream root_capture=isolated-replayd")
        let desktop = ConsoleDesktop(fps: config.fps)
        let supervisor = ConsoleSupervisor(config: config, desktop: desktop, logger: logger)
        let task = Task.detached { await supervisor.run() }
        do {
            let deadline = ContinuousClock.now + .seconds(45)
            while !desktop.hasReadyFrame {
                guard ContinuousClock.now < deadline else {
                    throw RFBError.captureFailed("console worker did not deliver a verified frame within 45 seconds; see worker diagnostics")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try listener.startListening()
            logger.info("session=console: isolated workers; clipboard/file transfer remain on the user endpoint")
            let server = RFBServer(config: config, capture: desktop, makeInput: { desktop.makeInput() },
                makeClipboard: { ConsoleClipboard() }, logger: logger)
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try server.run(listener: listener)
            } onCancel: { server.stop() }
        } catch {
            task.cancel(); desktop.invalidate()
            await task.value
            throw error
        }
        task.cancel(); desktop.invalidate()
        await task.value
    }
}

private final class ConsoleChild: @unchecked Sendable {
    let process: Process
    let transport: ConsoleTransport
    private let shutdownToken: UUID
    init(options: ConsoleWorkerOptions) throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw RFBError.socketError("could not create console worker socket pair")
        }
        for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let childInput = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        transport = try ConsoleTransport(fd: pair[0])
        process = Process()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let encoded = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        // Root must also use its own bootstrap: inherited user bootstrap sends
        // CGDisplayStream's SCK proxy to that user's replayd, not loginwindow.
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["asuser", String(options.identity.uid), executable.path, "--console-worker", encoded]
        // Workers have neither network credentials nor the caller's arbitrary
        // environment. Attach fills in the chosen account's HOME/USER/LOGNAME.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = childInput
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        shutdownToken = ProcessShutdown.shared.register(process)
        try? childInput.close()
    }

    func stop() {
        defer { ProcessShutdown.shared.unregister(shutdownToken) }
        transport.shutdown()
        if process.isRunning { process.terminate() }
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning, ContinuousClock.now < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

private final class ConsoleSupervisor: @unchecked Sendable {
    let config: ServerConfig
    let desktop: ConsoleDesktop
    let logger: ServerLogger
    init(config: ServerConfig, desktop: ConsoleDesktop, logger: ServerLogger) {
        self.config = config; self.desktop = desktop; self.logger = logger
    }

    func run() async {
        var reportedMissing = false
        var retry = ConsoleWorkerRetryPolicy()
        while !Task.isCancelled {
            guard let identity = ConsoleIdentity.current() else {
                retry.reset()
                if !reportedMissing { logger.warning("console session is not yet available; input paused"); reportedMissing = true }
                desktop.invalidate()
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            reportedMissing = false
            var stable = false
            do {
                let broker = identity.uid == 0 ? try ConsoleCaptureBroker(identity: identity) : nil
                defer { broker?.stop() }
                let display: Int
                if case .display(let index) = config.displaySelection { display = index } else { display = 0 }
                let child = try ConsoleChild(options: ConsoleWorkerOptions(identity: identity,
                    fps: config.fps, scale: config.scale, display: display, verbose: config.verbose))
                let token = desktop.begin(identity, transport: child.transport)
                logger.info("Console worker started: uid=\(identity.uid) audit=\(identity.auditID) pid=\(child.process.processIdentifier)")
                let reader = Task.detached { [desktop, logger] in
                    do {
                        var first = true
                        frames: while !Task.isCancelled {
                            let (message, pixels) = try child.transport.receive(timeout: first ? 35 : 10)
                            switch message.kind {
                            case .frame:
                                guard let info = message.frame else { throw RFBError.protocolError("missing console frame") }
                                guard try desktop.publish(info, pixels: pixels, generation: token) else { break frames }
                                if first {
                                    first = false
                                    desktop.sendRate()
                                    logger.info("Console worker ready: uid=\(identity.uid) audit=\(identity.auditID) frame=\(info.width)x\(info.height)")
                                }
                            case .heartbeat: break
                            default: throw RFBError.protocolError("unexpected console worker response")
                            }
                        }
                    } catch {
                        if desktop.isActive(token), ConsoleIdentity.current() == identity {
                            logger.warning("console worker unavailable: \(error.localizedDescription)")
                        }
                    }
                    desktop.invalidate(generation: token)
                }
                var heartbeat = ContinuousClock.now
                var readySince: ContinuousClock.Instant?
                while !Task.isCancelled, child.process.isRunning, desktop.isActive(token), ConsoleIdentity.current() == identity {
                    if let broker, !broker.isRunning {
                        logger.warning("console capture broker exited; restarting capture worker")
                        break
                    }
                    if desktop.hasReadyFrame {
                        if readySince == nil { readySince = .now }
                        if let readySince, readySince.duration(to: .now) >= .seconds(10) { stable = true }
                    }
                    if ContinuousClock.now >= heartbeat {
                        do { try child.transport.send(ConsoleMessage(kind: .heartbeat)) }
                        catch { break }
                        heartbeat = .now + .seconds(1)
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                // Invalidate before termination: readers can finish an old IPC
                // frame after the new console session has already taken over.
                desktop.invalidate(generation: token)
                reader.cancel()
                child.stop()
                await reader.value
                logger.info("Console worker stopped: uid=\(identity.uid) audit=\(identity.auditID) status=\(child.process.terminationStatus)")
            } catch {
                logger.warning("console worker startup failed: \(error.localizedDescription)")
            }
            guard !Task.isCancelled else { break }
            guard ConsoleIdentity.current() == identity else { retry.reset(); continue }
            let delay = retry.failed(identity: identity, wasStable: stable)
            logger.warning("console worker retry in \(delay): uid=\(identity.uid) audit=\(identity.auditID)")
            let deadline = ContinuousClock.now + delay
            // A new console session should start promptly even during backoff.
            while !Task.isCancelled, ContinuousClock.now < deadline, ConsoleIdentity.current() == identity {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        desktop.invalidate()
    }
}

/// Failed starts of one session back off to eight seconds. A different audit
/// session or ten seconds of verified frames resets the failure history.
struct ConsoleWorkerRetryPolicy {
    private var identity: ConsoleIdentity?
    private var failures = 0

    mutating func reset() { identity = nil; failures = 0 }

    mutating func failed(identity: ConsoleIdentity, wasStable: Bool) -> Duration {
        if self.identity != identity || wasStable { reset() }
        self.identity = identity
        let delay = Duration.milliseconds(500 * (1 << failures))
        failures = min(failures + 1, 4)
        return delay
    }
}
