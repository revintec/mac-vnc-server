import CVNCZlib
import Foundation
import zlib

enum ZlibBackend: String, CaseIterable, Sendable {
    case zlibNG = "zlib-ng"
    case system

    // zlib-ng's level 1 uses deflate_quick; level 2 is its fast match-search mode.
    var fastLevel: Int32 { self == .zlibNG ? 2 : 1 }
    var version: String { String(cString: vnc_zlib_version(self == .zlibNG ? 1 : 0)) }
}

struct ZlibConfiguration: Sendable {
    var backend: ZlibBackend = .zlibNG
    var level: Int32?

    var initialLevel: Int32 { level ?? backend.fastLevel }
}

final class ZlibEncoder {
    final class Transaction {
        fileprivate unowned let parent: ZlibEncoder
        fileprivate let stream: DeflateStream

        fileprivate init(parent: ZlibEncoder) throws {
            self.parent = parent
            stream = try parent.stream.copy()
        }

        func encode(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) throws -> [UInt8] {
            try parent.encode(rect: rect, framebuffer: framebuffer, pixelFormat: pixelFormat, stream: stream)
        }
    }

    // The C adapter owns streams at stable addresses and never retains Swift
    // buffer pointers. A copy includes pending parameter-change output.
    fileprivate final class DeflateStream {
        let handle: OpaquePointer
        var level: Int32
        var pendingOutput: [UInt8] = []

        init(configuration: ZlibConfiguration) throws {
            let level = configuration.initialLevel
            guard (0...9).contains(level) else {
                throw RFBError.protocolError("invalid zlib compression level \(level)")
            }
            var status: Int32 = Z_OK
            guard let handle = vnc_zlib_create(configuration.backend == .zlibNG ? 1 : 0, level, &status) else {
                throw RFBError.protocolError("zlib deflateInit failed with status \(status)")
            }
            self.handle = handle
            self.level = level
        }

        private init(handle: OpaquePointer, level: Int32, pendingOutput: [UInt8]) {
            self.handle = handle
            self.level = level
            self.pendingOutput = pendingOutput
        }

        deinit { vnc_zlib_destroy(handle) }

        func copy() throws -> DeflateStream {
            var status: Int32 = Z_OK
            guard let copy = vnc_zlib_copy(handle, &status) else {
                throw RFBError.protocolError("zlib deflateCopy failed with status \(status)")
            }
            return DeflateStream(handle: copy, level: level, pendingOutput: pendingOutput)
        }
    }

    private let configuration: ZlibConfiguration
    private var stream: DeflateStream
    private var rawBuffer: [UInt8] = []
    private var outputChunk = [UInt8](repeating: 0, count: 16 * 1024)
    var compressionLevel: Int32 { stream.level }

    init(configuration: ZlibConfiguration = .init()) throws {
        self.configuration = configuration
        stream = try DeflateStream(configuration: configuration)
    }

    // An explicit CLI level is fixed; automatic selection is backend-specific.
    func adaptCompression(encodeDominates: Bool) throws {
        guard configuration.level == nil else { return }
        try setCompressionLevel(encodeDominates ? configuration.backend.fastLevel : 3)
    }

    func setCompressionLevel(_ level: Int32) throws {
        guard (0...9).contains(level) else {
            throw RFBError.protocolError("invalid zlib compression level \(level)")
        }
        guard level != stream.level else { return }

        while true {
            var produced = UInt32(outputChunk.count)
            let status = outputChunk.withUnsafeMutableBufferPointer { output in
                vnc_zlib_params(stream.handle, level, output.baseAddress, &produced)
            }
            stream.pendingOutput.append(contentsOf: outputChunk.prefix(Int(produced)))
            if status == Z_OK { break }
            // deflateParams may fill the output before applying the new level.
            guard status == Z_BUF_ERROR, produced > 0 else {
                throw RFBError.protocolError("zlib deflateParams failed with status \(status)")
            }
        }
        stream.level = level
    }

    func beginTransaction() throws -> Transaction {
        try Transaction(parent: self)
    }

    func commit(_ transaction: Transaction) throws {
        guard transaction.parent === self else {
            throw RFBError.protocolError("zlib transaction belongs to another encoder")
        }
        // Clone successfully before releasing the live state. The transaction
        // retains independent ownership and cannot mutate a committed stream.
        stream = try transaction.stream.copy()
    }

    func encode(rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat) throws -> [UInt8] {
        try encode(rect: rect, framebuffer: framebuffer, pixelFormat: pixelFormat, stream: stream)
    }

    private func encode(
        rect: Rect, framebuffer: Framebuffer, pixelFormat: PixelFormat, stream: DeflateStream
    ) throws -> [UInt8] {
        try RawEncoding.encode(rect: rect, framebuffer: framebuffer, pixelFormat: pixelFormat, into: &rawBuffer)
        guard rawBuffer.count <= Int(UInt32.max) else {
            throw RFBError.protocolError("zlib rectangle exceeds the input size limit")
        }
        // Build the length-prefixed payload directly, avoiding a second complete
        // compressed-array copy solely to prepend the RFB length.
        var output: [UInt8] = [0, 0, 0, 0]
        output.reserveCapacity(max(1024, rawBuffer.count / 3) + stream.pendingOutput.count + 4)
        output.append(contentsOf: stream.pendingOutput)
        stream.pendingOutput.removeAll(keepingCapacity: true)

        try rawBuffer.withUnsafeBufferPointer { input in
            var consumed = 0
            while true {
                var inputCount = UInt32(input.count - consumed)
                var produced = UInt32(outputChunk.count)
                let status = outputChunk.withUnsafeMutableBufferPointer { scratch in
                    vnc_zlib_process(
                        stream.handle, input.baseAddress?.advanced(by: consumed), &inputCount,
                        scratch.baseAddress, &produced
                    )
                }
                // A final call after an exactly full flush buffer can report
                // Z_BUF_ERROR with no input/output. It means the flush is drained.
                guard status == Z_OK || (status == Z_BUF_ERROR && consumed == input.count && produced == 0) else {
                    throw RFBError.protocolError("zlib deflate failed with status \(status)")
                }
                consumed += Int(inputCount)
                output.append(contentsOf: outputChunk.prefix(Int(produced)))
                if consumed == input.count && produced < outputChunk.count { break }
                guard inputCount > 0 || produced > 0 else {
                    throw RFBError.protocolError("zlib deflate made no progress")
                }
            }
        }
        guard let length = UInt32(exactly: output.count - 4) else {
            throw RFBError.protocolError("zlib rectangle exceeds the output size limit")
        }
        output.replaceSubrange(0..<4, with: length.beBytes)
        return output
    }
}
