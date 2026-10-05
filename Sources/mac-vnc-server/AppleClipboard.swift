import Foundation
import zlib

/// A separate zlib stream for each Apple pasteboard archive; never the framebuffer stream.
enum AppleClipboard {
    static let textFlavor = Array("public.utf8-plain-text".utf8)
    static let maxArchiveBytes = 16 * 1_024 * 1_024

    enum Contents: Equatable {
        case text(String)
        case promisedText
        case noText
    }

    struct Header {
        let promises: Bool
        let requestID: UInt32
        let uncompressedSize: Int
        let compressedSize: Int

        init(bytes: [UInt8]) throws {
            guard bytes.count == 15 else {
                throw RFBError.protocolError("invalid Apple clipboard header")
            }
            promises = bytes[1] & 1 != 0
            requestID = UInt32.be(bytes[3], bytes[4], bytes[5], bytes[6])
            uncompressedSize = Int(UInt32.be(bytes[7], bytes[8], bytes[9], bytes[10]))
            compressedSize = Int(UInt32.be(bytes[11], bytes[12], bytes[13], bytes[14]))
            guard uncompressedSize <= maxArchiveBytes, compressedSize <= maxArchiveBytes else {
                throw RFBError.protocolError("Apple clipboard exceeds the 16 MiB archive limit")
            }
        }
    }

    static func archive(text: String, promises: Bool = false) throws -> [UInt8] {
        // A zero-length flavor means a promise. An item with zero flavors means clear.
        guard !text.isEmpty else { return UInt32(0).beBytes }
        let overhead = 20 + textFlavor.count
        guard text.utf8.count <= maxArchiveBytes - overhead else {
            throw RFBError.protocolError("Apple clipboard text exceeds the archive limit")
        }
        let data = promises ? [] : Array(text.utf8)
        return UInt32(1).beBytes + UInt32(textFlavor.count).beBytes + textFlavor
            + UInt32(0).beBytes + UInt32(0).beBytes + UInt32(data.count).beBytes + data
    }

    static func message(text: String, requestID: UInt32, promises: Bool = false) throws -> [UInt8] {
        let raw = try archive(text: text, promises: promises)
        let compressed = try compress(raw)
        guard compressed.count <= maxArchiveBytes else {
            throw RFBError.protocolError("compressed Apple clipboard exceeds the archive limit")
        }
        return [0x1f, 0, promises ? 1 : 0, 0] + requestID.beBytes
            + UInt32(raw.count).beBytes + UInt32(compressed.count).beBytes + compressed
    }

    static func decode(header: Header, compressed: [UInt8]) throws -> Contents {
        guard compressed.count == header.compressedSize else {
            throw RFBError.protocolError("Apple clipboard compressed length mismatch")
        }
        return try parseArchive(inflate(compressed, expectedSize: header.uncompressedSize))
    }

    static func parseArchive(_ bytes: [UInt8]) throws -> Contents {
        guard bytes.count <= maxArchiveBytes else {
            throw RFBError.protocolError("Apple clipboard archive is too large")
        }
        var reader = ArchiveReader(bytes: bytes)
        var text: String?
        var promisedText = false
        var hasFlavors = false
        // There is no outer item count. Items run to the end of the archive.
        while !reader.atEnd {
            let flavors = try reader.number()
            // Even an empty flavor needs four u32 fields. Bound counts before looping.
            guard flavors <= reader.remaining / 16 else {
                throw RFBError.protocolError("invalid Apple clipboard flavor count")
            }
            hasFlavors = hasFlavors || flavors > 0
            for _ in 0..<flavors {
                let name = try reader.countedBytes()
                _ = try reader.number() // reserved
                let tags = try reader.number()
                guard tags <= reader.remaining / 8 else {
                    throw RFBError.protocolError("invalid Apple clipboard tag count")
                }
                for _ in 0..<tags {
                    _ = try reader.countedBytes()
                    _ = try reader.countedBytes()
                }
                let data = try reader.countedBytes()
                if name.elementsEqual(textFlavor) {
                    if data.isEmpty {
                        promisedText = true
                    } else if text == nil {
                        guard let value = String(bytes: data, encoding: .utf8) else {
                            throw RFBError.protocolError("invalid UTF-8 in Apple clipboard")
                        }
                        text = value
                    }
                }
            }
        }
        if let text { return .text(text) }
        if promisedText { return .promisedText }
        return hasFlavors ? .noText : .text("")
    }

    private struct ArchiveReader {
        let bytes: [UInt8]
        var offset = 0
        var remaining: Int { bytes.count - offset }
        var atEnd: Bool { remaining == 0 }

        mutating func number() throws -> Int {
            guard remaining >= 4 else {
                throw RFBError.protocolError("truncated Apple clipboard archive")
            }
            defer { offset += 4 }
            return Int(UInt32.be(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]))
        }

        mutating func countedBytes() throws -> ArraySlice<UInt8> {
            let count = try number()
            guard count <= remaining else {
                throw RFBError.protocolError("invalid Apple clipboard field length")
            }
            defer { offset += count }
            return bytes[offset..<(offset + count)]
        }
    }

    static func compress(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count <= maxArchiveBytes else {
            throw RFBError.protocolError("Apple clipboard archive is too large")
        }
        var stream = z_stream()
        guard deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION,
                          Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RFBError.protocolError("Apple clipboard deflate initialization failed")
        }
        defer { deflateEnd(&stream) }
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 * 1_024)
        try bytes.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(bytes.count)
            repeat {
                let status = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return zlib.deflate(&stream, Z_SYNC_FLUSH)
                }
                if status == Z_BUF_ERROR && stream.avail_in == 0 && stream.avail_out == chunk.count {
                    // The previous chunk ended exactly at the completed sync flush.
                    break
                }
                guard status == Z_OK else {
                    throw RFBError.protocolError("Apple clipboard deflate failed: \(status)")
                }
                output.append(contentsOf: chunk.prefix(chunk.count - Int(stream.avail_out)))
            } while stream.avail_in > 0 || stream.avail_out == 0
        }
        return output
    }

    static func inflate(_ bytes: [UInt8], expectedSize: Int) throws -> [UInt8] {
        guard expectedSize >= 0, expectedSize <= maxArchiveBytes,
              bytes.count <= maxArchiveBytes, !bytes.isEmpty else {
            throw RFBError.protocolError("invalid Apple clipboard compressed archive size")
        }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RFBError.protocolError("Apple clipboard inflate initialization failed")
        }
        defer { inflateEnd(&stream) }
        // One extra byte detects output larger than the declared size, including zero.
        var output = [UInt8](repeating: 0, count: expectedSize + 1)
        let status = bytes.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(bytes.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return zlib.inflate(&stream, Z_SYNC_FLUSH)
            }
        }
        guard (status == Z_OK || status == Z_STREAM_END), stream.avail_in == 0,
              stream.total_out == expectedSize else {
            throw RFBError.protocolError("invalid or truncated Apple clipboard zlib archive")
        }
        // Apple's unfinished stream ends on a sync flush; also accept a complete stream.
        guard status == Z_STREAM_END || bytes.suffix(4).elementsEqual([0, 0, 0xff, 0xff]) else {
            throw RFBError.protocolError("Apple clipboard archive is missing its sync flush")
        }
        output.removeLast()
        return output
    }
}
