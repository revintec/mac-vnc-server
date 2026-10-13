import CoreGraphics
import CoreVideo
import CVNCSession
import Foundation
import Testing
@testable import mac_vnc_server

struct ConsoleDisplayCaptureTests {
    @Test func streamFailuresPreserveTheirStageAndErrorDomain() throws {
        var error = VNCConsoleCaptureError()
        let stream = VNCConsoleCaptureStart(0, 0, 0, 30, { _, _, _ in }, nil, &error)
        #expect(stream == nil && error.stage == VNCConsoleCaptureStageArguments)
        #expect(ConsoleDisplayCapture.describe(error).contains("errno"))
        // Regression: a NULL factory result used to be labeled "code 6",
        // although CoreGraphics provided no error and Start was never called.
        let factory = ConsoleDisplayCapture.describe(VNCConsoleCaptureError(stage: VNCConsoleCaptureStageCreate, code: 0))
        #expect(factory.contains("returned NULL before start") && factory.contains("no error code"))
        let start = ConsoleDisplayCapture.describe(VNCConsoleCaptureError(stage: VNCConsoleCaptureStageStart, code: 1002))
        #expect(start.contains("CGDisplayStreamStart") && start.contains("CGError 1002"))
    }

    @Test func consoleRejectsDisplayMissingFromItsGraphicsSession() throws {
        // ScreenCaptureKit offered the off-console user's display 30 while the
        // root worker's CGDisplayBounds(30) was empty. Never use its SCK frame
        // as a substitute: that produces a valid image of the wrong session.
        #expect(throws: (any Error).self) {
            try ConsoleDisplayCapture.makeLayout(displays: [
                VirtualDisplay(id: 30, bounds: .zero, pixelWidth: 1728, pixelHeight: 1118)
            ], scale: 1)
        }
    }

    @Test func consoleCaptureRetainsFullGeometryThroughIPCMetadata() throws {
        let display = VirtualDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1118),
            pixelWidth: 1728, pixelHeight: 1118)
        let layout = try ConsoleDisplayCapture.makeLayout(displays: [display], scale: 1)
        let store = StreamingFrameStore(layout: layout, expectedDisplayIDs: [1], acceptedFrameRate: 60)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, layout.width, layout.height,
            kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        try #require(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
        memset(CVPixelBufferGetBaseAddress(pixels), 42, CVPixelBufferGetBytesPerRow(pixels) * layout.height)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        store.update(displayID: 1, pixelBuffer: pixels, dirtyRects: nil, presentationTime: 1)
        let frame = try store.snapshot()
        #expect(frame.width == 1728 && frame.height == 1118)
        let info = try JSONDecoder().decode(ConsoleFrameInfo.self, from: JSONEncoder().encode(ConsoleFrameInfo(frame)))
        let received = try info.framebuffer(pixels: frame.bgra, sequence: 1)
        #expect(received.layout == layout && received.bgra == frame.bgra)
        #expect(received.bgra.first == 42 && received.bgra.last == 42)
    }

    @Test func consoleLayoutPreservesScaledCoordinatesAndRejectsInvalidAllocationSizes() throws {
        let displays = [
            VirtualDisplay(id: 1, bounds: CGRect(x: -800, y: -200, width: 800, height: 600), pixelWidth: 800, pixelHeight: 600),
            VirtualDisplay(id: 2, bounds: CGRect(x: 0, y: 0, width: 1000, height: 700), pixelWidth: 1000, pixelHeight: 700)
        ]
        let layout = try ConsoleDisplayCapture.makeLayout(displays: displays, scale: 0.5)
        #expect(layout.origin == CGPoint(x: -800, y: -200) && layout.width == 900 && layout.height == 450)
        #expect(layout.globalPoint(framebufferX: 400, framebufferY: 100) == .zero)
        #expect(layout.globalPoint(framebufferX: 50, framebufferY: 25) == CGPoint(x: -700, y: -150))
        for scale in [0, Double.nan, Double.infinity, 5] {
            #expect(throws: (any Error).self) { try ConsoleDisplayCapture.makeLayout(displays: displays, scale: scale) }
        }
        for bounds in [CGRect.null, .infinite, CGRect(x: 0, y: 0, width: 65535, height: 65535)] {
            #expect(throws: (any Error).self) {
                try ConsoleDisplayCapture.makeLayout(displays: [VirtualDisplay(id: 1, bounds: bounds,
                    pixelWidth: 65535, pixelHeight: 65535)], scale: 1)
            }
        }
    }

    @Test func blankAndStoppedEventsCannotKeepAnOldConsoleFrameLive() throws {
        let display = VirtualDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 4, height: 2),
            pixelWidth: 4, pixelHeight: 2)
        let store = StreamingFrameStore(layout: VirtualDisplayLayout(displays: [display], scaleOverride: 1),
            expectedDisplayIDs: [1], acceptedFrameRate: 60)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 4, 2, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        try #require(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
        memset(CVPixelBufferGetBaseAddress(pixels), 42, CVPixelBufferGetBytesPerRow(pixels) * 2)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        store.update(displayID: 1, pixelBuffer: pixels, dirtyRects: nil, presentationTime: nil)
        let original = try store.currentSequence()
        let output = ConsoleDisplayOutput(displayID: 1, width: 4, height: 2, store: store)
        output.receive(status: 1, surface: nil) // idle keeps a valid frame
        #expect(try store.currentSequence() == original)
        output.receive(status: 2, surface: nil) // blank invalidates old pixels
        #expect(output.isBlank && output.failure == nil)
        #expect(try store.currentSequence() != original)
        #expect(try store.snapshot().bgra.allSatisfy { $0 == 0 })
        output.receive(status: 3, surface: nil)
        #expect(output.failure != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VNC_TEST_CONSOLE_CAPTURE"] == "1"))
    func realDisplayStreamInCurrentSession() async throws {
        // Opt-in hardware check. Reads only the current test user's session;
        // does not join root, inject input, open a listener or save pixel data.
        let capture = try ConsoleDisplayCapture(scale: 1, fps: 30, displaySelection: .all,
            logger: ServerLogger(verbose: true))
        defer { capture.stop() }
        try await capture.waitUntilReady()
        let frame = try capture.capture()
        try ConsoleFrameInfo(frame).validate(pixelCount: frame.bgra.count)
        #expect(frame.width > 1 && frame.height > 1)
        #expect(Set(frame.bgra).count > 1)
        #expect(frame.layout.displays.map(\.id) == (try MacScreenCapture.activeDisplayIDs()))
    }
}
