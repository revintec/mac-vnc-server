import Foundation

struct ServerConfig {
    let bindAddress: String
    let port: UInt16
    let password: String?
    let passwordFromConfig: Bool
    let fps: Int
    let scale: Double
    let encodingPreference: EncodingPreference
    let displaySelection: DisplaySelection
    let verbose: Bool
    let clipboardSync: Bool
    let adaptiveStreaming: Bool
    let adaptiveFrameRate: Bool
}

enum DisplaySelection: Equatable {
    case automatic
    case all
    case display(Int)
}

enum EncodingPreference: String {
    case auto
    case zrle
    case zlib
    case raw
}

enum RFBEncoding: Int32 {
    case raw = 0
    case zlib = 6
    case zrle = 16
}

enum RFBStandardEncoding {
    static let copyRect: Int32 = 1
    static let tight: Int32 = 7
}

enum RFBPseudoEncoding {
    static let xCursor: Int32 = -240
    static let richCursor: Int32 = -239
    static let desktopSize: Int32 = -223
    static let extendedDesktopSize: Int32 = -308
}

struct RFBClientCapabilities: Equatable {
    let advertisedEncodings: [Int32]
    let supportsRaw: Bool
    let supportsCopyRect: Bool
    let supportsTight: Bool
    let supportsZlib: Bool
    let supportsZRLE: Bool
    let supportsXCursor: Bool
    let supportsRichCursor: Bool
    let supportsDesktopSize: Bool
    let supportsExtendedDesktopSize: Bool
    let isAppleScreenSharingClient: Bool

    init(encodings: [Int32]) {
        advertisedEncodings = encodings
        supportsRaw = encodings.contains(RFBEncoding.raw.rawValue)
        supportsCopyRect = encodings.contains(RFBStandardEncoding.copyRect)
        supportsTight = encodings.contains(RFBStandardEncoding.tight)
        supportsZlib = encodings.contains(RFBEncoding.zlib.rawValue)
        supportsZRLE = encodings.contains(RFBEncoding.zrle.rawValue)
        supportsXCursor = encodings.contains(RFBPseudoEncoding.xCursor)
        supportsRichCursor = encodings.contains(RFBPseudoEncoding.richCursor)
        supportsDesktopSize = encodings.contains(RFBPseudoEncoding.desktopSize)
        supportsExtendedDesktopSize = encodings.contains(RFBPseudoEncoding.extendedDesktopSize)
        isAppleScreenSharingClient = encodings.contains(1011)
            || encodings.contains(1002)
            || encodings.contains(1100)
            || encodings.contains(1104)
    }

    var summary: String {
        let names = [
            supportsRaw ? "raw" : nil,
            supportsCopyRect ? "copyrect" : nil,
            supportsTight ? "tight" : nil,
            supportsZlib ? "zlib" : nil,
            supportsZRLE ? "zrle" : nil,
            supportsXCursor || supportsRichCursor ? "cursor" : nil,
            supportsDesktopSize || supportsExtendedDesktopSize ? "resize" : nil
        ].compactMap { $0 }

        return "encodings=[\(advertisedEncodings.map(String.init).joined(separator: ","))] " +
            "features=[\(names.joined(separator: ","))] " +
            "apple=\(isAppleScreenSharingClient)"
    }

    var supportsDynamicResize: Bool {
        supportsDesktopSize && !isAppleScreenSharingClient
    }
}

// The registry is locked; capture supports concurrent snapshots. Factories create
// a separate clipboard subscription and input ownership handle for each session.
final class RFBServer: @unchecked Sendable {
    private let config: ServerConfig
    private let capture: FramebufferSource
    private let makeInput: @Sendable () -> InputController
    private let makeClipboard: @Sendable () -> ClipboardBridge
    private let logger: ServerLogger
    private let maximumClients: Int
    private let handshakeTimeout: TimeInterval
    private let messageTimeout: TimeInterval
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private var stopped = false
    private var clients: [ObjectIdentifier: ClientSocket] = [:]

    init(
        config: ServerConfig,
        capture: FramebufferSource,
        makeInput: @escaping @Sendable () -> InputController,
        makeClipboard: @escaping @Sendable () -> ClipboardBridge,
        logger: ServerLogger,
        maximumClients: Int = 32,
        handshakeTimeout: TimeInterval = 5,
        messageTimeout: TimeInterval = 5
    ) {
        self.config = config
        self.capture = capture
        self.makeInput = makeInput
        self.makeClipboard = makeClipboard
        self.logger = logger
        self.maximumClients = maximumClients
        self.handshakeTimeout = handshakeTimeout
        self.messageTimeout = messageTimeout
    }

    func run(listener suppliedListener: ListeningSocket? = nil) throws {
        let listener = try suppliedListener ?? ListeningSocket(bindAddress: config.bindAddress, port: config.port)
        defer {
            stop()
            workers.wait()
        }
        logger.info("mac-vnc-server \(AppVersion.current)")
        logger.info("mac-vnc-server listening on \(config.bindAddress):\(config.port)")
        let fpsDescription = config.adaptiveFrameRate ? "auto(60-45-30)" : "\(config.fps)"
        logger.info("fps=\(fpsDescription) scale=\(config.scale) encoding=\(config.encodingPreference.rawValue) display=\(config.displaySelection.description)")
        logger.info("password configured: \(config.password != nil)")
        logger.info("clipboard sync: \(config.clipboardSync ? "enabled" : "disabled")")
        logger.info("shared desktop: up to \(maximumClients) concurrent clients per port")
        logger.info("Connect with vnc://\(config.bindAddress == "0.0.0.0" ? "127.0.0.1" : config.bindAddress):\(config.port)")

        while !lock.withLock({ stopped }) {
            guard let client = try listener.acceptClient(timeout: 0.25) else { continue }
            let id = ObjectIdentifier(client)
            let admitted = lock.withLock {
                guard !stopped, clients.count < maximumClients else { return false }
                clients[id] = client
                return true
            }
            guard admitted else {
                client.shutdown()
                logger.warning("connection rejected: server stopping or client limit reached")
                continue
            }
            do {
                // A peer closing during socket setup must only fail its own session.
                try client.configureTCP()
                let session = try RFBClientSession(
                    socket: client, password: config.password, fps: config.fps,
                    encodingPreference: config.encodingPreference, capture: capture,
                    input: makeInput(), clipboard: makeClipboard(),
                    clipboardSync: config.clipboardSync, adaptiveStreaming: config.adaptiveStreaming,
                    adaptiveFrameRate: config.adaptiveFrameRate, logger: logger,
                    handshakeTimeout: handshakeTimeout, messageTimeout: messageTimeout
                )
                workers.enter()
                DispatchQueue.global(qos: .userInteractive).async { [self] in
                    defer {
                        session.shutdown()
                        lock.withLock { clients[id] = nil }
                        workers.leave()
                    }
                    do { try session.run() }
                    catch { logger.warning("client disconnected: \(error.localizedDescription)") }
                }
            } catch {
                client.shutdown()
                lock.withLock { clients[id] = nil }
                logger.warning("could not start client: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            for client in clients.values { client.shutdown() }
        }
    }
}

extension DisplaySelection {
    var description: String {
        switch self {
        case .automatic:
            return "auto"
        case .all:
            return "all"
        case .display(let index):
            return "\(index)"
        }
    }
}

struct AdaptiveFrameRateController {
    static let frameRates = [60, 45, 30]

    private(set) var index: Int
    private var slowFrameStreak = 0
    private var fastFrameStreak = 0

    init(startingFrameRate: Int = 60) {
        index = Self.frameRates.firstIndex(of: startingFrameRate) ?? 0
    }

    var frameRate: Int {
        Self.frameRates[index]
    }

    mutating func update(frameDuration: TimeInterval) -> Int? {
        let target = 1.0 / Double(frameRate)
        if frameDuration > target * 1.15 {
            slowFrameStreak += 1
            fastFrameStreak = 0
            guard slowFrameStreak >= 6 else {
                return nil
            }

            slowFrameStreak = 0
            guard index + 1 < Self.frameRates.count else {
                return nil
            }

            index += 1
            return frameRate
        }

        guard frameDuration < target * 0.70 else {
            slowFrameStreak = 0
            fastFrameStreak = 0
            return nil
        }

        fastFrameStreak += 1
        slowFrameStreak = 0
        guard fastFrameStreak >= 300 else {
            return nil
        }

        fastFrameStreak = 0
        guard index > 0 else {
            return nil
        }

        index -= 1
        return frameRate
    }

    mutating func reduceForBackpressure() -> Int? {
        slowFrameStreak = 0
        fastFrameStreak = 0
        guard index + 1 < Self.frameRates.count else {
            return nil
        }
        index += 1
        return frameRate
    }
}

struct AdaptiveScaleController {
    static let scales = [1.0, 0.75, 0.67]

    private(set) var index = 0
    private var overloadTime: TimeInterval = 0
    private var healthyTime: TimeInterval = 0

    var scale: Double {
        Self.scales[index]
    }

    mutating func update(
        frameDuration: TimeInterval,
        encodeDuration: TimeInterval,
        writeDuration: TimeInterval,
        frameInterval: TimeInterval,
        minimumFrameInterval: TimeInterval,
        staleRetries: Int,
        hadNetworkStall: Bool
    ) -> Double? {
        let encodeBudget = minimumFrameInterval * 1.10
        let overloaded = hadNetworkStall
            || frameDuration > frameInterval * 1.25
            || encodeDuration > encodeBudget
            || writeDuration > frameInterval * 1.10
            || staleRetries >= 2

        if overloaded {
            healthyTime = 0
            overloadTime += max(frameDuration, frameInterval)
            guard overloadTime >= 0.5 else {
                return nil
            }
            overloadTime = 0
            guard index + 1 < Self.scales.count else {
                return nil
            }
            index += 1
            return scale
        }

        overloadTime = 0
        guard index > 0,
              !hadNetworkStall,
              staleRetries == 0,
              frameDuration < frameInterval * 0.85,
              encodeDuration < encodeBudget * 0.8,
              writeDuration < frameInterval * 0.8 else {
            healthyTime = 0
            return nil
        }

        healthyTime += max(frameDuration, frameInterval)
        guard healthyTime >= 5 else {
            return nil
        }
        healthyTime = 0
        index -= 1
        return scale
    }
}

final class RFBClientSession: @unchecked Sendable {
    private struct FramebufferUpdateRequest {
        let incremental: Bool
        let rect: Rect
    }

    private enum EncodingTransaction {
        case zlib(ZlibEncoder.Transaction)
        case zrle(ZRLEEncoder.Transaction)
    }

    private struct PreparedFramebufferUpdate {
        let framebuffer: Framebuffer
        let encoding: RFBEncoding
        let rects: [Rect]
        let encodedRects: [[UInt8]]
        let desktopSizeChanged: Bool
        let changedPixels: Int
        let uncompressedBytes: Int
        let payloadBytes: Int
        let captureDuration: TimeInterval
        let diffDuration: TimeInterval
        let encodeDuration: TimeInterval
        let transaction: EncodingTransaction?
    }

    private let socket: ClientSocket
    private let handshakeTimeout: TimeInterval
    private let messageTimeout: TimeInterval
    private let writer = DispatchGroup()
    private let password: String?
    private let minimumFrameInterval: TimeInterval
    private var frameInterval: TimeInterval
    private let encodingPreference: EncodingPreference
    private let capture: FramebufferSource
    private let input: InputController
    private let clipboard: ClipboardBridge
    private let clipboardSync: Bool
    private let adaptiveStreaming: Bool
    private let adaptiveFrameRate: Bool
    private let logger: ServerLogger
    private var pixelFormat = PixelFormat.serverDefault
    private var clientCapabilities = RFBClientCapabilities(encodings: [RFBEncoding.raw.rawValue])
    private var previousFramebuffer: Framebuffer?
    private var currentLayout = VirtualDisplayLayout.empty
    private var lastFramebufferUpdate = Date.distantPast
    private var hasSentFramebufferUpdate = false
    private let zrleEncoder: ZRLEEncoder
    private let zlibEncoder: ZlibEncoder
    private let state = NSCondition()
    private var stopped = false
    private var latestUpdateRequest: FramebufferUpdateRequest?
    private var activeUpdateRequest: FramebufferUpdateRequest?
    private var writerError: Error?
    private var captureRateConsumer: ObjectIdentifier?
    private var networkStallNotifications = 0
    private var networkStalls = 0
    private var staleFrameRetries = 0
    private var updatesSent = 0
    private var bytesSent = 0
    private var adaptiveFrameRateController: AdaptiveFrameRateController
    private var adaptiveScaleController = AdaptiveScaleController()
    private var adaptiveScale = 1.0
    private var frameHadNetworkStall = false
    private var forceFullFramebuffer = false
    // Negotiated once before the writer starts. All other Apple state uses `state`.
    private var usesAppleClipboard = false
    private var appleViewerCapabilities: [UInt8] = []
    private var appleControlMode = true
    private var appleAutoPasteboard = false
    private var appleInitialClipboardNotification = false
    private var appleClipboardGeneration: UInt64 = 0
    private var appleAutomaticUpdate: FramebufferUpdateRequest?
    private var applePushInterval: TimeInterval = 0
    private var appleNextPush = Date.distantPast
    // Accessed only by the writer; retained between a promises-only and a full fetch.
    private var applePromisedText: (generation: UInt64, text: String)?

    private enum WriterCommand {
        case clipboardFetch(requestID: UInt32, promises: Bool)
        case status(UInt16)
    }
    private var writerCommands: [WriterCommand] = []
    private var pendingCursorEncoding: Int32?

    init(
        socket: ClientSocket,
        password: String?,
        fps: Int,
        encodingPreference: EncodingPreference,
        capture: FramebufferSource,
        input: InputController,
        clipboard: ClipboardBridge,
        clipboardSync: Bool,
        adaptiveStreaming: Bool,
        adaptiveFrameRate: Bool,
        logger: ServerLogger,
        handshakeTimeout: TimeInterval = 5,
        messageTimeout: TimeInterval = 5
    ) throws {
        self.handshakeTimeout = handshakeTimeout
        self.messageTimeout = messageTimeout
        self.socket = socket
        self.password = password
        minimumFrameInterval = 1.0 / Double(fps)
        frameInterval = minimumFrameInterval
        self.encodingPreference = encodingPreference
        self.capture = capture
        self.input = input
        self.clipboard = clipboard
        self.clipboardSync = clipboardSync
        self.adaptiveStreaming = adaptiveStreaming
        self.adaptiveFrameRate = adaptiveFrameRate
        self.logger = logger
        adaptiveFrameRateController = AdaptiveFrameRateController(startingFrameRate: fps)
        zrleEncoder = try ZRLEEncoder()
        zlibEncoder = try ZlibEncoder()
    }

    func run() throws {
        let initialFrame = try capture.capture()
        currentLayout = initialFrame.layout
        previousFramebuffer = initialFrame

        try socket.withReadTimeout(handshakeTimeout, operation: "RFB handshake") {
            try handshake(initialFrame: initialFrame)
        }
        let captureRateConsumer = ObjectIdentifier(self)
        self.captureRateConsumer = captureRateConsumer
        (capture as? CaptureFrameRateController)?.registerCaptureRateConsumer(
            captureRateConsumer,
            fps: Int((1.0 / minimumFrameInterval).rounded())
        )
        startFramebufferWriter()
        defer {
            stopFramebufferWriter()
            input.releaseKeys()
            if let captureRateConsumer = self.captureRateConsumer {
                (capture as? CaptureFrameRateController)?.unregisterCaptureRateConsumer(captureRateConsumer)
            }
        }

        while true {
            if let writerError = consumeWriterError() {
                throw writerError
            }
            // A healthy viewer may stay idle indefinitely. Once a message
            // starts, all of its fields must arrive within one total deadline.
            let messageType = try socket.readExact(1)[0]
            try socket.withReadTimeout(messageTimeout, operation: "RFB client message") {
                try handleClientMessage(messageType)
            }
        }
    }

    private func handleClientMessage(_ messageType: UInt8) throws {
        switch messageType {
        case 0:
            try handleSetPixelFormat()
        case 2:
            try handleSetEncodings()
        case 3:
            try handleFramebufferUpdateRequestMessage()
        case 4:
            try handleKeyEvent()
        case 5:
            try handlePointerEvent()
        case 6:
            try handleClientCutText()
        case 0x09:
            try requireAppleClipboard()
            try handleAppleAutoFramebufferUpdate()
        case 0x0a:
            try requireAppleClipboard()
            try handleAppleSetMode()
        case 0x0b:
            try requireAppleClipboard()
            try handleAppleClipboardFetch()
        case 0x15:
            try requireAppleClipboard()
            try handleAppleAutoPasteboard()
        case 0x1f:
            try requireAppleClipboard()
            try handleAppleClipboardSend()
        case 0x21:
            try requireAppleClipboard()
            try handleAppleViewerInfo()
        default:
            throw RFBError.protocolError("unsupported client message \(messageType)")
        }
    }

    private func handshake(initialFrame: Framebuffer) throws {
        let preferLegacyHandshake = password != nil
        let banner = clipboardSync ? AppleRFB.version
            : (preferLegacyHandshake ? "RFB 003.003\n" : "RFB 003.008\n")
        try socket.writeString(banner)
        let clientVersion = try socket.readExact(12)
        let versionText = String(bytes: clientVersion, encoding: .ascii) ?? "unknown"
        guard ["RFB 003.003\n", "RFB 003.007\n", "RFB 003.008\n", AppleRFB.version].contains(versionText),
              versionText != AppleRFB.version || clipboardSync else {
            throw RFBError.protocolError("unsupported RFB protocol version")
        }
        let isRFB33 = versionText == "RFB 003.003\n"
        logger.verbose("RFB handshake: viewer selected \(versionText.trimmingCharacters(in: .whitespacesAndNewlines))")

        if isRFB33 {
            if let password {
                try socket.writeAll(UInt32(2).beBytes)
                try authenticate(password: password)
            } else {
                try socket.writeAll(UInt32(1).beBytes)
            }
        } else {
            if password == nil {
                try socket.writeAll([1, 1])
            } else {
                // Never offer None alongside a configured password.
                try socket.writeAll([1, 2])
            }

            // Apple's viewer implicitly selects the single classic security type
            // in 3.889 and waits for the challenge (or None's result) immediately.
            // Standard 3.7/3.8 viewers still send the one-byte selector.
            let selectedSecurity: UInt8 = versionText == AppleRFB.version
                ? (password == nil ? 1 : 2) : try socket.readExact(1)[0]
            logger.verbose("RFB handshake: security type \(selectedSecurity)")
            switch selectedSecurity {
            case 1:
                guard password == nil else {
                    throw RFBError.authenticationFailed
                }
                // RFB 3.7 omits SecurityResult for the None security type.
                if versionText != "RFB 003.007\n" {
                    try socket.writeAll(UInt32(0).beBytes)
                }
            case 2:
                guard let password else {
                    try socket.writeAll(UInt32(1).beBytes)
                    throw RFBError.authenticationFailed
                }
                try authenticate(password: password)
            default:
                throw RFBError.protocolError("unsupported security type \(selectedSecurity)")
            }
        }

        let clientInit = try socket.readExact(1)[0]
        logger.verbose("RFB handshake: ClientInit=\(clientInit)")
        // Always share the desktop, even when ClientInit requests an exclusive session.
        // A newly connected viewer must never evict an existing viewer.
        usesAppleClipboard = versionText == AppleRFB.version && clientInit & 0x80 != 0
        // Apple's viewer commonly sends 0xc1. The optional session-selection
        // request is declined by leaving server flag 0x04 clear, not by disconnecting.
        try sendServerInit(framebuffer: initialFrame)
        logger.info("client connected: \(versionText.trimmingCharacters(in: .whitespacesAndNewlines)), framebuffer \(initialFrame.width)x\(initialFrame.height), clipboard=\(clipboardSync ? (usesAppleClipboard ? "apple" : "classic") : "off")")
    }

    private func authenticate(password: String) throws {
        var challenge = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, challenge.count, &challenge)
        if status != errSecSuccess {
            for index in challenge.indices {
                challenge[index] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }

        try socket.writeAll(challenge)
        let response = try socket.readExact(16)
        if try VNCAuth.response(challenge: challenge, password: password) == response {
            try socket.writeAll(UInt32(0).beBytes)
        } else {
            try socket.writeAll(UInt32(1).beBytes)
            throw RFBError.authenticationFailed
        }
    }

    private func sendServerInit(framebuffer: Framebuffer) throws {
        var bytes: [UInt8] = []
        bytes += UInt16(framebuffer.width).beBytes
        bytes += UInt16(framebuffer.height).beBytes
        bytes += PixelFormat.serverDefault.bytes
        let name = usesAppleClipboard ? AppleRFB.desktopName("mac-vnc-server") : Array("mac-vnc-server".utf8)
        bytes += UInt32(name.count).beBytes
        bytes += Array(name)
        try socket.writeAll(bytes)
    }

    private func handleSetPixelFormat() throws {
        _ = try socket.readExact(3)
        let bytes = try socket.readExact(16)
        let requested = try PixelFormat(bytes: bytes)
        guard requested.trueColor, [8, 16, 32].contains(requested.bitsPerPixel) else {
            throw RFBError.unsupportedPixelFormat(requested)
        }
        state.lock()
        pixelFormat = requested
        state.unlock()
    }

    private func handleSetEncodings() throws {
        _ = try socket.readExact(1)
        let countBytes = try socket.readExact(2)
        let count = Int(UInt16.be(countBytes[0], countBytes[1]))
        let bytes = try socket.readExact(count * 4)
        let encodings = stride(from: 0, to: bytes.count, by: 4).map { offset in
            Int32(bitPattern: UInt32.be(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]))
        }
        let capabilities = RFBClientCapabilities(encodings: encodings)
        state.lock()
        clientCapabilities = capabilities
        if capture.includesCursor {
            pendingCursorEncoding = capabilities.supportsRichCursor ? RFBPseudoEncoding.richCursor
                : (capabilities.supportsXCursor ? RFBPseudoEncoding.xCursor : nil)
            state.signal()
        }
        state.unlock()
        logger.verbose("client capabilities: \(capabilities.summary)")
    }

    private func handleFramebufferUpdateRequestMessage() throws {
        let header = try socket.readExact(9)
        let incremental = header[0] != 0
        let x = Int(UInt16.be(header[1], header[2]))
        let y = Int(UInt16.be(header[3], header[4]))
        let width = Int(UInt16.be(header[5], header[6]))
        let height = Int(UInt16.be(header[7], header[8]))

        state.lock()
        latestUpdateRequest = FramebufferUpdateRequest(
            incremental: incremental,
            rect: Rect(x: x, y: y, width: width, height: height)
        )
        state.signal()
        state.unlock()
    }

    func shutdown() { socket.shutdown() }

    private func startFramebufferWriter() {
        writer.enter()
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            defer { writer.leave() }
            do {
                try framebufferWriterLoop()
            } catch {
                socket.shutdown()
                state.lock()
                writerError = error
                stopped = true
                state.broadcast()
                state.unlock()
            }
        }
    }

    private func framebufferWriterLoop() throws {
        while true {
            state.lock()
            let automaticUpdateDue = appleAutomaticUpdate != nil && Date() >= appleNextPush
            if latestUpdateRequest == nil && activeUpdateRequest == nil && !automaticUpdateDue && writerCommands.isEmpty && pendingCursorEncoding == nil && !stopped {
                // Pasteboard monitoring must keep running without framebuffer requests.
                _ = state.wait(until: Date().addingTimeInterval(0.1))
            }
            if stopped {
                state.unlock()
                return
            }
            let commands = writerCommands
            writerCommands.removeAll(keepingCapacity: true)
            let cursorEncoding = pendingCursorEncoding
            pendingCursorEncoding = nil
            let request: FramebufferUpdateRequest?
            var unsolicited = false
            if let latest = latestUpdateRequest {
                latestUpdateRequest = nil
                activeUpdateRequest = usesAppleClipboard ? nil : latest
                request = latest
            } else if let automatic = appleAutomaticUpdate, Date() >= appleNextPush {
                request = automatic
                unsolicited = true
            } else if let active = activeUpdateRequest {
                request = FramebufferUpdateRequest(incremental: true, rect: active.rect)
            } else {
                request = nil
            }
            state.unlock()

            // Only this thread writes after the handshake. Clipboard cannot split a frame.
            for command in commands {
                try sendWriterCommand(command)
            }
            if let cursorEncoding {
                // A zero-sized cursor hides the viewer's local overlay. The real
                // cursor is already in ScreenCaptureKit's framebuffer pixels.
                try socket.writeAll([0, 0, 0, 1] + [UInt8](repeating: 0, count: 8)
                    + UInt32(bitPattern: cursorEncoding).beBytes)
                logger.verbose("cursor: embedded in framebuffer; viewer overlay hidden")
            }
            try sendClipboardChangeIfNeeded()
            if let request {
                try sendFramebufferUpdate(request, unsolicited: unsolicited)
                if usesAppleClipboard {
                    state.lock()
                    appleNextPush = Date().addingTimeInterval(applePushInterval)
                    state.unlock()
                }
            }
        }
    }

    private func stopFramebufferWriter() {
        state.lock()
        stopped = true
        state.broadcast()
        state.unlock()
        socket.shutdown()
        writer.wait()
    }

    private func sendFramebufferUpdate(_ request: FramebufferUpdateRequest, unsolicited: Bool = false) throws {
        frameHadNetworkStall = false
        throttleFrameRate()
        let frameStarted = Date()
        let measureTimings = logger.isVerbose
        state.lock()
        let allowStaleRetry = !clientCapabilities.isAppleScreenSharingClient
        state.unlock()

        var staleRetries = 0
        var captureDuration = 0.0
        var diffDuration = 0.0
        let prepared: PreparedFramebufferUpdate

        while true {
            let candidate = try prepareFramebufferUpdate(request, measureTimings: measureTimings)
            if measureTimings {
                captureDuration += candidate.captureDuration
                diffDuration += candidate.diffDuration
            }

            let canRetryStaleFrame = candidate.encodeDuration <= minimumFrameInterval * 1.5
            if allowStaleRetry,
               staleRetries < 1,
               canRetryStaleFrame,
               try isStale(candidate.framebuffer) {
                staleRetries += 1
                continue
            }

            prepared = candidate
            break
        }

        if unsolicited && prepared.encodedRects.isEmpty && !prepared.desktopSizeChanged {
            return
        }

        if let transaction = prepared.transaction {
            try commit(transaction)
        }

        if prepared.desktopSizeChanged {
            let header = [0, 0] + UInt16(1).beBytes
            let resizeResponse = desktopSizeResponse(for: prepared.framebuffer)
            try socket.writeAll([header, resizeResponse], onStall: { [self] in
                noteNetworkStall()
            })

            state.lock()
            updatesSent += 1
            bytesSent += header.count + resizeResponse.count
            currentLayout = prepared.framebuffer.layout
            forceFullFramebuffer = true
            networkStallNotifications = 0
            state.unlock()
            return
        }

        let rectCount = prepared.encodedRects.count
        guard rectCount <= Int(UInt16.max) else {
            throw RFBError.protocolError("too many rectangles in framebuffer update")
        }
        let header = [0, 0] + UInt16(rectCount).beBytes
        let writeStarted = DispatchTime.now().uptimeNanoseconds
        var updateChunks = [[UInt8]]()
        updateChunks.reserveCapacity(1 + prepared.encodedRects.count)
        updateChunks.append(header)
        updateChunks.append(contentsOf: prepared.encodedRects)
        try socket.writeAll(updateChunks, onStall: { [self] in
            noteNetworkStall()
        })
        let updateBytes = updateChunks.reduce(0) { $0 + $1.count }
        let writeDuration = elapsedSeconds(since: writeStarted)

        let frameDuration = Date().timeIntervalSince(frameStarted)
        state.lock()
        staleFrameRetries += staleRetries
        updatesSent += 1
        bytesSent += updateBytes
        if measureTimings && (updatesSent == 1 || updatesSent % 60 == 0) {
            let compressionRatio = prepared.payloadBytes > 0
                ? Double(prepared.uncompressedBytes) / Double(prepared.payloadBytes)
                : 0
            logger.verbose(
                "updates=\(updatesSent) encoding=\(prepared.encoding) last_rects=\(prepared.rects.count) " +
                "bytes=\(updateBytes) total_bytes=\(bytesSent) " +
                "changed_pixels=\(prepared.changedPixels) " +
                "raw_bytes=\(prepared.uncompressedBytes) payload_bytes=\(prepared.payloadBytes) " +
                "compression_ratio=\(String(format: "%.2f", compressionRatio)) " +
                "stale_retries=\(staleFrameRetries) network_stalls=\(networkStalls) " +
                "frame_ms=\(Int(frameDuration * 1_000)) " +
                "capture_ms=\(Int(captureDuration * 1_000)) " +
                "diff_ms=\(Int(diffDuration * 1_000)) " +
                "encode_ms=\(Int(prepared.encodeDuration * 1_000)) " +
                "write_ms=\(Int(writeDuration * 1_000))"
            )
        }
        previousFramebuffer = prepared.framebuffer
        currentLayout = prepared.framebuffer.layout
        hasSentFramebufferUpdate = true
        forceFullFramebuffer = false
        networkStallNotifications = 0
        state.unlock()

        let hadNetworkStall = frameHadNetworkStall
        try adaptStreaming(
            frameDuration: frameDuration,
            encodeDuration: prepared.encodeDuration,
            writeDuration: writeDuration,
            encoding: prepared.encoding
        )
        adaptScale(
            frameDuration: frameDuration,
            encodeDuration: prepared.encodeDuration,
            writeDuration: writeDuration,
            staleRetries: staleRetries,
            hadNetworkStall: hadNetworkStall
        )
        adaptFrameRate(frameDuration: frameDuration)

    }

    private func prepareFramebufferUpdate(
        _ request: FramebufferUpdateRequest,
        measureTimings: Bool
    ) throws -> PreparedFramebufferUpdate {
        let captureStarted = measureTimings ? Date() : .distantPast
        let capturedFramebuffer = try capture.capture()
        let scale: CGFloat
        let format: PixelFormat
        let encoding: RFBEncoding
        let previous: Framebuffer?
        let sentBefore: Bool
        let supportsResize: Bool
        let forceFull: Bool
        state.lock()
        scale = CGFloat(adaptiveScale)
        format = pixelFormat
        encoding = selectedEncodingLocked()
        previous = previousFramebuffer
        sentBefore = hasSentFramebufferUpdate
        supportsResize = clientCapabilities.supportsDynamicResize
        let useEncodingTransaction = !clientCapabilities.isAppleScreenSharingClient
        forceFull = forceFullFramebuffer
        state.unlock()

        let framebuffer = try FramebufferResampling.scale(capturedFramebuffer, factor: scale)
        let captureDuration = measureTimings ? Date().timeIntervalSince(captureStarted) : 0
        let framebufferSizeChanged = sentBefore
            && (previous?.width != framebuffer.width || previous?.height != framebuffer.height)
        let resizeUpdate = framebufferSizeChanged && supportsResize && !forceFull
        let requested = framebufferSizeChanged || forceFull
            ? Rect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
            : request.rect
        let shouldDiff = sentBefore && request.incremental && !framebufferSizeChanged && !forceFull
        let diffStarted = logger.isVerbose ? Date() : .distantPast
        let dirtyRects: [Rect]?
        if shouldDiff,
           let previous,
           let sequence = framebuffer.sequence,
           let previousSequence = previous.sequence,
           sequence == previousSequence &+ 1 {
            dirtyRects = framebuffer.dirtyRects
        } else {
            dirtyRects = nil
        }

        let rects: [Rect]
        if resizeUpdate {
            rects = []
        } else if shouldDiff,
           let previous,
           let sequence = framebuffer.sequence,
           previous.sequence == sequence {
            rects = []
        } else {
            let tileSize = RawEncoding.recommendedTileSize(
                requested: requested,
                dirtyRects: dirtyRects
            )
            rects = RawEncoding.rectangles(
                current: framebuffer,
                previous: previous,
                requested: requested,
                incremental: shouldDiff,
                dirtyRects: dirtyRects,
                tileSize: tileSize
            )
        }
        let diffDuration = logger.isVerbose ? Date().timeIntervalSince(diffStarted) : 0
        let transaction: EncodingTransaction?
        if resizeUpdate {
            transaction = nil
        } else if useEncodingTransaction {
            switch encoding {
            case .zlib:
                transaction = .zlib(try zlibEncoder.beginTransaction())
            case .zrle:
                transaction = .zrle(try zrleEncoder.beginTransaction())
            case .raw:
                transaction = nil
            }
        } else {
            transaction = nil
        }

        var encodedRects: [[UInt8]] = []
        encodedRects.reserveCapacity(rects.count)
        var encodeDuration = 0.0
        var changedPixels = 0
        var uncompressedBytes = 0
        var payloadBytes = 0

        for rect in rects {
            let encodeStarted = DispatchTime.now().uptimeNanoseconds
            let payload: [UInt8]
            let encodingBytes = UInt32(bitPattern: encoding.rawValue).beBytes
            switch encoding {
            case .zrle:
                if case .zrle(let transaction) = transaction {
                    payload = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
                } else {
                    payload = try zrleEncoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
                }
            case .zlib:
                if case .zlib(let transaction) = transaction {
                    payload = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
                } else {
                    payload = try zlibEncoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
                }
            case .raw:
                payload = try RawEncoding.encode(rect: rect, framebuffer: framebuffer, pixelFormat: format)
            }
            encodeDuration += elapsedSeconds(since: encodeStarted)
            changedPixels += rect.width * rect.height
            uncompressedBytes += rect.width * rect.height * format.cPixelByteCount
            let encodedPayloadBytes: Int
            switch encoding {
            case .zlib, .zrle:
                encodedPayloadBytes = max(0, payload.count - 4)
            case .raw:
                encodedPayloadBytes = payload.count
            }
            payloadBytes += encodedPayloadBytes

            var rectResponse: [UInt8] = []
            rectResponse.reserveCapacity(12 + payload.count)
            rectResponse += UInt16(rect.x).beBytes
            rectResponse += UInt16(rect.y).beBytes
            rectResponse += UInt16(rect.width).beBytes
            rectResponse += UInt16(rect.height).beBytes
            rectResponse += encodingBytes
            rectResponse += payload
            encodedRects.append(rectResponse)
        }

        return PreparedFramebufferUpdate(
            framebuffer: framebuffer,
            encoding: encoding,
            rects: rects,
            encodedRects: encodedRects,
            desktopSizeChanged: resizeUpdate,
            changedPixels: changedPixels,
            uncompressedBytes: uncompressedBytes,
            payloadBytes: payloadBytes,
            captureDuration: captureDuration,
            diffDuration: diffDuration,
            encodeDuration: encodeDuration,
            transaction: transaction
        )
    }

    private func isStale(_ framebuffer: Framebuffer) throws -> Bool {
        guard let sequence = framebuffer.sequence else {
            return false
        }
        let latestSequence: UInt64?
        if let sequenceSource = capture as? FramebufferSequenceSource {
            latestSequence = try sequenceSource.currentSequence()
        } else {
            latestSequence = try capture.capture().sequence
        }
        guard let latestSequence else {
            return false
        }
        return latestSequence != sequence
    }

    private func commit(_ transaction: EncodingTransaction) throws {
        switch transaction {
        case .zlib(let transaction):
            try zlibEncoder.commit(transaction)
        case .zrle(let transaction):
            try zrleEncoder.commit(transaction)
        }
    }

    private func desktopSizeResponse(for framebuffer: Framebuffer) -> [UInt8] {
        [0, 0]
            + UInt16(framebuffer.width).beBytes
            + UInt16(framebuffer.height).beBytes
            + UInt32(bitPattern: RFBPseudoEncoding.desktopSize).beBytes
    }

    private func consumeWriterError() -> Error? {
        state.lock()
        defer { state.unlock() }
        let error = writerError
        writerError = nil
        return error
    }

    private func selectedEncoding() -> RFBEncoding {
        state.lock()
        defer { state.unlock() }
        return selectedEncodingLocked()
    }

    private func selectedEncodingLocked() -> RFBEncoding {
        switch encodingPreference {
        case .raw:
            return .raw
        case .zrle:
            return clientCapabilities.supportsZRLE ? .zrle : .raw
        case .zlib:
            return clientCapabilities.supportsZlib ? .zlib : .raw
        case .auto:
            if clientCapabilities.isAppleScreenSharingClient, clientCapabilities.supportsZlib {
                return .zlib
            }
            if clientCapabilities.supportsZRLE {
                return .zrle
            }
            return clientCapabilities.supportsZlib ? .zlib : .raw
        }
    }

    private func throttleFrameRate() {
        let elapsed = Date().timeIntervalSince(lastFramebufferUpdate)
        if elapsed < frameInterval {
            usleep(useconds_t((frameInterval - elapsed) * 1_000_000))
        }
        lastFramebufferUpdate = Date()
    }

    private func adaptStreaming(
        frameDuration: TimeInterval,
        encodeDuration: TimeInterval,
        writeDuration: TimeInterval,
        encoding: RFBEncoding
    ) throws {
        guard adaptiveStreaming else {
            return
        }

        let target = frameInterval
        guard encodeDuration > 0 else {
            return
        }
        guard frameDuration > target * 1.25 else {
            return
        }

        if encodeDuration >= writeDuration {
            try setCompressionLevel(1, for: encoding)
        } else {
            try setCompressionLevel(3, for: encoding)
        }
    }

    private func adaptScale(
        frameDuration: TimeInterval,
        encodeDuration: TimeInterval,
        writeDuration: TimeInterval,
        staleRetries: Int,
        hadNetworkStall: Bool
    ) {
        guard adaptiveStreaming,
              supportsDynamicResize(),
              updatesSent > 3 else {
            return
        }

        guard let scale = adaptiveScaleController.update(
            frameDuration: frameDuration,
            encodeDuration: encodeDuration,
            writeDuration: writeDuration,
            frameInterval: frameInterval,
            minimumFrameInterval: minimumFrameInterval,
            staleRetries: staleRetries,
            hadNetworkStall: hadNetworkStall
        ) else {
            return
        }

        adaptiveScale = scale
        logger.verbose("adaptive scale changed to \(String(format: "%.2f", scale))")
    }

    private func adaptFrameRate(frameDuration: TimeInterval) {
        guard adaptiveFrameRate else {
            return
        }

        guard let frameRate = adaptiveFrameRateController.update(frameDuration: frameDuration) else {
            return
        }

        frameInterval = 1.0 / Double(frameRate)
        updateCaptureRateIfSafe(frameRate)
        logger.verbose("adaptive fps changed to \(frameRate)")
    }

    private func noteNetworkStall() {
        frameHadNetworkStall = true
        networkStalls += 1
        guard adaptiveFrameRate else {
            return
        }

        networkStallNotifications += 1
        guard networkStallNotifications >= 2 else {
            return
        }
        networkStallNotifications = 0
        guard let frameRate = adaptiveFrameRateController.reduceForBackpressure() else {
            return
        }

        frameInterval = 1.0 / Double(frameRate)
        updateCaptureRateIfSafe(frameRate)
        logger.verbose("adaptive fps changed to \(frameRate) due to network backpressure")
    }

    private func updateCaptureRateIfSafe(_ frameRate: Int) {
        state.lock()
        let reconfigureCapture = !clientCapabilities.isAppleScreenSharingClient
        let captureRateConsumer = self.captureRateConsumer
        state.unlock()

        guard let captureRateConsumer else {
            return
        }
        (capture as? CaptureFrameRateController)?.updateCaptureRate(
            frameRate,
            consumer: captureRateConsumer,
            reconfigureCapture: reconfigureCapture
        )
    }

    private func elapsedSeconds(since start: UInt64) -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private func setCompressionLevel(_ level: Int32, for encoding: RFBEncoding) throws {
        switch encoding {
        case .zrle:
            try zrleEncoder.setCompressionLevel(level)
        case .zlib:
            try zlibEncoder.setCompressionLevel(level)
        case .raw:
            return
        }
    }

    private func supportsDynamicResize() -> Bool {
        state.lock()
        defer { state.unlock() }
        return clientCapabilities.supportsDynamicResize
    }

    private func handleKeyEvent() throws {
        let bytes = try socket.readExact(7)
        let down = bytes[0] != 0
        let keysym = UInt32.be(bytes[3], bytes[4], bytes[5], bytes[6])
        state.lock()
        let mapAltToCommand = clientCapabilities.isAppleScreenSharingClient
        let allowInput = !usesAppleClipboard || appleControlMode
        state.unlock()
        guard allowInput else { return }
        requestCaptureRecoveryAfterInput()
        input.key(down: down, keysym: keysym, mapAltToCommand: mapAltToCommand)
    }

    private func handlePointerEvent() throws {
        let bytes = try socket.readExact(5)
        let mask = bytes[0]
        let x = UInt16.be(bytes[1], bytes[2])
        let y = UInt16.be(bytes[3], bytes[4])
        state.lock()
        let layout = currentLayout
        let allowInput = !usesAppleClipboard || appleControlMode
        state.unlock()
        guard allowInput else { return }
        requestCaptureRecoveryAfterInput()
        let standardMask = usesAppleClipboard ? AppleRFB.standardButtonMask(mask) : mask
        input.pointer(buttonMask: standardMask, x: x, y: y, layout: layout)
    }

    private func requestCaptureRecoveryAfterInput() {
        (capture as? InputRecoverySource)?.requestRecoveryAfterInput()
    }

    private func handleClientCutText() throws {
        _ = try socket.readExact(3)
        let lengthBytes = try socket.readExact(4)
        let length = Int(UInt32.be(lengthBytes[0], lengthBytes[1], lengthBytes[2], lengthBytes[3]))
        guard length <= AppleClipboard.maxArchiveBytes else {
            throw RFBError.protocolError("VNC clipboard exceeds the 16 MiB limit")
        }
        let bytes = try socket.readExact(length)
        if clipboardSync && !usesAppleClipboard {
            let text = String(decoding: bytes, as: UTF8.self)
            clipboard.setRemoteText(text)
        }
    }

    private func sendServerCutText(_ text: String) throws {
        let payload = Array(text.utf8)
        guard payload.count <= AppleClipboard.maxArchiveBytes else {
            logger.warning("skipping VNC clipboard larger than 16 MiB")
            return
        }
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += UInt32(payload.count).beBytes
        bytes += payload
        try socket.writeAll(bytes)
    }

    private func requireAppleClipboard() throws {
        guard usesAppleClipboard else {
            throw RFBError.protocolError("Apple message without extended ServerInit negotiation")
        }
    }

    private func enqueueWriterCommand(_ command: WriterCommand) throws {
        state.lock()
        defer { state.unlock() }
        guard writerCommands.count < 64 else {
            throw RFBError.protocolError("too many pending Apple clipboard requests")
        }
        writerCommands.append(command)
        state.signal()
    }

    private func handleAppleViewerInfo() throws {
        let header = try socket.readExact(3)
        let count = Int(UInt16.be(header[1], header[2]))
        guard count <= AppleRFB.maxViewerInfoBytes else {
            throw RFBError.protocolError("Apple ViewerInfo is too large")
        }
        let capabilities = try AppleRFB.viewerCapabilities(body: socket.readExact(count))
        state.lock()
        appleViewerCapabilities = capabilities
        state.unlock()
        logger.verbose("Apple ViewerInfo: status=\(AppleRFB.supports(0x14, bitmap: capabilities)) clipboard=\(AppleRFB.supports(0x1f, bitmap: capabilities))")
    }

    private func handleAppleAutoFramebufferUpdate() throws {
        let bytes = try socket.readExact(15)
        guard UInt16.be(bytes[1], bytes[2]) == 1 else {
            throw RFBError.protocolError("unsupported Apple AutoFrameBufferUpdate version")
        }
        let interval = UInt32.be(bytes[3], bytes[4], bytes[5], bytes[6])
        let rect = Rect(x: Int(UInt16.be(bytes[7], bytes[8])),
                        y: Int(UInt16.be(bytes[9], bytes[10])),
                        width: Int(UInt16.be(bytes[11], bytes[12])),
                        height: Int(UInt16.be(bytes[13], bytes[14])))
        state.lock()
        appleAutomaticUpdate = interval == UInt32.max || rect.width == 0 || rect.height == 0
            ? nil : FramebufferUpdateRequest(incremental: true, rect: rect)
        applePushInterval = interval == UInt32.max ? 0 : Double(interval) / 1_000_000
        appleNextPush = .distantPast
        state.signal()
        state.unlock()
        logger.verbose("Apple AutoFrameBufferUpdate: interval_us=\(interval)")
    }

    private func handleAppleSetMode() throws {
        let bytes = try socket.readExact(3)
        let mode = UInt16.be(bytes[1], bytes[2])
        guard mode <= 1 else {
            throw RFBError.protocolError("Apple exclusive control mode is not supported")
        }
        state.lock()
        appleControlMode = mode == 1
        let supportsStatus = AppleRFB.supports(0x14, bitmap: appleViewerCapabilities)
        state.unlock()
        if mode == 0 { input.releaseKeys() }
        if supportsStatus { try enqueueWriterCommand(.status(mode == 1 ? 9 : 10)) }
        logger.verbose("Apple SetMode: \(mode == 1 ? "control" : "observe")")
    }

    private func handleAppleAutoPasteboard() throws {
        let bytes = try socket.readExact(7)
        let command = UInt16.be(bytes[1], bytes[2])
        guard command == 1 || command == 2 else { return }
        state.lock()
        appleAutoPasteboard = command == 1
        appleInitialClipboardNotification = command == 1
        appleClipboardGeneration &+= 1
        state.signal()
        state.unlock()
        logger.verbose("Apple AutoPasteboard: \(command == 1 ? "started" : "stopped")")
    }

    private func handleAppleClipboardFetch() throws {
        let bytes = try socket.readExact(7)
        let requestID = UInt32.be(bytes[3], bytes[4], bytes[5], bytes[6])
        state.lock()
        let allowed = appleControlMode
        let promises = appleAutoPasteboard && bytes[0] & 1 != 0
        state.unlock()
        if allowed {
            try enqueueWriterCommand(.clipboardFetch(requestID: requestID, promises: promises))
        }
    }

    private func handleAppleClipboardSend() throws {
        let header = try AppleClipboard.Header(bytes: socket.readExact(15))
        let compressed = try socket.readExact(header.compressedSize)
        state.lock()
        let allowed = appleControlMode
        let canRequestPromises = appleAutoPasteboard
            && AppleRFB.supports(0x14, bitmap: appleViewerCapabilities)
        state.unlock()
        guard allowed else { return }
        switch try AppleClipboard.decode(header: header, compressed: compressed) {
        case .text(let text):
            clipboard.setRemoteText(text)
            state.lock()
            appleClipboardGeneration &+= 1
            // Applying a remote change must not trigger an initial-change echo.
            appleInitialClipboardNotification = false
            state.unlock()
            logger.verbose("Apple ClipboardSend received: \(text.utf8.count) text bytes")
        case .promisedText:
            if header.promises && canRequestPromises {
                try enqueueWriterCommand(.status(3))
            }
        case .noText:
            logger.verbose("Apple ClipboardSend ignored: no supported text flavor")
        }
    }

    private func sendWriterCommand(_ command: WriterCommand) throws {
        switch command {
        case .status(let value):
            try socket.writeAll(AppleRFB.status(value))
        case .clipboardFetch(let requestID, let promises):
            state.lock()
            let generation = appleClipboardGeneration
            let allowed = appleControlMode
            state.unlock()
            guard allowed else { return }
            let text: String
            if !promises, let saved = applePromisedText, saved.generation == generation {
                text = saved.text
            } else {
                text = clipboard.currentText()
            }
            applePromisedText = promises ? (generation, text) : nil
            try socket.writeAll(AppleClipboard.message(text: text, requestID: requestID, promises: promises))
            logger.verbose("Apple ClipboardSend sent: request=\(requestID) promises=\(promises) text_bytes=\(text.utf8.count)")
        }
    }

    private func sendClipboardChangeIfNeeded() throws {
        guard clipboardSync else { return }
        if !usesAppleClipboard {
            if let text = clipboard.localTextIfChanged() { try sendServerCutText(text) }
            return
        }
        state.lock()
        let watching = appleControlMode && appleAutoPasteboard
            && AppleRFB.supports(0x14, bitmap: appleViewerCapabilities)
            && AppleRFB.supports(0x1f, bitmap: appleViewerCapabilities)
        let initial = appleInitialClipboardNotification
        if watching { appleInitialClipboardNotification = false }
        state.unlock()
        guard watching else { return }
        let changed = clipboard.localTextIfChanged() != nil
        if changed || initial {
            applePromisedText = nil
            try socket.writeAll(AppleRFB.status(2))
            logger.verbose("Apple MiscStatus: pasteboard changed")
        }
    }
}
