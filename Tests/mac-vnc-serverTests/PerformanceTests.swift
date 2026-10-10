import Foundation
import Testing
@testable import mac_vnc_server

/// Opt in with MAC_VNC_BENCHMARK=1 swift test -c release --filter framebufferBenchmark.
/// Synthetic pixels only; no desktop capture, input, or network connection.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_VNC_BENCHMARK"] == "1"))
func framebufferBenchmark() throws {
    let width = 1728, height = 1118
    let layout = VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: width, height: height)
    let frames = (0..<8).map { step -> Framebuffer in
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let row = y + step * 13
                let text = row % 24 < 12 && x % 9 < 6 && x > 100 && x < 1500
                let shade = UInt8(text ? 40 + (x / 90 + row / 24) % 80 : 238 + (x / 70 + row / 80) % 18)
                let offset = (y * width + x) * 4
                pixels[offset] = shade
                pixels[offset + 1] = shade
                pixels[offset + 2] = shade
            }
        }
        return Framebuffer(width: width, height: height, bgra: pixels, layout: layout)
    }
    let rect = Rect(x: 0, y: 0, width: width, height: height)
    func measure(_ name: String, _ operation: (Int) throws -> Int) rethrows {
        var samples: [Double] = [], totalBytes = 0
        for iteration in 0..<40 {
            let start = DispatchTime.now().uptimeNanoseconds
            let bytes = try operation(iteration % frames.count)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if iteration >= 8 { samples.append(ms); totalBytes += bytes }
        }
        samples.sort()
        print(String(format: "BENCH %@ median_ms=%.3f p95_ms=%.3f bytes=%d", name,
            samples[samples.count / 2], samples[Int(Double(samples.count) * 0.95)], totalBytes / samples.count))
    }
    for depth: UInt8 in [24, 32] {
        var format = PixelFormat.serverDefault
        format.depth = depth
        var buffer: [UInt8] = []
        try measure("raw-depth\(depth)") { index in
            try RawEncoding.encode(rect: rect, framebuffer: frames[index], pixelFormat: format, into: &buffer)
            return buffer.count
        }
        let encoder = try ZlibEncoder()
        try measure("zlib-depth\(depth)") { index in
            try encoder.encode(rect: rect, framebuffer: frames[index], pixelFormat: format).count
        }
    }
    let encoder = try ZlibEncoder()
    let compressed = try encoder.encode(rect: rect, framebuffer: frames[0], pixelFormat: .serverDefault)
    let cipher = try AppleEncryption.Cipher(keys: .random(), encrypt: true)
    try measure("encrypt-compressed-frame") { _ in
        var bytes = 0
        for offset in stride(from: 0, to: compressed.count, by: AppleEncryption.maxPayloadBytes) {
            bytes += try cipher.seal(Array(compressed[offset..<min(compressed.count, offset + AppleEncryption.maxPayloadBytes)])).count
        }
        return bytes
    }
}
