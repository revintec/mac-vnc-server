import AppKit
import CoreGraphics
import Foundation

enum CursorMode: String {
    case auto
    case embedded
}

/// Premultiplied BGRA, in desktop points before scaling for a particular viewer.
struct CursorImage: Equatable, Sendable {
    let width: Int
    let height: Int
    let hotX: Int
    let hotY: Int
    let bgra: [UInt8]

    static let hidden = CursorImage(width: 0, height: 0, hotX: 0, hotY: 0, bgra: [])

    func scaled(by scale: CGFloat) throws -> CursorImage {
        guard width > 0, height > 0, abs(scale - 1) > .ulpOfOne else { return self }
        let scaled = try FramebufferResampling.scale(framebuffer, factor: scale)
        return CursorImage(width: scaled.width, height: scaled.height,
            hotX: min(scaled.width - 1, max(0, Int((CGFloat(hotX) * scale).rounded()))),
            hotY: min(scaled.height - 1, max(0, Int((CGFloat(hotY) * scale).rounded()))), bgra: scaled.bgra)
    }

    /// One RichCursor rectangle; the client moves it without framebuffer traffic.
    func richCursorRectangle(format: PixelFormat) throws -> [UInt8] {
        var rectangle = UInt16(hotX).beBytes + UInt16(hotY).beBytes
            + UInt16(width).beBytes + UInt16(height).beBytes
            + UInt32(bitPattern: RFBPseudoEncoding.richCursor).beBytes
        guard width > 0, height > 0 else { return rectangle }
        var straight = bgra
        let maskStride = (width + 7) / 8
        var mask = [UInt8](repeating: 0, count: maskStride * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = Int(bgra[offset + 3])
                if alpha >= 128 { mask[y * maskStride + x / 8] |= 0x80 >> (x % 8) }
                for component in 0..<3 {
                    straight[offset + component] = alpha == 0 ? 0
                        : UInt8(min(255, (Int(bgra[offset + component]) * 255 + alpha / 2) / alpha))
                }
            }
        }
        let pixels = Framebuffer(width: width, height: height, bgra: straight, layout: .empty)
        rectangle += try RawEncoding.encode(rect: Rect(x: 0, y: 0, width: width, height: height),
            framebuffer: pixels, pixelFormat: format)
        rectangle += mask
        return rectangle
    }

    private var framebuffer: Framebuffer {
        Framebuffer(width: width, height: height, bgra: bgra,
            layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: width, height: height))
    }
}

struct CursorSnapshot: Sendable {
    let image: CursorImage
    let position: CGPoint

    /// Fallback for viewers without RichCursor. Each viewer retains its own
    /// framebuffer baseline, including the old cursor area that must be erased.
    func composited(over frame: Framebuffer) throws -> Framebuffer {
        let cursor = try image.scaled(by: frame.layout.scale)
        let originX = Int(((position.x - frame.layout.origin.x) * frame.layout.scale).rounded()) - cursor.hotX
        let originY = Int(((position.y - frame.layout.origin.y) * frame.layout.scale).rounded()) - cursor.hotY
        var pixels = frame.bgra
        let x0 = max(0, originX), y0 = max(0, originY)
        let x1 = min(frame.width, originX + cursor.width), y1 = min(frame.height, originY + cursor.height)
        if x1 > x0, y1 > y0 {
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let src = ((y - originY) * cursor.width + x - originX) * 4
                    let dst = y * frame.bytesPerRow + x * 4
                    let alpha = Int(cursor.bgra[src + 3])
                    for component in 0..<3 {
                        pixels[dst + component] = UInt8(min(255, Int(cursor.bgra[src + component])
                            + (Int(pixels[dst + component]) * (255 - alpha) + 127) / 255))
                    }
                }
            }
        }
        // Cursor changes are independent of ScreenCaptureKit's sequence/dirty rectangles.
        return Framebuffer(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow,
            bgra: pixels, layout: frame.layout)
    }
}

/// AppKit access stays on the main actor. Writers only read a locked value.
/// There is one sampler for all viewers and display ports of a capture source.
final class MacCursorMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CursorSnapshot
    private var task: Task<Void, Never>?

    private init(initial: CursorSnapshot) { value = initial }
    deinit { task?.cancel() }

    var snapshot: CursorSnapshot { lock.withLock { value } }

    @MainActor static func start() -> MacCursorMonitor? {
        guard let cursor = NSCursor.currentSystem, let image = render(cursor) else { return nil }
        let monitor = MacCursorMonitor(initial: CursorSnapshot(image: image, position: CGEvent(source: nil)?.location ?? .zero))
        monitor.task = Task { @MainActor [weak monitor] in
            while !Task.isCancelled {
                autoreleasepool { monitor?.sample() }
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
        }
        return monitor
    }

    @MainActor private func sample() {
        let image: CursorImage
        if let cursor = NSCursor.currentSystem {
            guard let rendered = Self.render(cursor) else { return }
            image = rendered
        } else {
            image = .hidden
        }
        let position = CGEvent(source: nil)?.location ?? snapshot.position
        lock.withLock { value = CursorSnapshot(image: image, position: position) }
    }

    @MainActor static func render(_ cursor: NSCursor) -> CursorImage? {
        let size = cursor.image.size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, size.width <= 256, size.height <= 256 else { return nil }
        let width = Int(size.width.rounded(.up)), height = Int(size.height.rounded(.up))
        var proposed = CGRect(origin: .zero, size: size)
        guard let image = cursor.image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        return CursorImage(width: width, height: height,
            hotX: max(0, min(width - 1, Int(cursor.hotSpot.x.rounded()))),
            hotY: max(0, min(height - 1, Int(cursor.hotSpot.y.rounded()))), bgra: pixels)
    }
}
