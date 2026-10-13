import Darwin
import Foundation

/// Owns an out-of-process cleanup manager. It deliberately is not registered as
/// a kill-on-exit capture worker: parent death closes the socket, allowing the
/// manager to remove its launchd job even after SIGKILL or forced Ctrl-C exit.
final class ConsoleCaptureBroker {
    private let process: Process
    private let lifeline: ClientSocket

    init(identity: ConsoleIdentity) throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw RFBError.socketError("could not create console capture broker lifeline")
        }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let input = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        lifeline = try ClientSocket(fd: fds[0])
        process = Process()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["asuser", "0", executable.path, "--console-capture-broker", String(identity.auditID)]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = input
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        try? input.close()
        do {
            // Allow bounded orphan bootout/retry before bootstrapping the service.
            try lifeline.withReadTimeout(20, operation: "console capture broker startup") {
                guard try lifeline.readExact(1) == [1] else {
                    throw RFBError.captureFailed("console capture broker did not become ready")
                }
            }
        } catch {
            lifeline.shutdown()
            throw error
        }
    }

    deinit { lifeline.shutdown() }

    var isRunning: Bool { process.isRunning }

    func stop() {
        lifeline.shutdown()
        let deadline = ContinuousClock.now + .seconds(6)
        while process.isRunning, ContinuousClock.now < deadline { usleep(20_000) }
        // The manager independently bounds launchctl teardown and watches EOF.
        // Killing it here would prevent that cleanup during a stuck OS request.
    }
}
