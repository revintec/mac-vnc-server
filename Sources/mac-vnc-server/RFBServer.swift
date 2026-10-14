import Darwin
import Foundation

struct ServerConfig: Codable, Sendable {
    let bindAddress: String
    let port: UInt16
    let fps: Int
    let scale: Double
    let encodingPreference: EncodingPreference
    let displaySelection: DisplaySelection
    let verbose: Bool
    var clipboardSync: Bool
    let adaptiveStreaming: Bool
    let adaptiveFrameRate: Bool
    var fileTransfer = true
    var cursorMode: CursorMode = .auto
    var allowEncryption = false
    var zlibConfiguration = ZlibConfiguration()
    var transferOptions = TransferStore.Options()
    var transferDirectoryIsExplicit = false
}

enum DisplaySelection: Equatable, Codable, Sendable {
    case all
    case display(Int)
}

enum EncodingPreference: String, Codable, Sendable {
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
    static let continuousUpdates: Int32 = -313
    static let fence: Int32 = -312
    static let extendedDesktopSize: Int32 = -308
}

struct RFBClientCapabilities: Equatable {
    let advertisedEncodings: [Int32]
    let supportsRaw: Bool
    let supportsContinuousUpdates: Bool
    let supportsFence: Bool
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
        supportsContinuousUpdates = encodings.contains(RFBPseudoEncoding.continuousUpdates)
        supportsFence = encodings.contains(RFBPseudoEncoding.fence)
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
            supportsContinuousUpdates ? "continuous-updates" : nil,
            supportsFence ? "fence" : nil,
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
    private let transferInbox: TransferInbox?
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
        messageTimeout: TimeInterval = 5,
        transferInbox: TransferInbox? = nil
    ) {
        self.config = config
        self.capture = capture
        self.makeInput = makeInput
        self.makeClipboard = makeClipboard
        self.logger = logger
        self.transferInbox = transferInbox
        self.maximumClients = maximumClients
        self.handshakeTimeout = handshakeTimeout
        self.messageTimeout = messageTimeout
    }

    var activeClientCount: Int { lock.withLock { clients.count } }
    func waitForClients() { workers.wait() }

    /// Takes an already-connected socket. Account workers enter here after the
    /// listener has authenticated and passed ownership through SCM_RIGHTS.
    @discardableResult
    func serve(client: ClientSocket, admission: SessionAdmission) -> Bool {
        let id = ObjectIdentifier(client)
        let admitted = lock.withLock {
            guard !stopped, clients.count < maximumClients else { return false }
            clients[id] = client
            return true
        }
        guard admitted else {
            try? AccountHandshake.reject(socket: client, version: admission.version)
            client.shutdown()
            logger.warning("connection rejected: server stopping or client limit reached")
            return false
        }
        do {
            // A peer closing during socket setup must only fail its own session.
            try client.configureTCP()
            let session = try RFBClientSession(
                socket: client, fps: config.fps,
                encodingPreference: config.encodingPreference, capture: capture,
                input: makeInput(), clipboard: makeClipboard(),
                clipboardSync: config.clipboardSync, adaptiveStreaming: config.adaptiveStreaming,
                adaptiveFrameRate: config.adaptiveFrameRate, logger: logger,
                handshakeTimeout: handshakeTimeout,
                messageTimeout: messageTimeout, fileTransfer: config.fileTransfer,
                allowEncryption: config.allowEncryption, zlibConfiguration: config.zlibConfiguration,
                transferInbox: transferInbox
            )
            workers.enter()
            DispatchQueue.global(qos: .userInteractive).async { [self] in
                defer {
                    session.shutdown()
                    lock.withLock { clients[id] = nil }
                    workers.leave()
                }
                do { try session.run(admission: admission) }
                catch { logger.warning("client disconnected: \(error.localizedDescription)") }
            }
            return true
        } catch {
            try? AccountHandshake.reject(socket: client, version: admission.version)
            client.shutdown()
            lock.withLock { clients[id] = nil }
            logger.warning("could not start client: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            for client in clients.values { client.shutdown() }
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
        let sourceLayout: VirtualDisplayLayout
        let encoding: RFBEncoding
        let pixelFormat: PixelFormat
        let rects: [Rect]
        let coverage: Rect
        let copiedPixels: Int
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
    private let minimumFrameInterval: TimeInterval
    private var frameInterval: TimeInterval
    private let encodingPreference: EncodingPreference
    private let capture: FramebufferSource
    private let input: InputController
    private let clipboard: ClipboardBridge
    private let clipboardSync: Bool
    private let fileTransferEnabled: Bool
    private let allowEncryption: Bool
    private let transferInbox: TransferInbox?
    private var fileTransfer: MacFileTransfer?
    private let adaptiveStreaming: Bool
    private let adaptiveFrameRate: Bool
    private let logger: ServerLogger
    private var pixelFormat = PixelFormat.serverDefault
    private var clientCapabilities = RFBClientCapabilities(encodings: [RFBEncoding.raw.rawValue])
    private var previousFramebuffer: Framebuffer?
    private var previousCoverage: Rect?
    private var currentLayout = VirtualDisplayLayout.empty
    private var lastCursorImage: CursorImage?
    private var lastCursorFormat: PixelFormat?
    private var pacer = FramePacer()
    private let wake = FrameWakeSignal()
    private var scaledCache = ScaledFramebufferCache()
    private var hasSentFramebufferUpdate = false
    private let zrleEncoder: ZRLEEncoder
    private let zlibEncoder: ZlibEncoder
    private let state = NSCondition()
    private var stopped = false
    private var latestUpdateRequest: FramebufferUpdateRequest?
    private var updateRequestsReceived = 0
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
    // Negotiated once before the writer starts. Shared Apple state uses `state`.
    private var usesAppleExtensions = false
    private var appleViewerCapabilities: [UInt8] = []
    private var appleControlMode = true
    // Reader-owned: established by authentication, then replaced on each rekey.
    // Classic VNC authentication does not establish an encryption key.
    private var appleWrappingKey: [UInt8]?
    private var appleEncryptedInputReceived = false
    private var appleAutoPasteboard = false
    private var appleClipboardNoticeAfter: Date?
    private var appleClipboardNoticeLogged = false
    private var appleInitialClipboardNotification = false
    private var appleClipboardGeneration: UInt64 = 0
    private var appleAutomaticUpdate: FramebufferUpdateRequest?
    private var applePushInterval: TimeInterval = 0
    private var appleNextPush: UInt64 = 0
    private var continuousUpdate: FramebufferUpdateRequest?
    private var announcedContinuous = false
    private var announcedFence = false
    private var fenceCounter: UInt64 = 0
    private var outstandingFences: Set<UInt64> = []
    // Accessed only by the writer; retained between a promises-only and a full fetch.
    private var applePromisedContent: (generation: UInt64, content: ClipboardContent)?
    private var appleIncomingPromise = false
    private var appleCancelledPromise = false
    private var appleDeferredFetches: [WriterCommand] = []
    private static let maxClassicClipboardBytes = 16 * 1_024 * 1_024

    private enum WriterCommand {
        case protocolMessage([UInt8])
        case barrier([UInt8], DispatchSemaphore)
        case clipboardFetch(requestID: UInt32, promises: Bool)
        case clipboardReceived(ClipboardContent, promises: Bool, canRequest: Bool)
        case clipboardReset
        case rekey(AppleEncryption.Keys, wrappingKey: [UInt8], level: UInt16, completion: DispatchSemaphore)
        case fileData([UInt8], DispatchSemaphore)
    }
    private var writerCommands: [WriterCommand] = []
    private var pendingCursorEncoding: Int32?
    private var pendingAppleDisplayInfo = false
    private var pendingAppleFramebufferScale: Double?
    // Applied only by the writer, so metadata and pixels change together.
    private var appleFramebufferScale = 1.0

    init(
        socket: ClientSocket,
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
        messageTimeout: TimeInterval = 5,
        fileTransfer: Bool = false,
        allowEncryption: Bool = true,
        zlibConfiguration: ZlibConfiguration = .init(),
        transferInbox: TransferInbox? = nil
    ) throws {
        self.transferInbox = transferInbox
        self.handshakeTimeout = handshakeTimeout
        self.messageTimeout = messageTimeout
        self.socket = socket
        minimumFrameInterval = 1.0 / Double(fps)
        frameInterval = minimumFrameInterval
        self.encodingPreference = encodingPreference
        self.capture = capture
        self.input = input
        self.clipboard = clipboard
        self.clipboardSync = clipboardSync
        fileTransferEnabled = fileTransfer && NativeTransferProcess.available
        self.allowEncryption = allowEncryption
        self.adaptiveStreaming = adaptiveStreaming
        self.adaptiveFrameRate = adaptiveFrameRate
        self.logger = logger
        adaptiveFrameRateController = AdaptiveFrameRateController(startingFrameRate: fps)
        zrleEncoder = try ZRLEEncoder(configuration: zlibConfiguration)
        zlibEncoder = try ZlibEncoder(configuration: zlibConfiguration)
    }

    func run(admission: SessionAdmission) throws {
        let initialFrame = try capture.capture()
        currentLayout = initialFrame.layout
        previousFramebuffer = initialFrame

        try socket.withReadTimeout(handshakeTimeout, operation: "RFB handshake") {
            appleWrappingKey = admission.wrappingKey
            try socket.writeAll(UInt32(0).beBytes)
            try initializeClient(versionText: admission.version, initialFrame: initialFrame)
        }
        let captureRateConsumer = ObjectIdentifier(self)
        self.captureRateConsumer = captureRateConsumer
        (capture as? CaptureFrameRateController)?.registerCaptureRateConsumer(
            captureRateConsumer,
            fps: Int((1.0 / minimumFrameInterval).rounded())
        )
        if fileTransferEnabled && usesAppleExtensions {
            fileTransfer = MacFileTransfer(logger: logger, input: input, inbox: transferInbox) { [weak self] bytes in
                guard let self else { throw RFBError.socketError("file-transfer session closed") }
                let completion = DispatchSemaphore(value: 0)
                try self.enqueueWriterCommand(.fileData(bytes, completion))
                while completion.wait(timeout: .now() + 0.25) == .timedOut {
                    if self.state.withLock({ self.stopped }) {
                        throw RFBError.socketError("file-transfer session closed")
                    }
                }
            }
        }
        let observer = capture.frameChanges?.observe { [weak self] in self?.wake.signal() }
        startFramebufferWriter()
        defer {
            if let observer { capture.frameChanges?.remove(observer) }
            fileTransfer?.stop()
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
        case 150:
            try handleContinuousUpdates()
        case 248:
            try handleFence()
        case 4:
            try handleKeyEvent()
        case 5:
            try handlePointerEvent()
        case 6:
            try handleClientCutText()
        case 0x08:
            try requireAppleExtensions()
            try handleAppleSetServerScaling()
        case 0x09:
            try requireAppleExtensions()
            try handleAppleAutoFramebufferUpdate()
        case 0x0a:
            try requireAppleExtensions()
            try handleAppleSetMode()
        case 0x0b:
            try requireAppleExtensions()
            try handleAppleClipboardFetch()
        case 0x10:
            try requireAppleExtensions()
            try handleAppleEncryptedInput()
        case 0x12:
            try requireAppleExtensions()
            try handleAppleSetEncryption()
        case 0x0e:
            try requireAppleExtensions()
            let bytes = try socket.readExact(7)
            let sessionID = UInt32.be(bytes[3], bytes[4], bytes[5], bytes[6])
            logger.verbose("Apple DragEvent received: session=\(sessionID) \(appleFileTransferDiagnostic) [client_fd=\(socket.fd)]")
            if appleFileTransferAllowed {
                try fileTransfer?.startDrag(sessionID: sessionID, compressed: [], archiveSize: 0)
            }
        case 0x20:
            try requireAppleExtensions()
            let bytes = try socket.readExact(15)
            let sessionID = UInt32.be(bytes[3], bytes[4], bytes[5], bytes[6])
            let size = Int(UInt32.be(bytes[7], bytes[8], bytes[9], bytes[10]))
            let compressedSize = Int(UInt32.be(bytes[11], bytes[12], bytes[13], bytes[14]))
            guard size <= AppleFileTransfer.maxDragBytes, compressedSize <= AppleFileTransfer.maxDragBytes else {
                throw RFBError.protocolError("Apple drag exceeds 5 MiB")
            }
            let compressed = try socket.readExact(compressedSize)
            logger.verbose("Apple DropEvent received: session=\(sessionID) archive_bytes=\(size) compressed_bytes=\(compressedSize) \(appleFileTransferDiagnostic) [client_fd=\(socket.fd)]")
            if compressed.isEmpty { fileTransfer?.cancelDrag() }
            else if appleFileTransferAllowed {
                try fileTransfer?.startDrag(sessionID: sessionID, compressed: compressed, archiveSize: size)
            }
        case 0x22:
            try requireAppleExtensions()
            let bytes = try socket.readExact(5)
            let size = Int(UInt32.be(bytes[1], bytes[2], bytes[3], bytes[4]))
            guard size <= AppleFileTransfer.maxMessageBytes else {
                throw RFBError.protocolError("Apple file-copy record exceeds 1 MiB")
            }
            let message = try AppleFileTransfer.Message(body: socket.readExact(size))
            if appleFileTransferAllowed { try fileTransfer?.handle(message) }
            else { logger.verbose("Apple FileCopy ignored: command=\(message.command) session=\(message.sessionID) \(appleFileTransferDiagnostic) [client_fd=\(socket.fd)]") }
        case 0x15:
            try requireAppleExtensions()
            try handleAppleAutoPasteboard()
        case 0x1f:
            try requireAppleExtensions()
            try handleAppleClipboardSend()
        case 0x21:
            try requireAppleExtensions()
            try handleAppleViewerInfo()
        default:
            throw RFBError.protocolError("unsupported client message \(messageType)")
        }
    }

    private func initializeClient(versionText: String, initialFrame: Framebuffer) throws {
        let clientInit = try socket.readExact(1)[0]
        logger.verbose("RFB handshake: ClientInit=\(clientInit)")
        // Always share the desktop, even when ClientInit requests an exclusive session.
        // A newly connected viewer must never evict an existing viewer.
        usesAppleExtensions = versionText == AppleRFB.version && clientInit & 0x80 != 0
        // Apple's viewer commonly sends 0xc1. The optional session-selection
        // request is declined by leaving server flag 0x04 clear, not by disconnecting.
        try sendServerInit(framebuffer: initialFrame)
        logger.info("client connected: \(versionText.trimmingCharacters(in: .whitespacesAndNewlines)), framebuffer \(initialFrame.width)x\(initialFrame.height), clipboard=\(clipboardSync ? (usesAppleExtensions ? "apple" : "classic") : "off")")
    }

    private func desktopHostname() -> String {
        // Foundation's ProcessInfo.hostName may resolve to the Bonjour name.
        // Read the kernel hostname instead, matching `hostname -s` without DNS.
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count) == 0 else { return "localhost" }
        let hostname = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return hostname.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first.flatMap { $0.isEmpty ? nil : String($0) } ?? "localhost"
    }

    private func sendServerInit(framebuffer: Framebuffer) throws {
        var bytes: [UInt8] = []
        bytes += UInt16(framebuffer.width).beBytes
        bytes += UInt16(framebuffer.height).beBytes
        bytes += PixelFormat.serverDefault.bytes
        let hostname = desktopHostname()
        let name = usesAppleExtensions
            ? AppleRFB.desktopName(hostname, fileTransfer: fileTransferEnabled, allowEncryptedInput: appleWrappingKey != nil)
            : Array(hostname.utf8)
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
        logger.verbose("client pixel format: bpp=\(requested.bitsPerPixel) depth=\(requested.depth) big_endian=\(requested.bigEndian) rgb_max=\(requested.redMax),\(requested.greenMax),\(requested.blueMax) rgb_shift=\(requested.redShift),\(requested.greenShift),\(requested.blueShift) [client_fd=\(socket.fd)]")
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
        if !usesAppleExtensions {
            if capabilities.supportsContinuousUpdates && !announcedContinuous {
                announcedContinuous = true
                writerCommands.append(.protocolMessage([150]))
            }
            if capabilities.supportsFence && !announcedFence {
                announcedFence = true
                writerCommands.append(.protocolMessage(Self.fenceMessage(flags: 0x80000000, payload: [])))
            }
            if !capabilities.supportsContinuousUpdates { continuousUpdate = nil }
            if !capabilities.supportsFence { outstandingFences.removeAll() }
            wake.signal()
        }
        pendingAppleDisplayInfo = usesAppleExtensions && fileTransferEnabled
            && AppleRFB.preferredDisplayEncoding(in: encodings) != nil
        if pendingAppleDisplayInfo { state.signal(); wake.signal() }
        if capture.includesCursor || capture.cursorSnapshot != nil {
            pendingCursorEncoding = capabilities.supportsRichCursor ? RFBPseudoEncoding.richCursor
                : (capabilities.supportsXCursor ? RFBPseudoEncoding.xCursor : nil)
            state.signal(); wake.signal()
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
        if continuousUpdate != nil && incremental {
            state.unlock()
            return
        }
        var pending = FramebufferUpdateRequest(incremental: incremental,
            rect: Rect(x: x, y: y, width: width, height: height))
        // A newer request must not discard an outstanding refresh or region.
        for old in [activeUpdateRequest, latestUpdateRequest].compactMap({ $0 }) {
            let x0 = min(old.rect.x, pending.rect.x), y0 = min(old.rect.y, pending.rect.y)
            let x1 = max(old.rect.x + old.rect.width, pending.rect.x + pending.rect.width)
            let y1 = max(old.rect.y + old.rect.height, pending.rect.y + pending.rect.height)
            pending = FramebufferUpdateRequest(incremental: old.incremental && pending.incremental,
                rect: Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
        latestUpdateRequest = pending
        updateRequestsReceived += 1
        let requestNumber = updateRequestsReceived
        let fullRefresh = forceFullFramebuffer
        state.signal(); wake.signal()
        state.unlock()
        if requestNumber <= 8 || !incremental || fullRefresh {
            logger.verbose("FramebufferUpdateRequest: number=\(requestNumber) incremental=\(incremental) rect=\(x),\(y) \(width)x\(height) full_refresh=\(fullRefresh) [client_fd=\(socket.fd)]")
        }
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
                state.broadcast(); wake.signal()
                state.unlock()
            }
        }
    }

    private func framebufferWriterLoop() throws {
        while true {
            state.lock()
            let automaticUpdateDue = (appleAutomaticUpdate != nil && DispatchTime.now().uptimeNanoseconds >= appleNextPush) || continuousUpdate != nil
            if latestUpdateRequest == nil && activeUpdateRequest == nil && !automaticUpdateDue && writerCommands.isEmpty && !pendingAppleDisplayInfo && pendingAppleFramebufferScale == nil && !stopped {
                // Pasteboard monitoring must keep running without framebuffer requests.
                state.unlock()
                wake.wait(until: .now() + 0.1)
                state.lock()
            }
            if stopped {
                state.unlock()
                return
            }
            let commands = writerCommands
            writerCommands.removeAll(keepingCapacity: true)
            let displayInfo = pendingAppleDisplayInfo
            pendingAppleDisplayInfo = false
            let requestedScale = pendingAppleFramebufferScale
            pendingAppleFramebufferScale = nil
            let request: FramebufferUpdateRequest?
            var unsolicited = false
            if displayInfo || requestedScale != nil {
                request = nil
            } else if let latest = latestUpdateRequest {
                latestUpdateRequest = nil
                activeUpdateRequest = latest
                request = latest
            } else if let continuous = continuousUpdate, outstandingFences.count < 3 {
                request = continuous
                unsolicited = true
            } else if let automatic = appleAutomaticUpdate, DispatchTime.now().uptimeNanoseconds >= appleNextPush {
                request = automatic
                unsolicited = true
            } else if let active = activeUpdateRequest {
                request = active
            } else {
                request = nil
            }
            // An unsolicited empty cursor can make Screen Sharing report
            // "finished connecting" before sessionIsReady restores its mode
            // and clipboard settings. Keep it pending until the viewer asks
            // for pixels, after it has initialized the session.
            let cursorEncoding = request == nil ? nil : pendingCursorEncoding
            if request != nil { pendingCursorEncoding = nil }
            state.unlock()

            // Only this thread writes after the handshake. Clipboard cannot split a frame.
            for command in commands {
                try sendWriterCommand(command)
            }
            if let requestedScale { appleFramebufferScale = requestedScale }
            if displayInfo || requestedScale != nil {
                let captured = try captureClientFramebuffer()
                try sendAppleDisplayInfo(framebuffer: captured.framebuffer, sourceLayout: captured.sourceLayout)
            }
            if let cursorEncoding, capture.includesCursor || cursorEncoding == RFBPseudoEncoding.xCursor {
                // A zero-sized cursor hides the viewer's local overlay when
                // the cursor is captured or composited into the framebuffer.
                try socket.writeAll([0, 0, 0, 1] + [UInt8](repeating: 0, count: 8)
                    + UInt32(bitPattern: cursorEncoding).beBytes)
                logger.verbose("cursor: embedded in framebuffer; viewer overlay hidden")
            }
            try sendClipboardChangeIfNeeded()
            if let request {
                let sent = try sendFramebufferUpdate(request, unsolicited: unsolicited, forceCursor: cursorEncoding != nil)
                if sent && !unsolicited { state.withLock { activeUpdateRequest = nil } }
                if sent && !usesAppleExtensions { try sendFrameFenceIfNeeded() }
                if !sent {
                    // Frame arrivals wake this wait immediately; the short poll
                    // also catches cursor changes and sources without callbacks.
                    wake.wait(until: .now() + min(frameInterval, 1.0 / 30))
                }
                if usesAppleExtensions {
                    state.lock()
                    appleNextPush = DispatchTime.now().uptimeNanoseconds + UInt64(applePushInterval * 1_000_000_000)
                    state.unlock()
                }
            } else {
                wake.wait(until: .now() + 0.033)
            }
        }
    }

    private func stopFramebufferWriter() {
        state.lock()
        stopped = true
        state.broadcast(); wake.signal()
        state.unlock()
        socket.shutdown()
        writer.wait()
    }

    private func sendAppleDisplayInfo(framebuffer: Framebuffer, sourceLayout: VirtualDisplayLayout) throws {
        // Screen Sharing asynchronously installs (and clears) its bitmap after
        // each layout, even at the same size. Like Apple's server, discard old
        // update requests/arming and wait for a fresh request before sending
        // pixels. Reset before the write so a fast reply cannot be lost.
        state.lock()
        guard let encoding = AppleRFB.preferredDisplayEncoding(in: clientCapabilities.advertisedEncodings) else {
            state.unlock()
            return
        }
        latestUpdateRequest = nil
        activeUpdateRequest = nil
        appleAutomaticUpdate = nil
        forceFullFramebuffer = true
        // Remember the advertised dimensions to avoid another layout on the
        // next request. This snapshot is not a valid diff baseline until the
        // forced full refresh has been sent.
        previousFramebuffer = framebuffer
        previousCoverage = nil
        currentLayout = sourceLayout
        state.unlock()
        let message = encoding == AppleRFB.displayLayoutEncoding
            ? AppleRFB.displayLayout(width: framebuffer.width, height: framebuffer.height,
                unscaledWidth: sourceLayout.width, unscaledHeight: sourceLayout.height, scale: appleFramebufferScale)
            : AppleRFB.displayInfo(width: framebuffer.width, height: framebuffer.height,
                unscaledWidth: sourceLayout.width, unscaledHeight: sourceLayout.height)
        try socket.writeAll(message)
        logger.verbose("Apple DisplayInfo sent: encoding=\(encoding) \(framebuffer.width)x\(framebuffer.height) unscaled=\(sourceLayout.width)x\(sourceLayout.height) scale=\(appleFramebufferScale) awaiting_frame_request=true [client_fd=\(socket.fd)]")
    }

    private func captureClientFramebuffer() throws -> (framebuffer: Framebuffer, sourceLayout: VirtualDisplayLayout) {
        let captured = try capture.capture()
        let cursor = !capture.includesCursor && !state.withLock({ usesClientCursorLocked })
            ? capture.cursorSnapshot : nil
        let scale = state.withLock { CGFloat(usesAppleExtensions ? appleFramebufferScale : adaptiveScale) }
        let framebuffer = try scaledCache.frame(captured, factor: scale, rounded: usesAppleExtensions, cursor: cursor)
        return (framebuffer, captured.layout)
    }

    private var usesClientCursorLocked: Bool {
        clientCapabilities.supportsRichCursor && (!usesAppleExtensions || appleControlMode)
    }

    private func sendFramebufferUpdate(_ request: FramebufferUpdateRequest, unsolicited: Bool = false,
                                       forceCursor: Bool = false) throws -> Bool {
        frameHadNetworkStall = false
        try throttleFrameRate()
        let pacingStarted = DispatchTime.now().uptimeNanoseconds
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
            let captureStarted = measureTimings ? Date() : .distantPast
            let captured = try captureClientFramebuffer()
            let capturedDuration = measureTimings ? Date().timeIntervalSince(captureStarted) : 0
            let appleLayoutChanged = usesAppleExtensions && state.withLock {
                AppleRFB.preferredDisplayEncoding(in: clientCapabilities.advertisedEncodings) != nil
                    && (previousFramebuffer?.width != captured.framebuffer.width
                        || previousFramebuffer?.height != captured.framebuffer.height
                        || currentLayout.width != captured.sourceLayout.width
                        || currentLayout.height != captured.sourceLayout.height)
            }
            if appleLayoutChanged {
                // Do this before encoding: an unsent zlib/ZRLE frame must not
                // advance the persistent compression stream.
                try sendAppleDisplayInfo(framebuffer: captured.framebuffer, sourceLayout: captured.sourceLayout)
                return true
            }
            let candidate = try prepareFramebufferUpdate(request, framebuffer: captured.framebuffer,
                sourceLayout: captured.sourceLayout, captureDuration: capturedDuration)
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

        // Include the cursor in a requested update, after display initialization.
        // Sending it during SetEncodings can trigger Screen Sharing's startup race.
        var cursorRectangle: [UInt8]?
        var cursorImage: CursorImage?
        let cursorFormat = prepared.pixelFormat
        if !capture.includesCursor, state.withLock({ clientCapabilities.supportsRichCursor }),
           let cursor = capture.cursorSnapshot {
            // Observers need to see the host's actual cursor position. RichCursor
            // alone conveys the shape, not another user's pointer movement.
            let image = state.withLock({ usesClientCursorLocked })
                ? try cursor.image.scaled(by: prepared.framebuffer.layout.scale) : .hidden
            if forceCursor || image != lastCursorImage || cursorFormat != lastCursorFormat {
                cursorRectangle = try image.richCursorRectangle(format: cursorFormat)
                cursorImage = image
            }
        }
        if (unsolicited || !usesAppleExtensions) && request.incremental && prepared.encodedRects.isEmpty && !prepared.desktopSizeChanged && cursorRectangle == nil {
            return false
        }

        // Empty capture checks must not consume an FPS slot. When the next
        // buffer arrives it can be sent immediately if the deadline has passed.
        pacer.started(at: pacingStarted, interval: frameInterval)
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
            return true
        }

        let rectCount = prepared.encodedRects.count + (cursorRectangle == nil ? 0 : 1)
        guard rectCount <= Int(UInt16.max) else {
            throw RFBError.protocolError("too many rectangles in framebuffer update")
        }
        let header = [0, 0] + UInt16(rectCount).beBytes
        let writeStarted = DispatchTime.now().uptimeNanoseconds
        var updateChunks = [[UInt8]]()
        updateChunks.reserveCapacity(1 + rectCount)
        updateChunks.append(header)
        if let cursorRectangle { updateChunks.append(cursorRectangle) }
        updateChunks.append(contentsOf: prepared.encodedRects)
        try socket.writeAll(updateChunks, onStall: { [self] in
            noteNetworkStall()
        })
        let updateBytes = updateChunks.reduce(0) { $0 + $1.count }
        let writeDuration = elapsedSeconds(since: writeStarted)
        if let cursorImage {
            lastCursorImage = cursorImage
            lastCursorFormat = cursorFormat
        }

        let frameDuration = Date().timeIntervalSince(frameStarted)
        state.lock()
        staleFrameRetries += staleRetries
        updatesSent += 1
        bytesSent += updateBytes
        if measureTimings && (updatesSent <= 8 || updatesSent % 60 == 0) {
            let compressionRatio = prepared.payloadBytes > 0
                ? Double(prepared.uncompressedBytes) / Double(prepared.payloadBytes)
                : 0
            logger.verbose(
                "updates=\(updatesSent) encoding=\(prepared.encoding) last_rects=\(prepared.rects.count) " +
                "bytes=\(updateBytes) total_bytes=\(bytesSent) " +
                "changed_pixels=\(prepared.changedPixels) copyrect_pixels=\(prepared.copiedPixels) " +
                "raw_bytes=\(prepared.uncompressedBytes) payload_bytes=\(prepared.payloadBytes) " +
                "compression_ratio=\(String(format: "%.2f", compressionRatio)) " +
                "stale_retries=\(staleFrameRetries) network_stalls=\(networkStalls) " +
                "frame_ms=\(Int(frameDuration * 1_000)) " +
                "capture_ms=\(Int(captureDuration * 1_000)) " +
                "diff_ms=\(Int(diffDuration * 1_000)) " +
                "encode_ms=\(Int(prepared.encodeDuration * 1_000)) " +
                "write_ms=\(Int(writeDuration * 1_000)) " +
                "[client_fd=\(socket.fd)]"
            )
        }
        previousFramebuffer = committedBaseline(prepared)
        if prepared.coverage == Rect(x: 0, y: 0, width: prepared.framebuffer.width, height: prepared.framebuffer.height)
            || previousCoverage?.contains(prepared.coverage) != true { previousCoverage = prepared.coverage }
        // Apple's pointer messages stay in the original framebuffer coordinates
        // even when its transmitted image is scaled down.
        currentLayout = usesAppleExtensions ? prepared.sourceLayout : prepared.framebuffer.layout
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
        return true

    }

    private func prepareFramebufferUpdate(
        _ request: FramebufferUpdateRequest,
        framebuffer: Framebuffer,
        sourceLayout: VirtualDisplayLayout,
        captureDuration: TimeInterval
    ) throws -> PreparedFramebufferUpdate {
        let format: PixelFormat
        let encoding: RFBEncoding
        let previous: Framebuffer?
        let sentBefore: Bool
        let supportsResize: Bool
        let forceFull: Bool
        state.lock()
        format = pixelFormat
        encoding = selectedEncodingLocked()
        let zrleFormat = format.zrleFormat(forAppleClient: usesAppleExtensions || clientCapabilities.isAppleScreenSharingClient)
        previous = previousFramebuffer
        sentBefore = hasSentFramebufferUpdate
        supportsResize = !usesAppleExtensions && clientCapabilities.supportsDynamicResize
        let supportsCopyRect = clientCapabilities.supportsCopyRect
        let useEncodingTransaction = !clientCapabilities.isAppleScreenSharingClient
        forceFull = forceFullFramebuffer
        state.unlock()

        let framebufferSizeChanged = sentBefore
            && (previous?.width != framebuffer.width || previous?.height != framebuffer.height)
        let resizeUpdate = framebufferSizeChanged && supportsResize && !forceFull
        let requested = framebufferSizeChanged || forceFull
            ? Rect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
            : request.rect
        let coverage = Rect(x: max(0, min(framebuffer.width, requested.x)),
            y: max(0, min(framebuffer.height, requested.y)),
            width: max(0, min(framebuffer.width, requested.x + requested.width) - max(0, requested.x)),
            height: max(0, min(framebuffer.height, requested.y + requested.height) - max(0, requested.y)))
        let shouldDiff = sentBefore && request.incremental && !framebufferSizeChanged && !forceFull
            && previousCoverage?.contains(coverage) == true
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

        var rects: [Rect]
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
        var copies: [ScrollCopy] = []
        if shouldDiff, supportsCopyRect, let previous, let valid = previousCoverage {
            let plan = ScrollCopyPlanner.plan(current: framebuffer, previous: previous, dirty: rects, valid: valid)
            copies = plan.copies
            rects = plan.repaint
        }
        let copiedPixels = copies.reduce(0) { $0 + $1.rect.area }
        let diffDuration = logger.isVerbose ? Date().timeIntervalSince(diffStarted) : 0
        let transaction: EncodingTransaction?
        if resizeUpdate || rects.isEmpty {
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

        var encodedRects = copies.map(\.bytes)
        encodedRects.reserveCapacity(rects.count + copies.count)
        var encodeDuration = 0.0
        var changedPixels = copiedPixels
        var uncompressedBytes = 0
        var payloadBytes = copies.count * 4

        for rect in rects {
            let encodeStarted = DispatchTime.now().uptimeNanoseconds
            let payload: [UInt8]
            let encodingBytes = UInt32(bitPattern: encoding.rawValue).beBytes
            switch encoding {
            case .zrle:
                if case .zrle(let transaction) = transaction {
                    payload = try transaction.encode(rect: rect, framebuffer: framebuffer, pixelFormat: zrleFormat)
                } else {
                    payload = try zrleEncoder.encode(rect: rect, framebuffer: framebuffer, pixelFormat: zrleFormat)
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
            let bytesPerPixel = encoding == .zrle ? zrleFormat.cPixelByteCount : Int(format.bitsPerPixel / 8)
            uncompressedBytes += rect.width * rect.height * bytesPerPixel
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
            sourceLayout: sourceLayout,
            encoding: encoding,
            pixelFormat: format,
            rects: copies.map(\.rect) + rects,
            coverage: coverage,
            copiedPixels: copiedPixels,
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

    private func committedBaseline(_ prepared: PreparedFramebufferUpdate) -> Framebuffer {
        let frame = prepared.framebuffer
        let full = Rect(x: 0, y: 0, width: frame.width, height: frame.height)
        if prepared.coverage == full { return frame }
        // A captured pixel outside the transmitted region is NOT client state.
        // Preserve those pixels and disable sequence-based dirty shortcuts.
        let old = previousFramebuffer
        var pixels = old?.width == frame.width && old?.height == frame.height
            && old?.bytesPerRow == frame.bytesPerRow ? old!.bgra
            : [UInt8](repeating: 0, count: frame.bytesPerRow * frame.height)
        let rect = prepared.coverage
        pixels.withUnsafeMutableBytes { destination in
            frame.bgra.withUnsafeBytes { source in
                for y in rect.y..<(rect.y + rect.height) {
                    let offset = y * frame.bytesPerRow + rect.x * 4
                    memcpy(destination.baseAddress!.advanced(by: offset), source.baseAddress!.advanced(by: offset), rect.width * 4)
                }
            }
        }
        return Framebuffer(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow,
            bgra: pixels, layout: frame.layout)
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
            if clientCapabilities.supportsZlib {
                return .zlib
            }
            if clientCapabilities.supportsZRLE {
                return .zrle
            }
            return .raw
        }
    }

    private func throttleFrameRate() throws {
        while DispatchTime.now().uptimeNanoseconds < pacer.next {
            if state.withLock({ stopped }) { throw RFBError.socketError("session stopped") }
            wake.wait(until: DispatchTime(uptimeNanoseconds: pacer.next))
        }
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

        if encoding == .zlib {
            try zlibEncoder.adaptCompression(encodeDominates: encodeDuration >= writeDuration)
        } else if encoding == .zrle {
            try zrleEncoder.adaptCompression(encodeDominates: encodeDuration >= writeDuration)
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
        applyKeyEvent(down: down, keysym: keysym)
    }

    private func applyKeyEvent(down: Bool, keysym: UInt32) {
        state.lock()
        let mapAltToCommand = clientCapabilities.isAppleScreenSharingClient
        let allowInput = !usesAppleExtensions || appleControlMode
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
        applyPointerEvent(mask: mask, x: x, y: y)
    }

    private func applyPointerEvent(mask: UInt8, x: UInt16, y: UInt16) {
        state.lock()
        let layout = currentLayout
        let allowInput = !usesAppleExtensions || appleControlMode
        state.unlock()
        guard allowInput else { return }
        requestCaptureRecoveryAfterInput()
        let standardMask = usesAppleExtensions ? AppleRFB.standardButtonMask(mask) : mask
        if fileTransfer?.pointer(mask: standardMask, x: x, y: y, layout: layout) == true { return }
        input.pointer(buttonMask: standardMask, x: x, y: y, layout: layout)
    }

    private func handleAppleEncryptedInput() throws {
        // This per-event ECB envelope is separate from the CBC record layer.
        // Type-30 account logins enable it in Screen Sharing even when session
        // records are disabled. Decode with the authenticated wrapping key;
        // --no-encryption continues to prohibit framebuffer/stream ciphers.
        // Screen Sharing can send it before enabling incoming records, and
        // continues to use it when only server-to-viewer records are enabled.
        let bytes = try socket.readExact(17) // flags followed by one AES block
        guard let appleWrappingKey else {
            throw RFBError.protocolError("Apple encrypted input requires security type 30")
        }
        let event = try AppleEncryption.InputEvent(ciphertext: Array(bytes.dropFirst()), key: appleWrappingKey)
        if !appleEncryptedInputReceived {
            appleEncryptedInputReceived = true
            logger.verbose("Apple EncryptedInputEvent: accepted using authenticated key; session_encryption_allowed=\(allowEncryption) [client_fd=\(socket.fd)]")
        }
        // A single envelope can carry both events; the native server applies
        // the key first, then the pointer.
        if let key = event.key { applyKeyEvent(down: key.down, keysym: key.keysym) }
        if let pointer = event.pointer { applyPointerEvent(mask: pointer.mask, x: pointer.x, y: pointer.y) }
    }

    private func requestCaptureRecoveryAfterInput() {
        (capture as? InputRecoverySource)?.requestRecoveryAfterInput()
    }

    private func handleClientCutText() throws {
        _ = try socket.readExact(3)
        let lengthBytes = try socket.readExact(4)
        let length = Int(UInt32.be(lengthBytes[0], lengthBytes[1], lengthBytes[2], lengthBytes[3]))
        guard length <= Self.maxClassicClipboardBytes else {
            throw RFBError.protocolError("VNC clipboard exceeds the 16 MiB limit")
        }
        let bytes = try socket.readExact(length)
        if clipboardSync && !usesAppleExtensions {
            let text = String(decoding: bytes, as: UTF8.self)
            clipboard.setRemoteText(text)
        }
    }

    private func sendServerCutText(_ text: String) throws {
        let payload = Array(text.utf8)
        guard payload.count <= Self.maxClassicClipboardBytes else {
            logger.warning("skipping VNC clipboard larger than 16 MiB")
            return
        }
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += UInt32(payload.count).beBytes
        bytes += payload
        try socket.writeAll(bytes)
    }

    private var appleFileTransferAllowed: Bool {
        state.withLock {
            // Native Screen Sharing omits the FileCopy (0x22) bitmap bit even
            // while enabling and implementing file transfers. Gate on its drag
            // negotiation messages; MacFileTransfer still requires a selected
            // source or accepted destination for every file-copy request.
            fileTransferEnabled && appleControlMode
                && AppleRFB.supports(0x20, bitmap: appleViewerCapabilities)
                && AppleRFB.supports(0x1e, bitmap: appleViewerCapabilities)
        }
    }

    private var appleFileTransferDiagnostic: String {
        state.withLock {
            "backend=\(fileTransferEnabled) control=\(appleControlMode)"
                + " viewer_transfer_request=\(AppleRFB.supports(0x1e, bitmap: appleViewerCapabilities))"
                + " viewer_drag=\(AppleRFB.supports(0x20, bitmap: appleViewerCapabilities))"
                + " viewer_file_copy=\(AppleRFB.supports(0x22, bitmap: appleViewerCapabilities))"
        }
    }

    private func requireAppleExtensions() throws {
        guard usesAppleExtensions else {
            throw RFBError.protocolError("Apple message without extended ServerInit negotiation")
        }
    }

    private func enqueueWriterCommand(_ command: WriterCommand) throws {
        state.lock()
        defer { state.unlock() }
        guard !stopped else { throw RFBError.socketError("session closed") }
        guard writerCommands.count < 64 else {
            throw RFBError.protocolError("too many pending server messages")
        }
        if case .clipboardReceived(let content, _, _) = command {
            let pendingBytes = writerCommands.reduce(0) { count, pending in
                if case .clipboardReceived(let queued, _, _) = pending { return count + queued.payloadBytes }
                return count
            }
            guard content.payloadBytes <= AppleClipboard.maxArchiveBytes - pendingBytes else {
                throw RFBError.protocolError("too many buffered clipboard bytes")
            }
        }
        writerCommands.append(command)
        state.signal(); wake.signal()
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
        logger.verbose("Apple ViewerInfo: status=\(AppleRFB.supports(0x14, bitmap: capabilities)) clipboard=\(AppleRFB.supports(0x1f, bitmap: capabilities)) files=\(AppleRFB.supports(0x22, bitmap: capabilities))")
        if fileTransferEnabled { logger.verbose("Apple file transfer negotiation: \(appleFileTransferDiagnostic) [client_fd=\(socket.fd)]") }
    }

    private func handleAppleSetEncryption() throws {
        let header = try socket.readExact(3)
        let command = UInt16.be(header[1], header[2])
        var request = "command=\(command)"
        guard fileTransferEnabled else {
            throw RFBError.protocolError("Apple encryption was not advertised")
        }
        if command == 1 {
            let body = try socket.readExact(4)
            let level = UInt16.be(body[0], body[1])
            let count = Int(UInt16.be(body[2], body[3]))
            guard count <= 100 else {
                throw RFBError.protocolError("too many Apple encryption methods: \(count)")
            }
            let bytes = try socket.readExact(count * 4)
            let methods = stride(from: 0, to: bytes.count, by: 4).map {
                UInt32.be(bytes[$0], bytes[$0 + 1], bytes[$0 + 2], bytes[$0 + 3])
            }
            request += " level=\(level) methods=\(methods)"
            guard level <= 1, methods.contains(1) else {
                throw RFBError.protocolError("unsupported Apple encryption level or cipher method")
            }
            if !allowEncryption {
                // A native viewer requests encryption on a plain URL even after
                // type 2 authentication. It stays in plaintext until encoding
                // 1103 supplies keys. Consume the entire request so framing is
                // preserved, but do not send keys or arm either record cipher.
                // This undocumented fallback is only for explicit --no-encryption.
                logger.verbose("Apple SetEncryption: \(request) ignored by --no-encryption; record encryption remains disabled [client_fd=\(socket.fd)]")
                return
            }
            guard let appleWrappingKey else {
                throw RFBError.protocolError("Apple encryption requires password authentication with security type 30")
            }
            let keys = try AppleEncryption.Keys.random()
            let completion = DispatchSemaphore(value: 0)
            try enqueueWriterCommand(.rekey(keys, wrappingKey: appleWrappingKey, level: level, completion: completion))
            guard completion.wait(timeout: .now() + messageTimeout) == .success,
                  state.withLock({ writerError == nil && !stopped }) else {
                throw RFBError.protocolError("Apple encryption key exchange did not finish")
            }
            try socket.prepareAppleRecordReads(keys: keys, timeout: messageTimeout)
            self.appleWrappingKey = keys.key
        } else if command == 2 {
            let body = try socket.readExact(4)
            let enabled = UInt16.be(body[0], body[1])
            request += " enabled=\(enabled)"
            guard enabled <= 1 else { throw RFBError.protocolError("invalid Apple inbound encryption mode") }
            if enabled == 1 { try requireSessionEncryptionAllowed() }
            try socket.enableAppleRecordReads(enabled == 1)
        } else {
            throw RFBError.protocolError("unsupported Apple encryption command \(command)")
        }
        logger.verbose("Apple SetEncryption: \(request) [client_fd=\(socket.fd)]")
    }

    private func requireSessionEncryptionAllowed() throws {
        guard allowEncryption else {
            throw RFBError.protocolError("viewer attempted encrypted session records but --no-encryption is set")
        }
    }

    private func handleAppleSetServerScaling() throws {
        // Ten bytes including the message type: padding and a big-endian f64.
        // Native viewers can send this without checking the capability bitmap.
        let bytes = try socket.readExact(9)
        let bits = bytes.dropFirst().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let scale = Double(bitPattern: bits)
        guard scale.isFinite, scale > 0, scale <= 1 else {
            throw RFBError.protocolError("invalid Apple server scaling factor \(scale)")
        }
        state.lock()
        let supportsDisplayInfo = AppleRFB.preferredDisplayEncoding(in: clientCapabilities.advertisedEncodings) != nil
        if supportsDisplayInfo {
            pendingAppleFramebufferScale = scale
            state.signal(); wake.signal()
        }
        state.unlock()
        logger.verbose("Apple SetServerScaling: requested=\(scale) display_info=\(supportsDisplayInfo) [client_fd=\(socket.fd)]")
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
        appleNextPush = 0
        state.signal(); wake.signal()
        state.unlock()
        logger.verbose("Apple AutoFrameBufferUpdate: interval_us=\(interval) rect=\(rect.x),\(rect.y) \(rect.width)x\(rect.height) [client_fd=\(socket.fd)]")
    }

    private static func fenceMessage(flags: UInt32, payload: [UInt8]) -> [UInt8] {
        [248, 0, 0, 0] + flags.beBytes + [UInt8(payload.count)] + payload
    }

    private func handleContinuousUpdates() throws {
        let bytes = try socket.readExact(9)
        guard !usesAppleExtensions, state.withLock({ clientCapabilities.supportsContinuousUpdates }) else {
            throw RFBError.protocolError("ContinuousUpdates was not negotiated")
        }
        let rect = Rect(x: Int(UInt16.be(bytes[1], bytes[2])), y: Int(UInt16.be(bytes[3], bytes[4])),
            width: Int(UInt16.be(bytes[5], bytes[6])), height: Int(UInt16.be(bytes[7], bytes[8])))
        state.lock()
        continuousUpdate = bytes[0] != 0 && rect.width > 0 && rect.height > 0
            ? FramebufferUpdateRequest(incremental: true, rect: rect) : nil
        if activeUpdateRequest?.incremental == true { activeUpdateRequest = nil }
        if latestUpdateRequest?.incremental == true { latestUpdateRequest = nil }
        wake.signal()
        state.unlock()
        if bytes[0] == 0 { try enqueueWriterCommand(.protocolMessage([150])) }
        logger.verbose("ContinuousUpdates: enabled=\(bytes[0] != 0) rect=\(rect)")
    }

    private func handleFence() throws {
        let header = try socket.readExact(8)
        guard !usesAppleExtensions, state.withLock({ clientCapabilities.supportsFence }), header[7] <= 64 else {
            throw RFBError.protocolError("invalid or unnegotiated Fence")
        }
        let flags = UInt32.be(header[3], header[4], header[5], header[6])
        let payload = try socket.readExact(Int(header[7]))
        if flags & 0x80000000 != 0 {
            // BlockBefore/After are satisfied by the sole, ordered writer.
            // SyncNext is not offered; unsupported flags are cleared in reply.
            let response = Self.fenceMessage(flags: flags & 3, payload: payload)
            if flags & 2 != 0 {
                let done = DispatchSemaphore(value: 0)
                try enqueueWriterCommand(.barrier(response, done))
                guard done.wait(timeout: .now() + messageTimeout) == .success else {
                    throw RFBError.protocolError("Fence barrier timed out")
                }
            } else { try enqueueWriterCommand(.protocolMessage(response)) }
        } else if payload.count == 8 {
            let token = payload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            state.withLock { _ = outstandingFences.remove(token) }
            wake.signal()
        }
    }

    private func sendFrameFenceIfNeeded() throws {
        state.lock()
        guard continuousUpdate != nil && clientCapabilities.supportsFence else { state.unlock(); return }
        fenceCounter &+= 1
        let token = fenceCounter
        outstandingFences.insert(token)
        state.unlock()
        let payload = (0..<8).map { UInt8(truncatingIfNeeded: token >> (56 - $0 * 8)) }
        try socket.writeAll(Self.fenceMessage(flags: 0x80000001, payload: payload))
    }

    private func handleAppleSetMode() throws {
        let bytes = try socket.readExact(3)
        let mode = UInt16.be(bytes[1], bytes[2])
        guard mode <= 1 else {
            throw RFBError.protocolError("Apple exclusive control mode is not supported")
        }
        state.lock()
        let controlling = mode == 1
        let changed = appleControlMode != controlling
        appleControlMode = controlling
        if changed {
            appleClipboardNoticeAfter = controlling && !appleClipboardNoticeLogged
                ? Date().addingTimeInterval(1) : nil
        } else if controlling && appleClipboardNoticeAfter == nil && !appleClipboardNoticeLogged {
            appleClipboardNoticeAfter = Date().addingTimeInterval(1)
        }
        state.unlock()
        if changed && !controlling {
            // Cancel an AppKit move before releasing its synthetic button.
            fileTransfer?.cancelAll()
            input.releaseKeys()
            try enqueueWriterCommand(.clipboardReset)
        }
        // Like the native server, accept the selected mode without replying.
        // ServerInit already advertises control permission. MiscStatus 9/10
        // change that permission; echoing them here can trigger another SetMode
        // and create a feedback loop in Screen Sharing.
        logger.verbose("Apple SetMode: \(controlling ? "control" : "observe") state_changed=\(changed) [client_fd=\(socket.fd)]")
    }

    private func handleAppleAutoPasteboard() throws {
        let bytes = try socket.readExact(7)
        let command = UInt16.be(bytes[1], bytes[2])
        guard command == 1 || command == 2 else { return }
        state.lock()
        let enabled = command == 1
        let changed = appleAutoPasteboard != enabled
        // Reasserting an active subscription is not a clipboard change. A
        // false notification can replace a newer copy on the viewer with our
        // old text, including when the viewer's new copy is an unsupported image.
        if changed {
            appleAutoPasteboard = enabled
            appleInitialClipboardNotification = enabled
            appleClipboardGeneration &+= 1
            state.signal(); wake.signal()
        }
        state.unlock()
        if changed && !enabled { try enqueueWriterCommand(.clipboardReset) }
        logAppleClipboard("Apple AutoPasteboard: \(enabled ? "started" : "stopped") state_changed=\(changed)")
    }

    private func handleAppleClipboardFetch() throws {
        let bytes = try socket.readExact(7)
        let requestID = UInt32.be(bytes[3], bytes[4], bytes[5], bytes[6])
        state.lock()
        let allowed = appleControlMode && clipboardSync
        let promises = appleAutoPasteboard && bytes[0] & 1 != 0
        state.unlock()
        logAppleClipboard("Apple ClipboardFetch received: request=\(requestID) promises=\(promises) allowed=\(allowed)")
        if allowed {
            try enqueueWriterCommand(.clipboardFetch(requestID: requestID, promises: promises))
        }
    }

    private func handleAppleClipboardSend() throws {
        let header = try AppleClipboard.Header(bytes: socket.readExact(15))
        // Headers retain the normal message deadline. Image bodies get a
        // bounded size-based allowance, including slow links (at least 1 MiB/s).
        let compressed = try socket.withReadTimeout(
            messageTimeout + Double(header.compressedSize) / 1_048_576,
            operation: "Apple clipboard body"
        ) { try socket.readExact(header.compressedSize) }
        state.lock()
        let allowed = appleControlMode && clipboardSync
        let canRequestPromises = appleAutoPasteboard
            && AppleRFB.supports(0x14, bitmap: appleViewerCapabilities)
        state.unlock()
        logAppleClipboard("Apple ClipboardSend received: request=\(header.requestID) promises=\(header.promises) archive_bytes=\(header.uncompressedSize) compressed_bytes=\(header.compressedSize) allowed=\(allowed)")
        guard allowed else { return }
        guard let content = try AppleClipboard.decode(header: header, compressed: compressed).supportedContent else {
            logAppleClipboard("Apple ClipboardSend ignored: no supported flavor; server clipboard retained")
            return
        }
        // Clipboard mutations and fetches share the writer queue, preserving
        // wire order and preventing a fetch from racing an incoming image.
        let resolved = !header.promises && content.hasPromises ? content.resolved : content
        // An unavailable representation must not turn a full response into a clear.
        guard content.items.isEmpty || !resolved.items.isEmpty else { return }
        try enqueueWriterCommand(.clipboardReceived(resolved, promises: header.promises, canRequest: canRequestPromises))
    }

    private func applyAppleClipboard(_ content: ClipboardContent, promises: Bool, canRequest: Bool) throws {
        state.lock()
        let allowed = appleControlMode
        state.unlock()
        guard allowed else { return }
        if content.hasPromises {
            if promises && canRequest {
                appleIncomingPromise = true
                appleCancelledPromise = false
                applePromisedContent = nil
                state.lock()
                appleClipboardGeneration &+= 1
                appleInitialClipboardNotification = false
                state.unlock()
                try socket.writeAll(AppleRFB.status(3))
                logAppleClipboard("Apple ClipboardSend requesting promised contents: images=\(content.hasImages)")
            }
            return
        }
        // A local copy made during a deferred transfer takes precedence over
        // the response we requested earlier. Check here as well as in polling.
        if appleIncomingPromise && !promises { try sendClipboardChangeIfNeeded() }
        if appleCancelledPromise && !promises && !content.items.isEmpty {
            appleCancelledPromise = false
            logAppleClipboard("Apple ClipboardSend ignored: superseded promised response")
            return
        }
        appleCancelledPromise = appleIncomingPromise && promises && content.items.isEmpty
        clipboard.setRemoteContent(content)
        appleIncomingPromise = false
        applePromisedContent = nil
        state.lock()
        appleClipboardGeneration &+= 1
        appleInitialClipboardNotification = false
        state.unlock()
        logAppleClipboard("Apple ClipboardSend applied: payload_bytes=\(content.payloadBytes) images=\(content.hasImages)")
        let fetches = appleDeferredFetches
        appleDeferredFetches.removeAll()
        for fetch in fetches { try sendWriterCommand(fetch) }
    }

    private func sendWriterCommand(_ command: WriterCommand) throws {
        switch command {
        case .protocolMessage(let bytes):
            try socket.writeAll(bytes)
        case .barrier(let bytes, let done):
            try socket.writeAll(bytes)
            done.signal()
        case .rekey(let keys, let wrappingKey, let level, let completion):
            defer { completion.signal() }
            let cipher = level == 1 ? try AppleEncryption.Cipher(keys: keys, encrypt: true) : nil
            // The rekey itself uses the previous transport. All following
            // writes use the newly negotiated mode, at a message boundary.
            try socket.writeAll(keys.update(wrappingKey: wrappingKey))
            socket.setAppleRecordWrites(cipher)
            logger.verbose("Apple encryption keys sent: AES-128 outgoing_records=\(level == 1) [client_fd=\(socket.fd)]")
        case .clipboardReset:
            appleIncomingPromise = false
            appleCancelledPromise = false
            applePromisedContent = nil
            appleDeferredFetches.removeAll()
        case .fileData(let bytes, let completion):
            defer { completion.signal() }
            if appleFileTransferAllowed { try socket.writeAll(bytes) }
        case .clipboardReceived(let content, let promises, let canRequest):
            try applyAppleClipboard(content, promises: promises, canRequest: canRequest)
        case .clipboardFetch(let requestID, let promises):
            state.lock()
            let generation = appleClipboardGeneration
            let allowed = appleControlMode
            state.unlock()
            guard allowed else { return }
            if appleIncomingPromise {
                guard appleDeferredFetches.count < 64 else {
                    throw RFBError.protocolError("too many clipboard fetches while waiting for promised contents")
                }
                appleDeferredFetches.append(command)
                return
            }
            let content: ClipboardContent
            let source: String
            if !promises, let saved = applePromisedContent, saved.generation == generation {
                content = saved.content
                source = "saved-promise"
            } else if let current = clipboard.currentContent() {
                content = current
                source = "current-pasteboard"
            } else {
                logAppleClipboard("Apple ClipboardFetch skipped: unsupported or oversized pasteboard")
                return
            }
            applePromisedContent = promises ? (generation, content) : nil
            try socket.writeAll(AppleClipboard.message(content: content, requestID: requestID, promises: promises))
            logAppleClipboard("Apple ClipboardSend sent: request=\(requestID) promises=\(promises) payload_bytes=\(content.payloadBytes) images=\(content.hasImages) source=\(source)")
        }
    }

    private func sendClipboardChangeIfNeeded() throws {
        guard clipboardSync else { return }
        if !usesAppleExtensions {
            if let text = clipboard.localTextIfChanged() { try sendServerCutText(text) }
            return
        }
        state.lock()
        let watching = appleControlMode && appleAutoPasteboard
            && AppleRFB.supports(0x14, bitmap: appleViewerCapabilities)
            && AppleRFB.supports(0x1f, bitmap: appleViewerCapabilities)
        let initial = appleInitialClipboardNotification
        if watching { appleInitialClipboardNotification = false }
        let clipboardDisabled = appleControlMode && hasSentFramebufferUpdate && !appleAutoPasteboard
            && !appleClipboardNoticeLogged && (appleClipboardNoticeAfter.map { Date() >= $0 } ?? false)
        if clipboardDisabled { appleClipboardNoticeLogged = true }
        state.unlock()
        if clipboardDisabled {
            logAppleClipboard("Apple shared clipboard: available but disabled by viewer; Use Shared Clipboard is a client setting")
        }
        guard watching else { return }
        let changed = clipboard.localContentIfChanged() != nil
        if changed {
            if appleIncomingPromise { appleCancelledPromise = true }
            appleIncomingPromise = false
            applePromisedContent = nil
            state.withLock { appleClipboardGeneration &+= 1 }
            let fetches = appleDeferredFetches
            appleDeferredFetches.removeAll()
            for fetch in fetches { try sendWriterCommand(fetch) }
        }
        if changed || (initial && !appleIncomingPromise) {
            applePromisedContent = nil
            try socket.writeAll(AppleRFB.status(2))
            logAppleClipboard("Apple MiscStatus: pasteboard changed initial=\(initial) local_change=\(changed)")
        }
    }

    private func logAppleClipboard(_ message: String) {
        guard logger.isVerbose else { return }
        // Identify interleaved sessions and correlate client/server traces
        // without logging clipboard contents. Time is Unix seconds with ms.
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
        logger.verbose("\(message) [client_fd=\(socket.fd) time=\(timestamp)]")
    }
}
