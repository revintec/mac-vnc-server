import Foundation

/// An internal RFB connection over an inherited socket, authenticated by the
/// root listener's descriptor handoff. It never owns the external viewer socket.
final class ConsoleFramebufferBridge: @unchecked Sendable, FramebufferSource, InputController {
    let socket: ClientSocket
    let identity: ConsoleIdentity
    let changes = FrameChangeHub()
    var frameChanges: FrameChangeHub? { changes }
    var includesCursor: Bool { false }
    var cursorSnapshot: CursorSnapshot? { lock.withLock { cursor } }
    private let lock = NSLock()
    private let writer = NSLock()
    private var frame: Framebuffer
    private var cursor = CursorSnapshot(image: .hidden, position: .zero)
    private var closed = false
    private var sequence: UInt64 = 0
    private var keys: Set<UInt32> = []
    private var pointer: (UInt16, UInt16) = (0, 0)

    init(socket: ClientSocket, identity: ConsoleIdentity, startupTimeout: TimeInterval = 75) throws {
        self.socket = socket; self.identity = identity
        frame = Framebuffer(width: 1, height: 1, bgra: [0, 0, 0, 0], layout: .empty)
        var stage = "starting capture and input"
        do {
            try socket.withReadTimeout(startupTimeout, operation: "console desktop startup") {
                let status = try socket.readExact(4)
                if status != [0, 0, 0, 0] {
                    let header = try socket.readExact(4)
                    let count = Int(UInt32.be(header[0], header[1], header[2], header[3]))
                    guard (1...4096).contains(count) else {
                        throw RFBError.protocolError("invalid console desktop error length")
                    }
                    throw CLIError.commandFailed(String(decoding: try socket.readExact(count), as: UTF8.self))
                }
                stage = "initializing the framebuffer"
                try socket.writeAll([1])
                let header = try socket.readExact(24)
                let width = Int(UInt16.be(header[0], header[1])), height = Int(UInt16.be(header[2], header[3]))
                let nameLength = Int(UInt32.be(header[20], header[21], header[22], header[23]))
                guard nameLength <= 4096 else { throw RFBError.protocolError("invalid internal desktop name") }
                _ = try socket.readExact(nameLength)
                frame = try Self.empty(width: width, height: height)
                // Carry the cursor separately so the external viewer can move
                // it immediately. Position updates also support Observe mode
                // and viewers that need their cursor composited into pixels.
                try socket.writeAll([0, 0, 0, 0] + PixelFormat.serverDefault.bytes)
                let encodings: [Int32] = [0, RFBPseudoEncoding.desktopSize,
                    RFBPseudoEncoding.richCursor, RFBPseudoEncoding.pointerPosition]
                try socket.writeAll([2, 0] + UInt16(encodings.count).beBytes
                    + encodings.flatMap { UInt32(bitPattern: $0).beBytes })
                stage = "waiting for the first screen image"
                try request(incremental: false)
                while try !readUpdate() { try request(incremental: false) }
            }
        } catch {
            socket.shutdown()
            let desktop = identity.uid == 0 ? "loginwindow" : "console user \(identity.uid)"
            throw CLIError.commandFailed("Could not view \(desktop) (audit \(identity.auditID)) while \(stage): \(error.localizedDescription)")
        }
    }

    /// Private, already-authorized peers may receive desktop startup details.
    /// Ordinary network authentication deliberately keeps its generic errors.
    static func rejectStartup(socket: ClientSocket, error: any Error) throws {
        let bytes = Array(CLI.errorMessage(for: error).utf8.prefix(4096))
        try socket.writeAll(UInt32(1).beBytes + UInt32(bytes.count).beBytes + bytes)
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
                    _ = try socket.withReadTimeout(10, operation: "console framebuffer") {
                        try readUpdate(typeAlreadyRead: true)
                    }
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
        let oldCursor = lock.withLock { cursor }
        var nextCursor = oldCursor
        var pixels = next.bgra
        var changed = false
        var resized = false
        for _ in 0..<count {
            let r = try socket.readExact(12)
            let x = Int(UInt16.be(r[0], r[1])), y = Int(UInt16.be(r[2], r[3]))
            let w = Int(UInt16.be(r[4], r[5])), h = Int(UInt16.be(r[6], r[7]))
            let encoding = Int32(bitPattern: UInt32.be(r[8], r[9], r[10], r[11]))
            if encoding == RFBPseudoEncoding.desktopSize {
                next = try Self.empty(width: w, height: h); pixels = next.bgra
                resized = true
                continue
            }
            if encoding == RFBPseudoEncoding.richCursor {
                // A sampled shape is at most 256 points; --scale supports up
                // to 4x, so its negotiated wire image may be 1024 pixels.
                guard (w == 0 && h == 0) || (w > 0 && h > 0 && w <= 1024 && h <= 1024 && x < w && y < h) else {
                    throw RFBError.protocolError("invalid internal cursor shape")
                }
                var image = CursorImage.hidden
                if w > 0 {
                    var bgra = try socket.readExact(w * h * 4)
                    let stride = (w + 7) / 8
                    let mask = try socket.readExact(stride * h)
                    for row in 0..<h { for column in 0..<w {
                        let offset = (row * w + column) * 4
                        let visible = mask[row * stride + column / 8] & (0x80 >> (column % 8)) != 0
                        bgra[offset + 3] = visible ? 255 : 0
                        if !visible { bgra[offset] = 0; bgra[offset + 1] = 0; bgra[offset + 2] = 0 }
                    } }
                    image = CursorImage(width: w, height: h, hotX: x, hotY: y, bgra: bgra)
                }
                nextCursor = CursorSnapshot(image: image, position: nextCursor.position)
                continue
            }
            if encoding == RFBPseudoEncoding.pointerPosition {
                guard w == 0, h == 0, x < next.width, y < next.height else {
                    throw RFBError.protocolError("invalid internal cursor position")
                }
                nextCursor = CursorSnapshot(image: nextCursor.image, position: CGPoint(x: x, y: y))
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
        if changed || resized { sequence &+= 1 }
        let updated = Framebuffer(width: next.width, height: next.height, bgra: pixels,
            layout: next.layout, sequence: sequence)
        lock.withLock { frame = updated; cursor = nextCursor }
        if changed || resized || nextCursor != oldCursor { changes.signal() }
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
