import Foundation

/// Apple's RFB extensions, deliberately limited to control and text pasteboard support.
/// Wire reference and interoperability limits: docs/apple-clipboard.md.
enum AppleRFB {
    static let version = "RFB 003.889\n"
    static let maxViewerInfoBytes = 4_096

    /// 3.889 numbers buttons as CGMouseButton: left, right, middle.
    /// The input bridge uses standard RFB order: left, middle, right.
    static func standardButtonMask(_ appleMask: UInt8) -> UInt8 {
        (appleMask & ~0x06) | ((appleMask & 0x02) << 1) | ((appleMask & 0x04) >> 1)
    }

    static func supports(_ message: Int, bitmap: [UInt8]) -> Bool {
        message >= 0 && message / 8 < bitmap.count
            && bitmap[message / 8] & (0x80 >> (message % 8)) != 0
    }

    static func desktopName(_ name: String) -> [UInt8] {
        var bitmap = [UInt8](repeating: 0, count: 16)
        // Do not advertise Apple's encrypted records, virtual displays or private codecs.
        for message in [0, 2, 3, 4, 5, 6, 0x09, 0x0a, 0x0b, 0x15, 0x1f, 0x21] {
            bitmap[message / 8] |= 0x80 >> (message % 8)
        }
        // Extended ServerInit, with control privilege available.
        return UInt16(0).beBytes + UInt32(0x12).beBytes + bitmap + Array(name.utf8)
    }

    static func viewerCapabilities(body: [UInt8]) throws -> [UInt8] {
        // Numeric application class/id, app version and OS version occupy 30 bytes.
        // Respect the declared message length so an unknown tail cannot desync RFB.
        guard body.count >= 62, body.count <= maxViewerInfoBytes else {
            throw RFBError.protocolError("unsupported Apple ViewerInfo length \(body.count)")
        }
        return Array(body[30..<62])
    }

    static func status(_ command: UInt16) -> [UInt8] {
        [0x14, 0, 0, 4, 0, 1] + command.beBytes
    }
}
