import CoreGraphics
import CVNCSession
import Darwin
import Foundation

struct ConsoleIdentity: Codable, Equatable, Sendable {
    let uid: UInt32
    let auditID: Int32
    var native: VNCConsoleIdentity { VNCConsoleIdentity(uid: uid, audit_id: auditID) }

    static func current() -> ConsoleIdentity? {
        var value = VNCConsoleIdentity()
        guard VNCConsoleCurrent(&value) == 0 else { return nil }
        return ConsoleIdentity(uid: value.uid, auditID: value.audit_id)
    }
    func verifyWorker() -> Bool { VNCConsoleVerify(native) == 0 }
}

struct ConsoleWorkerOptions: Codable, Sendable {
    let identity: ConsoleIdentity
    let fps: Int
    let scale: Double
    let display: Int // zero means combined displays
    let verbose: Bool

    func validate() throws {
        guard identity.auditID > 0, (1...120).contains(fps), scale.isFinite,
              scale > 0, scale <= 4, display >= 0 else {
            throw CLIError.invalidArgument("invalid console worker configuration")
        }
    }

    private func validateSocket() throws {
        try validate()
        // The internal entry point accepts only an inherited anonymous socket,
        // not a pathname, network listener, command, or arbitrary destination.
        var info = stat()
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let family = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(STDIN_FILENO, $0, &length)
            }
        }
        guard fstat(STDIN_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              family == 0, address.sun_family == AF_UNIX, address.sun_path.0 == 0 else {
            throw CLIError.commandFailed("console worker requires its supervisor's anonymous socket")
        }
    }

    func attachAndExec() throws -> Never {
        try validateSocket()
        // Resolve everything before dropping root; no graphics query happens
        // until the exec has cleared credential-change taint in the new image.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        let encoded = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        let error = VNCConsolePrepare(identity.native)
        guard error == 0 else {
            throw CLIError.commandFailed("cannot attach console worker: \(String(cString: strerror(error)))")
        }
        let execError = VNCConsoleExecWorker(executable, encoded)
        throw CLIError.commandFailed("cannot exec attached console worker: \(String(cString: strerror(execError)))")
    }

    func verifyAttachment() throws {
        try validateSocket()
        guard issetugid() == 0 else {
            throw CLIError.commandFailed("console worker is still setugid after exec; capture refused")
        }
        let error = VNCConsoleVerify(identity.native)
        guard error == 0 else {
            throw CLIError.commandFailed("console worker identity verification failed after exec: \(String(cString: strerror(error)))")
        }
        if verbose {
            print("Console worker attached: uid=\(identity.uid) audit=\(identity.auditID) setugid=0")
        }
    }
}

struct ConsoleFrameInfo: Codable {
    struct Display: Codable {
        let id: UInt32
        let bounds: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
    }
    let width: Int
    let height: Int
    let stride: Int
    let origin: CGPoint
    let scale: Double
    let displays: [Display]

    init(_ frame: Framebuffer) {
        width = frame.width; height = frame.height; stride = frame.bytesPerRow
        origin = frame.layout.origin; scale = frame.layout.scale
        displays = frame.layout.displays.map {
            Display(id: $0.id, bounds: $0.bounds, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
        }
    }

    func validate(pixelCount: Int) throws {
        guard (1...65535).contains(width), (1...65535).contains(height),
              stride >= width * 4, stride <= ConsoleTransport.maximumPixels / height,
              stride * height == pixelCount, scale.isFinite, scale > 0, scale <= 4,
              origin.x.isFinite, origin.y.isFinite, !displays.isEmpty, displays.count <= 32,
              displays.allSatisfy({
                  $0.bounds.minX.isFinite && $0.bounds.minY.isFinite &&
                  $0.bounds.width.isFinite && $0.bounds.height.isFinite &&
                  $0.bounds.width > 0 && $0.bounds.height > 0 &&
                  (1...65535).contains($0.pixelWidth) && (1...65535).contains($0.pixelHeight)
              }) else {
            throw RFBError.protocolError("invalid console framebuffer geometry")
        }
    }

    func framebuffer(pixels: [UInt8], sequence: UInt64) throws -> Framebuffer {
        try validate(pixelCount: pixels.count)
        let layout = VirtualDisplayLayout(displays: displays.map {
            VirtualDisplay(id: $0.id, bounds: $0.bounds, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
        }, origin: origin, scale: scale, width: width, height: height)
        return Framebuffer(width: width, height: height, bytesPerRow: stride,
                           bgra: pixels, layout: layout, sequence: sequence)
    }
}

struct ConsoleMessage: Codable {
    enum Kind: String, Codable { case frame, heartbeat, key, pointer, release, fps }
    let kind: Kind
    var frame: ConsoleFrameInfo?
    var client: UUID?
    var down: Bool?
    var keysym: UInt32?
    var apple: Bool?
    var mask: UInt8?
    var x: UInt16?
    var y: UInt16?
    var fps: Int?
}

/// A single reader and serialized writer per direction. Pixel bytes travel
/// directly after small JSON metadata, never base64, files or named sockets.
final class ConsoleTransport: @unchecked Sendable {
    static let maximumPixels = 256 * 1024 * 1024
    private let socket: ClientSocket
    private let writer = NSLock()
    init(fd: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(fd)
            throw RFBError.socketError("could not configure console IPC socket")
        }
        socket = try ClientSocket(fd: fd)
    }
    func shutdown() { socket.shutdown() }

    func send(_ message: ConsoleMessage, pixels: [UInt8] = []) throws {
        let metadata = Array(try JSONEncoder().encode(message))
        guard metadata.count <= 65536, pixels.count <= Self.maximumPixels,
              message.kind == .frame || pixels.isEmpty else {
            throw RFBError.protocolError("console message exceeds limits")
        }
        var header: [UInt8] = [67, 86, 78, 67] // CVNC
        for count in [metadata.count, pixels.count] {
            let size = UInt32(count)
            header += [UInt8(truncatingIfNeeded: size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                       UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)]
        }
        try writer.withLock {
            try socket.writeAll([header, metadata, pixels], idleTimeout: 2)
        }
    }

    func receive(timeout: TimeInterval = 10) throws -> (ConsoleMessage, [UInt8]) {
        try socket.withReadTimeout(timeout, operation: "console worker IPC") {
            let header = try socket.readExact(12)
            guard Array(header.prefix(4)) == [67, 86, 78, 67] else {
                throw RFBError.protocolError("invalid console IPC header")
            }
            func length(_ offset: Int) -> Int {
                header[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            }
            let metadataLength = length(4), pixelsLength = length(8)
            guard (1...65536).contains(metadataLength), pixelsLength <= Self.maximumPixels else {
                throw RFBError.protocolError("invalid console IPC length")
            }
            let message = try JSONDecoder().decode(ConsoleMessage.self, from: Data(socket.readExact(metadataLength)))
            if message.kind == .frame {
                guard let frame = message.frame else { throw RFBError.protocolError("missing console frame metadata") }
                try frame.validate(pixelCount: pixelsLength)
            } else if pixelsLength != 0 {
                throw RFBError.protocolError("unexpected console pixel payload")
            }
            return (message, try socket.readExact(pixelsLength))
        }
    }
}
