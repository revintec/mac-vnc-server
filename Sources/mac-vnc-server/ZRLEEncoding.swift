import Foundation
import CVNCZlib

/// RFC 6143 tile coding with bounded C scratch storage and zlib-ng compression.
/// Shares the tested persistent-stream/transaction implementation with Zlib.
final class ZRLEEncoder {
    final class Transaction {
        private unowned let parent: ZRLEEncoder
        fileprivate let compressor: ZlibEncoder.Transaction
        fileprivate init(parent: ZRLEEncoder) throws {
            self.parent = parent
            compressor = try parent.compressor.beginTransaction()
        }
        func encode(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) throws -> [UInt8] {
            try compressor.encode(bytes: parent.tiles(rect, framebuffer, pixelFormat))
        }
    }
    private let compressor: ZlibEncoder
    private var tileBuffer: [UInt8] = []
    init(configuration: ZlibConfiguration = .init()) throws {
        compressor = try ZlibEncoder(configuration: configuration)
    }
    func setCompressionLevel(_ level: Int32) throws { try compressor.setCompressionLevel(level) }
    func adaptCompression(encodeDominates: Bool) throws { try compressor.adaptCompression(encodeDominates: encodeDominates) }
    func beginTransaction() throws -> Transaction { try Transaction(parent: self) }
    func commit(_ transaction: Transaction) throws { try compressor.commit(transaction.compressor) }
    func encode(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) throws -> [UInt8] {
        try compressor.encode(bytes: tiles(rect, framebuffer, pixelFormat))
    }
    private func tiles(_ rect: Rect, _ frame: Framebuffer, _ format: PixelFormat) throws -> [UInt8] {
        guard format.trueColor, [8, 16, 32].contains(format.bitsPerPixel),
              format.redShift < format.bitsPerPixel, format.greenShift < format.bitsPerPixel,
              format.blueShift < format.bitsPerPixel else { throw RFBError.unsupportedPixelFormat(format) }
        guard rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
              rect.x <= frame.width - rect.width, rect.y <= frame.height - rect.height,
              frame.bytesPerRow >= frame.width * 4,
              frame.bgra.count >= frame.bytesPerRow * frame.height else {
            throw RFBError.protocolError("ZRLE rectangle outside framebuffer")
        }
        let bound = rect.width * rect.height * format.cPixelByteCount
            + ((rect.width + 63) / 64) * ((rect.height + 63) / 64)
        tileBuffer.removeAll(keepingCapacity: true)
        tileBuffer.append(contentsOf: repeatElement(0, count: bound))
        let f = VNCZRLEFormat(max_r: format.redMax, max_g: format.greenMax, max_b: format.blueMax,
            shift_r: format.redShift, shift_g: format.greenShift, shift_b: format.blueShift,
            bytes: UInt8(format.cPixelByteCount), big_endian: format.bigEndian ? 1 : 0,
            omit_low_byte: format.cPixelOmitsLowByte ? 1 : 0)
        let used = frame.bgra.withUnsafeBufferPointer { source in
            tileBuffer.withUnsafeMutableBufferPointer { destination in
                vnc_zrle_tiles(source.baseAddress!.advanced(by: rect.y * frame.bytesPerRow + rect.x * 4),
                    frame.bytesPerRow, Int32(rect.width), Int32(rect.height), f, destination.baseAddress!, bound)
            }
        }
        guard used > 0 else { throw RFBError.protocolError("ZRLE tile construction failed") }
        tileBuffer.removeLast(tileBuffer.count - used)
        return tileBuffer
    }
}
