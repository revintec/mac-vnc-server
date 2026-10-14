import CVNCSession
import Darwin
import Foundation

/// Private, inherited socketpair. Only admissions and a readiness byte travel
/// here; framebuffer, clipboard, file bytes, and input never enter this channel.
final class SessionChannel: @unchecked Sendable {
    let socket: ClientSocket
    private let writer = NSLock()

    init(fd: Int32) throws {
        socket = try ClientSocket(fd: fd)
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw RFBError.socketError("could not configure session channel")
        }
    }

    static func pair() throws -> (SessionChannel, FileHandle) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw RFBError.socketError("could not create session channel")
        }
        let child = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        _ = fcntl(pair[1], F_SETFD, FD_CLOEXEC)
        return (try SessionChannel(fd: pair[0]), child)
    }

    static func validateInheritedSocket() throws {
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(STDIN_FILENO, $0, &length) }
        }
        guard status == 0, address.sun_family == AF_UNIX, address.sun_path.0 == 0 else {
            throw CLIError.commandFailed("session worker requires an inherited anonymous socket")
        }
    }

    func ready() throws { try socket.writeAll([82]) }
    func waitUntilReady(timeout: TimeInterval = 40) throws {
        try socket.withReadTimeout(timeout, operation: "session worker startup") {
            guard try socket.readExact(1) == [82] else { throw RFBError.protocolError("invalid session worker response") }
        }
    }

    func send(client: ClientSocket, admission: SessionAdmission) throws {
        let bytes = Array(try JSONEncoder().encode(admission))
        guard bytes.count <= 4096 else { throw RFBError.protocolError("session admission too large") }
        try writer.withLock {
            let result = VNCSessionSendDescriptor(socket.fd, client.fd)
            guard result == 0 else { throw RFBError.socketError("session socket handoff failed (\(result))") }
            try socket.writeAll(UInt32(bytes.count).beBytes + bytes)
        }
    }

    func receive(timeout: TimeInterval = 0.25) throws -> (ClientSocket, SessionAdmission)? {
        var descriptor = pollfd(fd: socket.fd, events: Int16(POLLIN), revents: 0)
        let count = poll(&descriptor, 1, Int32(timeout * 1000))
        if count == 0 || (count < 0 && errno == EINTR) { return nil }
        guard count > 0 else { throw RFBError.socketError("session channel poll failed") }
        var fd: Int32 = -1
        let result = VNCSessionReceiveDescriptor(socket.fd, &fd)
        if result == EAGAIN || result == EWOULDBLOCK { return nil }
        guard result == 0 else { throw RFBError.socketError("session channel closed or invalid (\(result))") }
        let client = try ClientSocket(fd: fd)
        let admission = try socket.withReadTimeout(5, operation: "session admission") {
            let header = try socket.readExact(4)
            let size = Int(UInt32.be(header[0], header[1], header[2], header[3]))
            guard (1...4096).contains(size) else { throw RFBError.protocolError("invalid session admission length") }
            return try JSONDecoder().decode(SessionAdmission.self, from: Data(socket.readExact(size)))
        }
        return (client, admission)
    }

    func shutdown() { socket.shutdown() }
}

struct SessionWorkerOptions: Codable, Sendable {
    let identity: ConsoleIdentity
    let config: ServerConfig

    func validate() throws {
        guard identity.auditID > 0,
              (1...120).contains(config.fps), config.scale.isFinite, config.scale > 0, config.scale <= 4 else {
            throw CLIError.invalidArgument("invalid account session worker options")
        }
        if identity.uid == 0, config.clipboardSync || config.fileTransfer {
            throw CLIError.invalidArgument("loginwindow workers support display and input only")
        }
    }

    func attachAndExec() throws -> Never {
        try validate()
        try SessionChannel.validateInheritedSocket()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        let encoded = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        let error = VNCSessionPrepare(identity.native)
        guard error == 0 else { throw CLIError.commandFailed("session attachment failed (\(error))") }
        let result = VNCSessionExecWorker(executable, encoded)
        throw CLIError.commandFailed("session worker exec failed (\(result))")
    }

    func verifyAttachment() throws {
        try validate()
        try SessionChannel.validateInheritedSocket()
        guard VNCSessionVerify(identity.native) == 0 else {
            throw CLIError.commandFailed("session worker identity verification failed")
        }
    }
}
