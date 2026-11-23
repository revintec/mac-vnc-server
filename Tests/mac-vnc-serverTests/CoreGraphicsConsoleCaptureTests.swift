import CoreGraphics
import CoreVideo
import CVNCSession
import Foundation
import Testing
@testable import mac_vnc_server

struct CoreGraphicsConsoleCaptureTests {
    private let display = VirtualDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 4, height: 2), pixelWidth: 4, pixelHeight: 2)
    private func buffer(_ value: Int32, width: Int = 4) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, width, 2, kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess)
        let buffer = try #require(result)
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        memset(CVPixelBufferGetBaseAddress(buffer), value, CVPixelBufferGetBytesPerRow(buffer) * 2)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    private func frames(verify: @escaping @Sendable () throws -> Void = {}) -> ConsoleCaptureFrames {
        ConsoleCaptureFrames(layout: VirtualDisplayLayout(displays: [display], scaleOverride: 1), fps: 30, verify: verify)
    }

    @Test func onlyVenturaLoginwindowUsesCoreGraphics() {
        #expect(SessionCaptureBackend.select(uid: 0, majorVersion: 13) == .coreGraphics)
        #expect(!SessionCaptureBackend.needsConsoleService(uid: 0, majorVersion: 13))
        for version in [13, 14, 15, 26, 27] {
            #expect(SessionCaptureBackend.select(uid: 501, majorVersion: version) == .screenCaptureKit)
            #expect(!SessionCaptureBackend.needsConsoleService(uid: 501, majorVersion: version))
        }
        for version in [14, 15, 26, 27] {
            #expect(SessionCaptureBackend.select(uid: 0, majorVersion: version) == .screenCaptureKit)
            #expect(SessionCaptureBackend.needsConsoleService(uid: 0, majorVersion: version))
        }
    }

    @Test func unavailableConsoleFailsBeforeNativeCapture() async {
        await #expect(throws: (any Error).self) {
            try await CoreGraphicsConsoleCapture(scale: 1, fps: 30, displaySelection: .all,
                identity: ConsoleIdentity(uid: 0, auditID: 123), logger: ServerLogger(verbose: false))
        }
    }

    @Test func displayReplacementOrResolutionChangeRequiresFreshCapture() throws {
        try CoreGraphicsConsoleCapture.validateGeometry(expected: [display], current: [display])
        for current in [[], [VirtualDisplay(id: 2, bounds: display.bounds, pixelWidth: 4, pixelHeight: 2)],
                        [VirtualDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 8, height: 2), pixelWidth: 8, pixelHeight: 2)]] {
            #expect(throws: (any Error).self) {
                try CoreGraphicsConsoleCapture.validateGeometry(expected: [display], current: current)
            }
        }
    }

    @Test func borrowedPixelsAreCopiedBeforeReturning() throws {
        let capture = frames(), pixels = try buffer(31)
        capture.receive(displayID: 1, status: VNCDisplayFrameComplete, pixelBuffer: pixels, seconds: 1)
        #expect(capture.waitForFirstFrames(timeout: 0.1))
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 87, CVPixelBufferGetBytesPerRow(pixels) * 2)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(try capture.snapshot().bgra.first == 31)
    }

    @Test func blankClearsOldImageAndIdleCannotRestoreIt() throws {
        let capture = frames(), pixels = try buffer(31)
        capture.receive(displayID: 1, status: VNCDisplayFrameComplete, pixelBuffer: pixels, seconds: 1)
        capture.receive(displayID: 1, status: VNCDisplayFrameBlank, pixelBuffer: nil, seconds: 1.001)
        #expect(capture.isBlank)
        capture.receive(displayID: 1, status: VNCDisplayFrameIdle, pixelBuffer: pixels, seconds: 1.002)
        #expect(try capture.snapshot().bgra.allSatisfy { $0 == 0 })
        capture.receive(displayID: 1, status: VNCDisplayFrameComplete, pixelBuffer: pixels, seconds: 1.003)
        #expect(!capture.isBlank)
        #expect(try capture.snapshot().bgra.first == 31)
    }

    @Test func startupRequiresACompleteFrameFromEveryDisplay() throws {
        let second = VirtualDisplay(id: 2, bounds: CGRect(x: 4, y: 0, width: 4, height: 2), pixelWidth: 4, pixelHeight: 2)
        let capture = ConsoleCaptureFrames(layout: VirtualDisplayLayout(displays: [display, second], scaleOverride: 1),
            fps: 30, verify: {})
        capture.receive(displayID: 1, status: VNCDisplayFrameBlank, pixelBuffer: nil, seconds: 1)
        capture.receive(displayID: 2, status: VNCDisplayFrameIdle, pixelBuffer: nil, seconds: 1)
        #expect(!capture.waitForFirstFrames(timeout: 0.01), "blank or idle is not evidence of a captured desktop")
        capture.receive(displayID: 1, status: VNCDisplayFrameComplete, pixelBuffer: try buffer(31), seconds: 2)
        #expect(!capture.waitForFirstFrames(timeout: 0.01))
        capture.receive(displayID: 1, status: VNCDisplayFrameBlank, pixelBuffer: nil, seconds: 2.001)
        capture.receive(displayID: 2, status: VNCDisplayFrameComplete, pixelBuffer: try buffer(47), seconds: 2)
        #expect(!capture.waitForFirstFrames(timeout: 0.01), "a display that went blank must deliver a fresh complete frame")
        capture.receive(displayID: 1, status: VNCDisplayFrameComplete, pixelBuffer: try buffer(31), seconds: 2.002)
        #expect(capture.waitForFirstFrames(timeout: 0.01))
        let image = try capture.snapshot()
        #expect(image.width == 8 && image.height == 2)
        #expect(image.bgra[0] == 31 && image.bgra[4 * 4] == 47)
    }

    @Test func sleepWakeChecksSessionAndDoesNotWakeAnAlreadyAwakeDisplay() throws {
        let logger = ServerLogger(verbose: false)
        var checks = 0, wakes = 0
        try CoreGraphicsConsoleCapture.wakeIfAsleep(verify: { checks += 1 }, isAsleep: { false },
            wake: { wakes += 1 }, logger: logger)
        #expect(checks == 1 && wakes == 0)
        checks = 0
        try CoreGraphicsConsoleCapture.wakeIfAsleep(verify: { checks += 1 }, isAsleep: { true },
            wake: { wakes += 1 }, logger: logger)
        #expect(checks == 3 && wakes == 1)
        #expect(throws: (any Error).self) {
            try CoreGraphicsConsoleCapture.wakeIfAsleep(verify: { throw RFBError.captureFailed("console changed") },
                isAsleep: { true }, wake: { wakes += 1 }, logger: logger)
        }
        #expect(wakes == 1)
        var valid = true
        #expect(throws: (any Error).self) {
            try CoreGraphicsConsoleCapture.wakeIfAsleep(verify: { if !valid { throw RFBError.captureFailed("console changed") } },
                isAsleep: { true }, wake: { valid = false }, logger: logger)
        }
    }

    @Test func endedOrMalformedStreamsNeverKeepServingStaleFrames() throws {
        for kind in 0..<3 {
            let capture = frames()
            capture.receive(displayID: 1, status: VNCDisplayFrameComplete, pixelBuffer: try buffer(31), seconds: 1)
            switch kind {
            case 0: capture.receive(displayID: 1, status: VNCDisplayFrameStopped, pixelBuffer: nil, seconds: 2)
            case 1: capture.receive(displayID: 1, status: VNCDisplayFrameComplete, pixelBuffer: try buffer(31, width: 8), seconds: 2)
            default: capture.receive(displayID: 99, status: VNCDisplayFrameComplete, pixelBuffer: try buffer(31), seconds: 2)
            }
            #expect(throws: (any Error).self) { try capture.snapshot() }
            #expect(throws: (any Error).self) { try capture.currentSequence() }
        }
    }

    @Test func changingConsoleInvalidatesAlreadyCapturedFrames() throws {
        let verification = ConsoleVerificationFixture()
        let capture = frames { try verification.check() }
        capture.receive(displayID: 1, status: VNCDisplayFrameComplete, pixelBuffer: try buffer(31), seconds: 1)
        verification.invalidate()
        #expect(throws: (any Error).self) { try capture.snapshot() }
    }

    @Test func stoppedDeliveryIgnoresLateCallbacks() throws {
        let capture = frames()
        capture.receive(displayID: 1, status: VNCDisplayFrameComplete, pixelBuffer: try buffer(31), seconds: 1)
        let sequence = try capture.store.currentSequence()
        capture.stop()
        capture.receive(displayID: 1, status: VNCDisplayFrameComplete, pixelBuffer: try buffer(87), seconds: 2)
        #expect(try capture.store.currentSequence() == sequence)
        #expect(throws: (any Error).self) { try capture.snapshot() }
    }
}

private final class ConsoleVerificationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func invalidate() { lock.withLock { valid = false } }
    func check() throws {
        if !lock.withLock({ valid }) { throw RFBError.captureFailed("console changed") }
    }
}
