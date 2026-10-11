import CoreVideo
import Foundation
import Testing
@testable import mac_vnc_server

/// Independent, strict RFC 6143 decoder. It does not call the encoder's tile,
/// palette, run-length or CPixel helpers; output is ordinary negotiated pixels.
private func decodeZRLE(_ bytes: [UInt8], width: Int, height: Int, format: PixelFormat) throws -> [UInt8] {
    var position = 0
    func take(_ n: Int) throws -> [UInt8] {
        guard position + n <= bytes.count else { throw RFBError.protocolError("truncated test tile") }
        defer { position += n }; return Array(bytes[position..<(position + n)])
    }
    func byte() throws -> Int { Int(try take(1)[0]) }
    let fullBytes = Int(format.bitsPerPixel / 8)
    let mask = UInt32(format.redMax) << format.redShift | UInt32(format.greenMax) << format.greenShift | UInt32(format.blueMax) << format.blueShift
    let compact = fullBytes == 4 && format.depth <= 24 && (mask & 0xff000000 == 0 || mask & 255 == 0)
    let pixelBytes = compact ? 3 : fullBytes
    func pixel() throws -> [UInt8] {
        var raw = try take(pixelBytes)
        if compact {
            let omittedHigh = mask & 0xff000000 == 0
            if omittedHigh == format.bigEndian { raw.insert(0, at: 0) } else { raw.append(0) }
        }
        return raw
    }
    func length() throws -> Int {
        var n = 1
        while true { let b = try byte(); n += b; if b < 255 { return n } }
    }
    var result = [UInt8](repeating: 0, count: width * height * fullBytes)
    for y in stride(from: 0, to: height, by: 64) {
        for x in stride(from: 0, to: width, by: 64) {
            let w = min(64, width - x), h = min(64, height - y), mode = try byte()
            let paletteSize = mode == 128 ? 0 : mode & 127
            guard mode == 0 || mode == 1 || (2...16).contains(mode) || mode >= 128 && mode != 129 else {
                throw RFBError.protocolError("invalid ZRLE mode")
            }
            let palette = try (0..<paletteSize).map { _ in try pixel() }
            var decoded: [[UInt8]] = []
            if mode == 0 { decoded = try (0..<(w * h)).map { _ in try pixel() } }
            else if mode == 1 { decoded = Array(repeating: palette[0], count: w * h) }
            else if mode < 128 {
                let bits = mode == 2 ? 1 : mode <= 4 ? 2 : 4
                for _ in 0..<h {
                    let row = try take((w * bits + 7) / 8)
                    for column in 0..<w {
                        let index = Int(row[column * bits / 8] >> (8 - bits - column * bits % 8)) & ((1 << bits) - 1)
                        guard index < palette.count else { throw RFBError.protocolError("palette index overflow") }
                        decoded.append(palette[index])
                    }
                }
            } else {
                while decoded.count < w * h {
                    let color: [UInt8], run: Int
                    if mode == 128 { color = try pixel(); run = try length() }
                    else {
                        let marker = try byte(), index = marker & 127
                        guard index < palette.count else { throw RFBError.protocolError("RLE palette overflow") }
                        color = palette[index]; run = marker & 128 == 0 ? 1 : try length()
                    }
                    guard decoded.count + run <= w * h else { throw RFBError.protocolError("run crosses tile") }
                    decoded += Array(repeating: color, count: run)
                }
            }
            for row in 0..<h { for column in 0..<w {
                let offset = ((y + row) * width + x + column) * fullBytes
                result.replaceSubrange(offset..<(offset + fullBytes), with: decoded[row * w + column])
            } }
        }
    }
    guard position == bytes.count else { throw RFBError.protocolError("trailing tile bytes") }
    return result
}

@Test func zrlePreservesEveryPixelAcrossPalettesRunsEdgesAndFormats() throws {
    var formats: [PixelFormat] = []
    for big in [false, true] {
        for depth: UInt8 in [24, 32] { var f = PixelFormat.serverDefault; f.depth = depth; f.bigEndian = big; formats.append(f) }
        var high = PixelFormat.serverDefault
        high.redShift = 24; high.greenShift = 16; high.blueShift = 8; high.bigEndian = big; formats.append(high)
        formats.append(PixelFormat(bitsPerPixel: 16, depth: 16, bigEndian: big, trueColor: true,
            redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0))
        formats.append(PixelFormat(bitsPerPixel: 8, depth: 8, bigEndian: big, trueColor: true,
            redMax: 7, greenMax: 7, blueMax: 3, redShift: 5, greenShift: 2, blueShift: 0))
    }
    let w = 133, h = 101, stride = 544, rect = Rect(x: 3, y: 2, width: 127, height: 97)
    for colors in [1, 2, 3, 5, 16, 17, 32, 127, 128, 4096] {
        for run in [1, 7, 256] {
            var pixels = [UInt8](repeating: 213, count: stride * h)
            for y in 0..<h { for x in 0..<w {
                let c = ((y * w + x) / run) % colors, offset = y * stride + x * 4
                pixels[offset] = UInt8(truncatingIfNeeded: c * 73)
                pixels[offset + 1] = UInt8(truncatingIfNeeded: c * 29 + c / 256)
                pixels[offset + 2] = UInt8(truncatingIfNeeded: c * 11 + c / 64)
            } }
            let frame = Framebuffer(width: w, height: h, bytesPerRow: stride, bgra: pixels,
                layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: w, height: h))
            for format in formats {
                let encoder = try ZRLEEncoder()
                let payload = try encoder.encode(rect: rect, framebuffer: frame, pixelFormat: format)
                let tiles = try inflatePayloads([payload], outputCounts: [rect.area * 5 + 1024])
                let decoded = try decodeZRLE(tiles, width: rect.width, height: rect.height, format: format)
                #expect(decoded == (try RawEncoding.encode(rect: rect, framebuffer: frame, pixelFormat: format)),
                    "colors=\(colors) run=\(run) format=\(format)")
            }
        }
    }
}

@Test func appleZRLECompactFormatDoesNotChangeOtherPixelFormats() {
    var requested = PixelFormat.serverDefault
    requested.depth = 32
    #expect(requested.cPixelByteCount == 4)
    #expect(requested.zrleFormat(forAppleClient: false) == requested)
    #expect(requested.zrleFormat(forAppleClient: true) == .serverDefault)
    #expect(requested.pixelBytes(red: 1, green: 2, blue: 3).count == 4)
    // Limit the compatibility exception to Apple's observed little-endian BGRX.
    var bigEndian = requested; bigEndian.bigEndian = true
    #expect(bigEndian.zrleFormat(forAppleClient: true) == bigEndian)
    var tenBit = requested
    tenBit.redMax = 1023; tenBit.greenMax = 1023; tenBit.blueMax = 1023
    tenBit.redShift = 20; tenBit.greenShift = 10
    #expect(tenBit.zrleFormat(forAppleClient: true) == tenBit)
    #expect(PixelFormat.serverDefault.zrleFormat(forAppleClient: true) == .serverDefault)
}

@Test func framePacerPreservesDeadlinesSkipsStallsAndChangesRate() {
    var pacer = FramePacer()
    pacer.started(at: 1_000_000_000, interval: 0.02)
    #expect(pacer.next == 1_020_000_000)
    pacer.started(at: 1_021_000_000, interval: 0.02)
    #expect(pacer.next == 1_040_000_000)
    pacer.started(at: 2_000_000_000, interval: 0.02)
    #expect(pacer.next == 2_020_000_000)
    pacer.started(at: 2_020_000_000, interval: 0.04)
    #expect(pacer.next == 2_060_000_000)
}

@Test func captureCadenceKeeps45Of60FramesAndDoesNotPublishIdleBuffers() throws {
    let display = VirtualDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 2, height: 1), pixelWidth: 2, pixelHeight: 1)
    let store = StreamingFrameStore(layout: VirtualDisplayLayout(displays: [display], scaleOverride: 1),
        expectedDisplayIDs: [1], acceptedFrameRate: 45)
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 2, 1, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixelBuffer = try #require(buffer)
    for n in 0..<60 { store.update(displayID: 1, pixelBuffer: pixelBuffer, dirtyRects: nil, presentationTime: Double(n) / 60) }
    let sequence = try #require(try store.currentSequence())
    #expect(sequence == 45)
    store.update(displayID: 1, pixelBuffer: pixelBuffer, dirtyRects: [], presentationTime: 2)
    #expect(try store.currentSequence() == sequence)
    store.setAcceptedFrameRate(60)
    store.update(displayID: 1, pixelBuffer: pixelBuffer, dirtyRects: nil, presentationTime: 0)
    #expect(try store.currentSequence() == sequence + 1)
    // A skipped changed buffer invalidates the next buffer's dirty hint, even
    // when the next complete buffer reports no further changes.
    store.update(displayID: 1, pixelBuffer: pixelBuffer, dirtyRects: nil, presentationTime: 0.001)
    store.update(displayID: 1, pixelBuffer: pixelBuffer, dirtyRects: [], presentationTime: 0.02)
    #expect(try store.currentSequence() == sequence + 2)
    #expect(try store.snapshot().dirtyRects == nil)
}

@Test func scaledCacheInvalidatesForCursorScaleLayoutAndMissingSequence() throws {
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: 4, height: 4)
    let frame = Framebuffer(width: 4, height: 4, bgra: [UInt8](repeating: 0, count: 64), layout: layout, sequence: 1)
    var cache = ScaledFramebufferCache()
    let first = try cache.frame(frame, factor: 0.5, rounded: false, cursor: nil)
    #expect(try cache.frame(frame, factor: 0.5, rounded: false, cursor: nil).bgra == first.bgra)
    #expect(try cache.frame(frame, factor: 1, rounded: false, cursor: nil).width == 4)
    let cursor = CursorSnapshot(image: CursorImage(width: 1, height: 1, hotX: 0, hotY: 0, bgra: [255, 0, 0, 255]), position: .zero)
    #expect(try cache.frame(frame, factor: 1, rounded: false, cursor: cursor).bgra[0] == 255)
    #expect(try cache.frame(frame, factor: 1, rounded: false, cursor: nil).bgra[0] == 0)
    let unknown = Framebuffer(width: 4, height: 4, bgra: [UInt8](repeating: 42, count: 64), layout: layout)
    #expect(try cache.frame(unknown, factor: 1, rounded: false, cursor: nil).bgra[0] == 42)
}

@Test(arguments: [-31, -4, 7, 64])
func scrollCopiesReconstructExactlyWithOverlapsAndChangedOverlays(delta: Int) throws {
    let w = 256, h = 256, full = Rect(x: 0, y: 0, width: w, height: h)
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: w, height: h)
    let before = (0..<(w * h * 4)).map { UInt8(truncatingIfNeeded: (($0 / 4) * 71) ^ (($0 / 4) >> 8) ^ ($0 % 4 * 13)) }
    var after = before
    for y in 0..<h where y + delta >= 0 && y + delta < h {
        after.replaceSubrange((y * w * 4)..<((y + 1) * w * 4), with: before[((y + delta) * w * 4)..<((y + delta + 1) * w * 4)])
    }
    after.replaceSubrange((60 * w * 4)..<(61 * w * 4), with: [UInt8](repeating: 123, count: w * 4))
    let old = Framebuffer(width: w, height: h, bgra: before, layout: layout)
    let new = Framebuffer(width: w, height: h, bgra: after, layout: layout)
    let plan = ScrollCopyPlanner.plan(current: new, previous: old, dirty: [full], valid: full)
    #expect(!plan.copies.isEmpty)
    var client = before
    for copy in plan.copies {
        // CopyRect reads the CURRENT client image, not an immutable old copy.
        let snapshot = client
        for row in 0..<copy.rect.height {
            let dst = ((copy.rect.y + row) * w + copy.rect.x) * 4, src = ((copy.sourceY + row) * w + copy.rect.x) * 4
            client.replaceSubrange(dst..<(dst + copy.rect.width * 4), with: snapshot[src..<(src + copy.rect.width * 4)])
        }
    }
    for rect in plan.repaint { for y in rect.y..<(rect.y + rect.height) {
        let offset = (y * w + rect.x) * 4
        client.replaceSubrange(offset..<(offset + rect.width * 4), with: after[offset..<(offset + rect.width * 4)])
    } }
    #expect(client == after)
    let partial = Rect(x: 0, y: 64, width: w, height: 64)
    let limited = ScrollCopyPlanner.plan(current: new, previous: old, dirty: [partial], valid: partial)
    #expect(limited.copies.allSatisfy { partial.contains(Rect(x: $0.rect.x, y: $0.sourceY, width: $0.rect.width, height: $0.rect.height)) })
}
