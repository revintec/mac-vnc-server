import Foundation

/// An internal RFB connection over an inherited socket, authenticated by the
/// root listener's descriptor handoff. It never owns the external viewer socket.
final class ConsoleFramebufferBridge: @unchecked Sendable, FramebufferSource, InputController {
    let socket: ClientSocket
    let identity: ConsoleIdentity
    let changes = FrameChangeHub()
    var frameChanges: FrameChangeHub? { changes }
    var includesCursor: Bool { true }
    private let lock = NSLock()
    private let writer = NSLock()
    private var frame: Framebuffer
    private var closed = false
    private var sequence: UInt64 = 0
    private var keys: Set<UInt32> = []
    private var pointer: (UInt16, UInt16) = (0, 0)

    init(socket: ClientSocket, identity: ConsoleIdentity) throws {
        self.socket = socket; self.identity = identity
        frame = Framebuffer(width: 1, height: 1, bgra: [0, 0, 0, 0], layout: .empty)
        do {
            try socket.withReadTimeout(75, operation: "console desktop startup") {
                guard try socket.readExact(4) == [0, 0, 0, 0] else {
                    throw RFBError.protocolError("console desktop initialization failed")
                }
                try socket.writeAll([1])
                let header = try socket.readExact(24)
                let width = Int(UInt16.be(header[0], header[1])), height = Int(UInt16.be(header[2], header[3]))
                let nameLength = Int(UInt32.be(header[20], header[21], header[22], header[23]))
                guard nameLength <= 4096 else { throw RFBError.protocolError("invalid internal desktop name") }
                _ = try socket.readExact(nameLength)
                frame = try Self.empty(width: width, height: height)
                // Raw pixels and an embedded cursor keep the private bridge
                // independent of the external client's codecs and encryption.
                try socket.writeAll([0, 0, 0, 0] + PixelFormat.serverDefault.bytes)
                try socket.writeAll([2, 0, 0, 2] + UInt32(0).beBytes
                    + UInt32(bitPattern: RFBPseudoEncoding.desktopSize).beBytes)
                try request(incremental: false)
                while try !readUpdate() { try request(incremental: false) }
            }
        } catch { socket.shutdown(); throw error }
    }

    func start(onClosed: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { stop(); onClosed() }
            do {
                while !lock.withLock({ closed }) {
                    try request(incremental: true)
                    // Idle desktops may wait indefinitely before an update.
                    guard try socket.readExact(1) == [0] else {
                        throw RFBError.protocolError("unexpected internal server message")
                    }
                    let changed = try socket.withReadTimeout(10, operation: "console framebuffer") {
                        try readUpdate(typeAlreadyRead: true)
                    }
                    if changed { changes.signal() }
                }
            } catch { /* Returning to the account desktop preserves the viewer. */ }
        }
    }

    func stop() { lock.withLock { closed = true }; socket.shutdown() }
    func capture() throws -> Framebuffer { lock.withLock { frame } }

    private static func empty(width: Int, height: Int) throws -> Framebuffer {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              width * height <= 64 * 1024 * 1024 else {
            throw RFBError.protocolError("invalid internal framebuffer size")
        }
        return Framebuffer(width: width, height: height, bgra: [UInt8](repeating: 0, count: width * height * 4),
            layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: width, height: height))
    }

    private func request(incremental: Bool) throws {
        let size = lock.withLock { (frame.width, frame.height) }
        try writer.withLock {
            try socket.writeAll([3, incremental ? 1 : 0, 0, 0, 0, 0]
                + UInt16(size.0).beBytes + UInt16(size.1).beBytes)
        }
    }

    private func readUpdate(typeAlreadyRead: Bool = false) throws -> Bool {
        if !typeAlreadyRead, try socket.readExact(1) != [0] {
            throw RFBError.protocolError("unexpected internal server message")
        }
        let header = try socket.readExact(3)
        let count = Int(UInt16.be(header[1], header[2]))
        var next = lock.withLock { frame }
        var pixels = next.bgra
        var changed = false
        for _ in 0..<count {
            let r = try socket.readExact(12)
            let x = Int(UInt16.be(r[0], r[1])), y = Int(UInt16.be(r[2], r[3]))
            let w = Int(UInt16.be(r[4], r[5])), h = Int(UInt16.be(r[6], r[7]))
            let encoding = Int32(bitPattern: UInt32.be(r[8], r[9], r[10], r[11]))
            if encoding == RFBPseudoEncoding.desktopSize {
                next = try Self.empty(width: w, height: h); pixels = next.bgra
                continue
            }
            guard encoding == 0, w > 0, h > 0, x + w <= next.width, y + h <= next.height else {
                throw RFBError.protocolError("invalid internal rectangle")
            }
            let bytes = try socket.readExact(w * h * 4)
            pixels.withUnsafeMutableBytes { destination in
                bytes.withUnsafeBytes { source in
                    for row in 0..<h {
                        memcpy(destination.baseAddress!.advanced(by: ((y + row) * next.width + x) * 4),
                            source.baseAddress!.advanced(by: row * w * 4), w * 4)
                    }
                }
            }
            changed = true
        }
        sequence &+= 1
        let updated = Framebuffer(width: next.width, height: next.height, bgra: pixels,
            layout: next.layout, sequence: sequence)
        lock.withLock { frame = updated }
        return changed
    }

    func key(down: Bool, keysym: UInt32, mapAltToCommand: Bool) {
        // The private peer uses standard keysyms. Preserve Apple's swapped
        // Option/Command convention before forwarding to that peer.
        let symbol: UInt32 = mapAltToCommand
            ? ([0xffe7: 0xffe9, 0xffe8: 0xffea, 0xffe9: 0xffe7, 0xffea: 0xffe8][keysym] ?? keysym) : keysym
        writer.withLock {
            if down { keys.insert(symbol) } else { keys.remove(symbol) }
            do { try socket.writeAll([4, down ? 1 : 0, 0, 0] + symbol.beBytes) }
            catch { socket.shutdown() }
        }
    }
    func pointer(buttonMask: UInt8, x: UInt16, y: UInt16, layout: VirtualDisplayLayout) {
        writer.withLock {
            pointer = (x, y)
            do { try socket.writeAll([5, buttonMask] + x.beBytes + y.beBytes) }
            catch { socket.shutdown() }
        }
    }
    func releaseKeys() {
        writer.withLock {
            do {
                for key in keys { try socket.writeAll([4, 0, 0, 0] + key.beBytes) }
                try socket.writeAll([5, 0] + pointer.0.beBytes + pointer.1.beBytes)
            } catch { socket.shutdown() }
            keys.removeAll()
        }
    }
}
