// Used only in a disposable server source copy. No UI or screen capture.
import CoreGraphics
import CoreText
import Darwin
import Foundation

enum CodecComparison {
    static func frame(_ kind: String, index: Int, width: Int, height: Int) -> Framebuffer {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        if kind == "document" {
            bytes.withUnsafeMutableBytes { storage in
                let context = CGContext(data: storage.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
                context.setFillColor(CGColor(gray: 0.96, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let font = CTFontCreateWithName("Menlo" as CFString, 16, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1)
                ]
                for line in 0..<34 {
                    let text = String(format: "%05d  func pipeline_%03d(frame: Framebuffer) -> Response { return encode(frame) }", line + index, (line + index) % 997)
                    context.textPosition = CGPoint(x: 24, y: height - 30 - line * 26 + (index * 13) % 26)
                    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
                }
            }
        } else {
            for y in 0..<height { for x in 0..<width {
                let p = (y * width + x) * 4
                let color: UInt8
                switch kind {
                case "solid": color = UInt8(160 + index % 20)
                case "two-color": color = ((x + index * 3) / 8 + y / 8) % 2 == 0 ? 20 : 240
                case "palette-runs": color = UInt8(((x + index * 3) / 10) % 4 * 60)
                case "many-colors": color = UInt8((x + y + index) % 32 * 7)
                default: fatalError("unknown fixture")
                }
                bytes[p] = color; bytes[p + 1] = color; bytes[p + 2] = color
            }}
        }
        for p in stride(from: 3, to: bytes.count, by: 4) { bytes[p] = 0 }
        return Framebuffer(width: width, height: height, bgra: bytes,
            layout: VirtualDisplayLayout(displays: [], origin: .zero, scale: 1, width: width, height: height))
    }

    static func run(output: String) throws {
        let root = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var results: [[String: Any]] = []
        let width = 1024, height = 768, framesPerPass = 20, fixtureCount = 4
        var format = PixelFormat.serverDefault; format.depth = 32
        // Full visible region, split into twelve identical bands for both codecs.
        let rects = stride(from: 0, to: height, by: 64).map { Rect(x: 0, y: $0, width: width, height: 64) }
        for kind in ["solid", "two-color", "palette-runs", "many-colors", "document"] {
            let frames = (0..<fixtureCount).map { frame(kind, index: $0, width: width, height: height) }
            for (index, frame) in frames.enumerated() {
                try Data(frame.bgra).write(to: root.appendingPathComponent("\(kind)-\(index).bgra"))
            }
            for pass in 0..<2 {
                // Alternate order to reduce systematic warmup/order bias.
                for codec in (pass == 0 ? ["zlib", "zrle"] : ["zrle", "zlib"]) {
                    let zlibEncoder = try ZlibEncoder(configuration: .init(backend: .zlibNG, level: 2))
                    let zrleEncoder = try ZRLEEncoder()
                    var samples: [[String: Any]] = []
                    var payloads = Data()
                    for index in 0..<(fixtureCount + framesPerPass) {
                        let frame = frames[index % fixtureCount]
                        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                        let rectangles = try rects.map { rect in
                            if codec == "zlib" { return try zlibEncoder.encode(rect: rect, framebuffer: frame, pixelFormat: format) }
                            return try zrleEncoder.encode(rect: rect, framebuffer: frame, pixelFormat: format)
                        }
                        let elapsedCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu
                        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
                        // File IO, fixture creation and validation are outside timing.
                        for payload in rectangles { payloads.append(contentsOf: payload) }
                        samples.append(["fixture": index % fixtureCount, "warmup": index < fixtureCount,
                            "wall_ms": Double(elapsed) / 1e6, "cpu_ms": Double(elapsedCPU) / 1e6,
                            "payload_bytes": rectangles.reduce(0) { $0 + $1.count }])
                    }
                    let name = "\(kind)-\(codec)-\(pass)"
                    try payloads.write(to: root.appendingPathComponent(name + ".payloads"))
                    results.append(["name": name, "scenario": kind, "codec": codec, "pass": pass,
                        "width": width, "height": height, "depth": 32, "rect_height": 64, "samples": samples])
                    print("codec comparison completed: \(name)")
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("timings.json"))
    }
}
