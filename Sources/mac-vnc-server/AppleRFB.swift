import Foundation

/// Apple's RFB extensions for control, display scaling, pasteboard and file transfers.
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

    static func desktopName(_ name: String, fileTransfer: Bool = false, allowEncryptedInput: Bool = true) -> [UInt8] {
        var bitmap = [UInt8](repeating: 0, count: 16)
        // Virtual displays and private codecs are not implemented.
        for message in [0, 2, 3, 4, 5, 6, 0x09, 0x0a, 0x0b, 0x15, 0x1f, 0x21] {
            bitmap[message / 8] |= 0x80 >> (message % 8)
        }
        if fileTransfer {
            // Screen Sharing uses SetEncryption as a native-server capability
            // gate even when it does not request encrypted records.
            for message in [0x08, 0x0e, 0x12, 0x20, 0x22] { bitmap[message / 8] |= 0x80 >> (message % 8) }
            // Plaintext sessions omit encrypted input and use security type 2.
            // Type 30 enables encrypted keys even when this bit is omitted.
            if allowEncryptedInput { bitmap[0x10 / 8] |= 0x80 >> (0x10 % 8) }
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

    static let displayInfoEncoding: Int32 = 1101
    static let displayLayoutEncoding: Int32 = 1105

    /// Native macOS prefers DisplayInfo2 regardless of SetEncodings order.
    static func preferredDisplayEncoding(in encodings: [Int32]) -> Int32? {
        if encodings.contains(displayLayoutEncoding) { return displayLayoutEncoding }
        if encodings.contains(displayInfoEncoding) { return displayInfoEncoding }
        return nil
    }

    /// DisplayInfo2 version 5: counted header and one 56-byte display record.
    /// This port presents its captured desktop as one screen at density 1.
    /// Logical coordinates remain unscaled; backing bounds describe the pixels
    /// actually transmitted. Session bit 2 identifies the console session.
    static func displayLayout(width: Int, height: Int, unscaledWidth: Int, unscaledHeight: Int,
                              scale: Double) -> [UInt8] {
        let nativeWidth = UInt16(clamping: unscaledWidth), nativeHeight = UInt16(clamping: unscaledHeight)
        let width = UInt16(clamping: width), height = UInt16(clamping: height)
        let rectangle = [UInt8](repeating: 0, count: 4) + width.beBytes + height.beBytes
            + UInt32(bitPattern: displayLayoutEncoding).beBytes
        var payload = UInt16(5).beBytes + nativeWidth.beBytes + nativeHeight.beBytes
        payload += width.beBytes + height.beBytes
        payload += UInt32.max.beBytes + UInt32(0x04).beBytes + UInt16(1).beBytes
        for factor in [1.0, scale] {
            payload += stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: factor.bitPattern >> $0) }
        }
        payload += UInt32(1).beBytes // stable logical display ID
        payload += [0, 0, 0, 0] + nativeHeight.beBytes + nativeWidth.beBytes
        payload += [0, 0, 0, 0] + height.beBytes + width.beBytes
        payload += UInt32(1).beBytes + PixelFormat.serverDefault.bytes // main display
        // The length excludes the prefix itself, unlike some Apple messages.
        return [0, 0, 0, 1] + rectangle + UInt16(payload.count).beBytes + payload
    }

    /// One logical screen represents the framebuffer selected by this port.
    /// Apple waits for this metadata before declaring a native session ready.
    /// The rectangle describes transmitted pixels; the body retains unscaled
    /// desktop coordinates, which Apple also uses for pointer events.
    static func displayInfo(width: Int, height: Int, unscaledWidth: Int? = nil, unscaledHeight: Int? = nil) -> [UInt8] {
        let nativeWidth = UInt16(clamping: unscaledWidth ?? width)
        let nativeHeight = UInt16(clamping: unscaledHeight ?? height)
        let width = UInt16(clamping: width), height = UInt16(clamping: height)
        let rectangle = [UInt8](repeating: 0, count: 4) + width.beBytes + height.beBytes
            + UInt32(bitPattern: displayInfoEncoding).beBytes
        let header = nativeWidth.beBytes + nativeHeight.beBytes + UInt32(0).beBytes + UInt16(1).beBytes
        let screen = UInt32(1).beBytes + nativeWidth.beBytes + nativeHeight.beBytes + UInt32(0).beBytes
            + UInt32(0).beBytes + UInt32(0).beBytes + UInt32(nativeWidth).beBytes + UInt32(nativeHeight).beBytes
        return [0, 0, 0, 1] + rectangle + header + screen
    }
}
