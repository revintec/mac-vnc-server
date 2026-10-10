import Foundation
import Testing
import zlib
@testable import mac_vnc_server

@Test(arguments: ZlibBackend.allCases)
func zlibBackendKeepsStreamAcrossLevelsAndTransactions(backend: ZlibBackend) throws {
    let width = 257, height = 97
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: width, height: height)
    var seed: UInt32 = 123456789
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for index in pixels.indices where index % 4 != 3 {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        pixels[index] = UInt8(truncatingIfNeeded: seed)
    }
    let frame = Framebuffer(width: width, height: height, bgra: pixels, layout: layout)
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    let expected = try RawEncoding.encode(rect: rect, framebuffer: frame, pixelFormat: .serverDefault)
    let encoder = try ZlibEncoder(configuration: .init(backend: backend))
    var payloads: [[UInt8]] = []
    for level: Int32 in [backend.fastLevel, 0, 1, 3, 9, 0, 2] {
        try encoder.setCompressionLevel(level)
        // Compression of this random frame exceeds the 16 KiB scratch buffer.
        payloads.append(try encoder.encode(rect: rect, framebuffer: frame, pixelFormat: .serverDefault))
        do {
            let discarded = try encoder.beginTransaction()
            _ = try discarded.encode(rect: Rect(x: 3, y: 7, width: 199, height: 79),
                                     framebuffer: frame, pixelFormat: .serverDefault)
        }
        let committed = try encoder.beginTransaction()
        payloads.append(try committed.encode(rect: rect, framebuffer: frame, pixelFormat: .serverDefault))
        try encoder.commit(committed)
        // The committed transaction retains its own state; subsequent work on
        // it must not change what the next live payload's dictionary references.
        _ = try committed.encode(rect: Rect(x: 1, y: 2, width: 213, height: 83),
                                 framebuffer: frame, pixelFormat: .serverDefault)
        payloads.append(try encoder.encode(rect: rect, framebuffer: frame, pixelFormat: .serverDefault))
    }

    // Decode every rectangle at its flush boundary with Apple's zlib, keeping
    // the decoder alive for all updates and checking complete input consumption.
    var decoder = z_stream()
    try #require(inflateInit_(&decoder, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    defer { inflateEnd(&decoder) }
    for payload in payloads {
        #expect(Int(UInt32.be(payload[0], payload[1], payload[2], payload[3])) == payload.count - 4)
        var decoded = [UInt8](repeating: 0, count: expected.count + 1)
        let status = payload.withUnsafeBytes { input in
            decoded.withUnsafeMutableBytes { output in
                decoder.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress!.advanced(by: 4))
                decoder.avail_in = UInt32(input.count - 4)
                decoder.next_out = output.bindMemory(to: Bytef.self).baseAddress
                decoder.avail_out = UInt32(output.count)
                return inflate(&decoder, Z_SYNC_FLUSH)
            }
        }
        #expect(status == Z_OK)
        #expect(decoder.avail_in == 0)
        #expect(decoder.avail_out == 1)
        #expect(Array(decoded.dropLast()) == expected)
    }
}

@Test(arguments: ZlibBackend.allCases)
func zlibAdaptiveLevelUsesBackendAndHonorsOverride(backend: ZlibBackend) throws {
    let adaptive = try ZlibEncoder(configuration: .init(backend: backend))
    #expect(adaptive.compressionLevel == backend.fastLevel)
    try adaptive.adaptCompression(encodeDominates: false)
    #expect(adaptive.compressionLevel == 3)
    try adaptive.adaptCompression(encodeDominates: true)
    #expect(adaptive.compressionLevel == backend.fastLevel)
    let fixed = try ZlibEncoder(configuration: .init(backend: backend, level: 0))
    try fixed.adaptCompression(encodeDominates: false)
    #expect(fixed.compressionLevel == 0)
    #expect(throws: (any Error).self) { try fixed.setCompressionLevel(10) }
    #expect(throws: (any Error).self) { try ZlibEncoder(configuration: .init(backend: backend, level: -1)) }
}

@Test func zlibTransactionRejectsDifferentOwner() throws {
    let first = try ZlibEncoder()
    let second = try ZlibEncoder()
    let transaction = try first.beginTransaction()
    #expect(throws: (any Error).self) { try second.commit(transaction) }
}

@Test func zlibOptionsParseAndPersistInServiceArguments() throws {
    guard case .run(let defaults) = try CLI.parse(arguments: ["run"]) else {
        Issue.record("expected run config"); return
    }
    #expect(defaults.zlibConfiguration.backend == .zlibNG)
    #expect(defaults.zlibConfiguration.initialLevel == 2)
    #expect(defaults.zlibConfiguration.level == nil)
    guard case .service(let config, let args) = try CLI.parse(arguments: [
        "run", "--service", "--zlib-backend", "system", "--zlib-level", "0"
    ]) else { Issue.record("expected service config"); return }
    #expect(config.zlibConfiguration.backend == .system)
    #expect(config.zlibConfiguration.level == 0)
    #expect(args == ["--zlib-backend", "system", "--zlib-level", "0"])
    guard case .run(let automatic) = try CLI.parse(arguments: [
        "run", "--zlib-level", "9", "--zlib-level", "auto", "--zlib-backend", "system"
    ]) else { Issue.record("expected automatic config"); return }
    #expect(automatic.zlibConfiguration.level == nil)
    #expect(automatic.zlibConfiguration.initialLevel == 1)
}

@Test(arguments: [
    ["--zlib-level"], ["--zlib-level", "-1"], ["--zlib-level", "10"],
    ["--zlib-level", "fast"], ["--zlib-backend"], ["--zlib-backend", "unknown"]
])
func zlibOptionsRejectInvalidValues(arguments: [String]) {
    #expect(throws: (any Error).self) { try CLI.parse(arguments: arguments) }
}
