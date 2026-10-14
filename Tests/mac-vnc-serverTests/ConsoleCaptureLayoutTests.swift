import CoreGraphics
import CoreVideo
import CVNCSession
import Foundation
import Testing
@testable import mac_vnc_server

struct ConsoleCaptureLayoutTests {
    @Test func consoleRejectsDisplayMissingFromItsGraphicsSession() throws {
        // ScreenCaptureKit offered the off-console user's display 30 while the
        // root worker's CGDisplayBounds(30) was empty. Never use its SCK frame
        // as a substitute: that produces a valid image of the wrong session.
        #expect(throws: (any Error).self) {
            try StreamingScreenCapture.consoleLayout(displays: [
                VirtualDisplay(id: 30, bounds: .zero, pixelWidth: 1728, pixelHeight: 1118)
            ], scale: 1)
        }
    }

    @Test func consoleCaptureRetainsFullGeometry() throws {
        let display = VirtualDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1118),
            pixelWidth: 1728, pixelHeight: 1118)
        let layout = try StreamingScreenCapture.consoleLayout(displays: [display], scale: 1)
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
        #expect(frame.layout == layout && frame.bgra.first == 42 && frame.bgra.last == 42)

    }

    @Test func consoleLayoutPreservesScaledCoordinatesAndRejectsInvalidAllocationSizes() throws {
        let displays = [
            VirtualDisplay(id: 1, bounds: CGRect(x: -800, y: -200, width: 800, height: 600), pixelWidth: 800, pixelHeight: 600),
            VirtualDisplay(id: 2, bounds: CGRect(x: 0, y: 0, width: 1000, height: 700), pixelWidth: 1000, pixelHeight: 700)
        ]
        let layout = try StreamingScreenCapture.consoleLayout(displays: displays, scale: 0.5)
        #expect(layout.origin == CGPoint(x: -800, y: -200) && layout.width == 900 && layout.height == 450)
        #expect(layout.globalPoint(framebufferX: 400, framebufferY: 100) == .zero)
        #expect(layout.globalPoint(framebufferX: 50, framebufferY: 25) == CGPoint(x: -700, y: -150))
        for scale in [0, Double.nan, Double.infinity, 5] {
            #expect(throws: (any Error).self) { try StreamingScreenCapture.consoleLayout(displays: displays, scale: scale) }
        }
        for bounds in [CGRect.null, .infinite, CGRect(x: 0, y: 0, width: 65535, height: 65535)] {
            #expect(throws: (any Error).self) {
                try StreamingScreenCapture.consoleLayout(displays: [VirtualDisplay(id: 1, bounds: bounds,
                    pixelWidth: 65535, pixelHeight: 65535)], scale: 1)
            }
        }
    }

}
