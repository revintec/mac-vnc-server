import AppKit
import CoreVideo
import Foundation
import Testing
@testable import mac_vnc_server

@Test func richCursorUsesMaskRowPaddingHotspotAndStraightColor() throws {
    var bgra = [UInt8](repeating: 0, count: 9 * 2 * 4)
    bgra.replaceSubrange(0..<4, with: [50, 25, 100, 128])
    bgra.replaceSubrange(32..<36, with: [1, 2, 3, 255])
    bgra.replaceSubrange(36..<40, with: [4, 5, 6, 255])
    let image = CursorImage(width: 9, height: 2, hotX: 2, hotY: 1, bgra: bgra)
    let bytes = try image.richCursorRectangle(format: .serverDefault)
    #expect(Array(bytes.prefix(8)) == [0, 2, 0, 1, 0, 9, 0, 2])
    #expect(Array(bytes[12..<16]) == [100, 50, 199, 0])
    #expect(Array(bytes.suffix(4)) == [0x80, 0x80, 0x80, 0])
    #expect(bytes.count == 12 + 9 * 2 * 4 + 4)
    var rgb565 = PixelFormat.serverDefault
    rgb565.bitsPerPixel = 16; rgb565.depth = 16
    rgb565.redMax = 31; rgb565.greenMax = 63; rgb565.blueMax = 31
    rgb565.redShift = 11; rgb565.greenShift = 5
    #expect(try image.richCursorRectangle(format: rgb565).count == 12 + 9 * 2 * 2 + 4)
    #expect(try CursorImage.hidden.richCursorRectangle(format: rgb565).count == 12)
}

@Test func embeddedFallbackClipsBlendsAndInvalidatesCaptureSequence() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: CGPoint(x: -10, y: 20), scale: 1, width: 2, height: 2)
    let frame = Framebuffer(width: 2, height: 2, bytesPerRow: 12,
        bgra: [UInt8](repeating: 100, count: 24), layout: layout, sequence: 4, dirtyRects: [])
    let image = CursorImage(width: 2, height: 2, hotX: 1, hotY: 1,
        bgra: [[UInt8]](repeating: [50, 0, 0, 128], count: 4).flatMap { $0 })
    let cursor = CursorSnapshot(image: image, position: CGPoint(x: -10, y: 20))
    let composed = try cursor.composited(over: frame)
    #expect(Array(composed.bgra.prefix(4)) == [100, 50, 50, 100])
    #expect(Array(composed.bgra.dropFirst(4)) == Array(frame.bgra.dropFirst(4)))
    #expect(composed.sequence == nil && composed.dirtyRects == nil)
    let hidden = try CursorSnapshot(image: .hidden, position: .zero).composited(over: frame)
    #expect(hidden.bgra == frame.bgra)
    #expect(hidden.sequence == nil)
    #expect(RawEncoding.rectangles(current: hidden, previous: composed,
        requested: Rect(x: 0, y: 0, width: 2, height: 2), incremental: true).count == 1)
}

@Test func cursorScalesHotspotWithFramebuffer() throws {
    let image = CursorImage(width: 2, height: 3, hotX: 1, hotY: 2,
        bgra: [UInt8](repeating: 255, count: 24))
    let scaled = try image.scaled(by: 2)
    #expect(scaled.width == 4 && scaled.height == 6)
    #expect(scaled.hotX == 2 && scaled.hotY == 4)
}

@MainActor @Test func systemCursorRasterizerPreservesDistinctShapes() throws {
    // Render known AppKit shapes without changing the user's cursor or input.
    _ = NSApplication.shared
    let arrow = try #require(MacCursorMonitor.render(.arrow))
    let beam = try #require(MacCursorMonitor.render(.iBeam))
    #expect(arrow != beam)
    #expect(arrow.bgra.contains { $0 > 0 })
    #expect(beam.bgra.contains { $0 > 0 })
}

@Test func singleDisplayCaptureRetainsPaddedRowsWithoutRepacking() throws {
    let display = VirtualDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 3, height: 2), pixelWidth: 3, pixelHeight: 2)
    let store = StreamingFrameStore(layout: VirtualDisplayLayout(displays: [display], scaleOverride: 1),
        expectedDisplayIDs: [1], acceptedFrameRate: 60)
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 3, 2, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    memset(CVPixelBufferGetBaseAddress(pixels), 42, CVPixelBufferGetBytesPerRow(pixels) * 2)
    CVPixelBufferUnlockBaseAddress(pixels, [])
    store.update(displayID: 1, pixelBuffer: pixels, dirtyRects: nil, presentationTime: 1)
    let frame = try store.snapshot()
    #expect(frame.bytesPerRow == CVPixelBufferGetBytesPerRow(pixels))
    #expect(frame.bytesPerRow > frame.width * 4)
    #expect(try RawEncoding.encode(rect: Rect(x: 0, y: 0, width: 3, height: 2),
        framebuffer: frame, pixelFormat: .serverDefault) == [[UInt8]](repeating: [42, 42, 42, 0], count: 6).flatMap { $0 })
}

@Test func performanceOptionsPreserveAuthenticationAndAllowPlaintextFileTransfer() throws {
    guard case .run(let config) = try CLI.parse(arguments: ["--no-encryption", "--cursor", "embedded"]) else {
        Issue.record("expected run command"); return
    }
    #expect(config.passwordFromConfig)
    #expect(!config.allowEncryption && !config.fileTransfer && config.cursorMode == .embedded)
    guard case .run(let transfer) = try CLI.parse(arguments: ["--no-encryption", "--file-transfer"]) else {
        Issue.record("expected run command"); return
    }
    #expect(transfer.fileTransfer && !transfer.allowEncryption && transfer.passwordFromConfig)
    #expect(throws: (any Error).self) { try CLI.parse(arguments: ["--cursor", "unknown"]) }
}

@Test(arguments: [UInt8(24), UInt8(32)])
func bgrxFastPathPreservesPaddedRowsAndIgnoresAlpha(depth: UInt8) throws {
    let frame = Framebuffer(width: 3, height: 2, bytesPerRow: 16,
        bgra: Array(0..<32), layout: .empty)
    var format = PixelFormat.serverDefault
    format.depth = depth
    let bytes = try RawEncoding.encode(rect: Rect(x: 1, y: 0, width: 2, height: 2), framebuffer: frame, pixelFormat: format)
    #expect(bytes == [4, 5, 6, 0, 8, 9, 10, 0, 20, 21, 22, 0, 24, 25, 26, 0])
    format.bigEndian = true
    #expect(!format.usesBGRX8888)
    #expect(try RawEncoding.encode(rect: Rect(x: 1, y: 1, width: 1, height: 1), framebuffer: frame, pixelFormat: format) == [0, 22, 21, 20])
}
