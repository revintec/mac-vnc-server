import Foundation

/// Apple's file-copy records are independent of the clipboard zlib stream.
/// See docs/apple-file-transfer.md for the wire and native-helper boundaries.
enum AppleFileTransfer {
    static let maxMessageBytes = 1_048_576
    static let maxDragBytes = 5 * 1_024 * 1_024

    struct Message {
        let version: UInt16
        let command: UInt16
        let sessionID: UInt32
        let payload: [UInt8]

        init(body: [UInt8]) throws {
            guard body.count >= 8, body.count <= maxMessageBytes else {
                throw RFBError.protocolError("invalid Apple file-copy message size")
            }
            version = UInt16.be(body[0], body[1])
            command = UInt16.be(body[2], body[3])
            sessionID = UInt32.be(body[4], body[5], body[6], body[7])
            payload = Array(body.dropFirst(8))
            guard version == 1 || version == 2 else {
                throw RFBError.protocolError("unsupported Apple file-copy version")
            }
        }

        init(command: UInt16, sessionID: UInt32, payload: [UInt8] = []) {
            version = 1
            self.command = command
            self.sessionID = sessionID
            self.payload = payload
        }

        var wire: [UInt8] {
            [0x22, 0] + UInt32(8 + payload.count).beBytes
                + version.beBytes + command.beBytes + sessionID.beBytes + payload
        }

        /// The helper framing and common fields use host endian. Item metadata
        /// and file contents remain in network endian, as in Apple's daemon.
        var receiverInput: [UInt8] {
            UInt16(2).nativeBytes + UInt32(8 + payload.count).nativeBytes
                + version.nativeBytes + command.nativeBytes + sessionID.nativeBytes + payload
        }

        func validateFileData() throws {
            switch command {
            case 100:
                guard payload.count == 52 else { throw RFBError.protocolError("invalid file item information") }
            case 101:
                guard payload.count >= 105, payload[0] == 1 || payload[0] == 2 else {
                    throw RFBError.protocolError("unsupported file item (only regular files and folders are accepted)")
                }
                let length = Int(UInt16.be(payload[100], payload[101]))
                guard length > 0, length < 1_024, payload.count >= 104 + length + 1,
                      payload[104 + length] == 0 else { throw RFBError.protocolError("invalid file item name length") }
                let name = try AppleFileTransfer.pathString(Array(payload[104..<(104 + length)]))
                guard name != ".", name != "..", !name.contains("/") else {
                    throw RFBError.protocolError("invalid file item name")
                }
            case 102:
                guard payload.count >= 4,
                      Int(UInt32.be(payload[0], payload[1], payload[2], payload[3])) == payload.count - 4 else {
                    throw RFBError.protocolError("invalid file data length")
                }
            case 103:
                guard payload.count >= 10 else { throw RFBError.protocolError("truncated compressed file data") }
                let size = UInt32.be(payload[2], payload[3], payload[4], payload[5])
                let compressedSize = UInt32.be(payload[6], payload[7], payload[8], payload[9])
                guard payload[0] == 0, payload[1] == 1, size <= 5_000_000,
                      Int(compressedSize) == payload.count - 10 else {
                    throw RFBError.protocolError("invalid compressed file data")
                }
            case 104:
                guard payload.count == 4 else { throw RFBError.protocolError("invalid file completion") }
            default: throw RFBError.protocolError("unexpected file data command")
            }
        }

        func startPath() throws -> (path: String, name: String?) {
            guard command == 1 || command == 2, payload.count >= 10 else {
                throw RFBError.protocolError("truncated Apple file-copy start")
            }
            let length = Int(UInt16.be(payload[8], payload[9]))
            let hasName = command == 2 && version >= 2
            let offset = hasName ? 12 : 10
            guard length > 0, length < 16_384, payload.count >= offset + length else {
                throw RFBError.protocolError("invalid Apple file-copy path length")
            }
            let path = try AppleFileTransfer.pathString(Array(payload[offset..<(offset + length)]))
            guard path.hasPrefix("/") else {
                throw RFBError.protocolError("Apple file-copy requires an absolute path")
            }
            if hasName {
                let nameLength = Int(UInt16.be(payload[10], payload[11]))
                let start = offset + length + 1
                guard nameLength > 0, nameLength < 1_024,
                      payload.count >= start + nameLength, payload[offset + length] == 0 else {
                    throw RFBError.protocolError("invalid Apple file-copy destination name")
                }
                let name = try AppleFileTransfer.pathString(Array(payload[start..<(start + nameLength)]))
                guard name != ".", name != "..", !name.contains("/") else {
                    throw RFBError.protocolError("invalid Apple file-copy destination name")
                }
                return (path, name)
            }
            return (path, nil)
        }
    }

    static func pathString(_ bytes: [UInt8]) throws -> String {
        let trimmed = bytes.last == 0 ? Array(bytes.dropLast()) : bytes
        guard !trimmed.isEmpty, !trimmed.contains(0), let string = String(bytes: trimmed, encoding: .utf8) else {
            throw RFBError.protocolError("invalid UTF-8 file-copy path")
        }
        return string
    }

    static func receiverStart(sessionID: UInt32, directory: URL, name: String?) -> [UInt8] {
        let path = Array(directory.path.utf8)
        let body: [UInt8]
        let common = UInt16(2).nativeBytes + sessionID.nativeBytes + UInt32(0).nativeBytes + UInt32(0).nativeBytes
        if let name {
            let bytes = Array(name.utf8)
            body = UInt16(2).nativeBytes + common + UInt16(path.count).nativeBytes
                + UInt16(bytes.count).nativeBytes + path + [0] + bytes + [0]
        } else {
            body = UInt16(1).nativeBytes + common + UInt16(path.count).nativeBytes + path + [0]
        }
        return UInt16(2).nativeBytes + UInt32(body.count).nativeBytes + body
    }

    static func receiverResult(sessionID: UInt32, status: UInt16, name: String) -> [UInt8] {
        let name = Array(name.utf8.prefix(1_023))
        return Message(command: 200, sessionID: sessionID,
                       payload: status.beBytes + UInt16(name.count).beBytes + name + [0]).wire
    }

    static func dragMessage(sessionID: UInt32, compressed: [UInt8], archiveSize: UInt32) -> [UInt8] {
        [0x20, 0, 0, 0] + sessionID.beBytes + archiveSize.beBytes
            + UInt32(compressed.count).beBytes + compressed
    }

    /// Extract only file URLs; drag images and other representations are carried
    /// unchanged to the native helper. The archive is validated before launching it.
    static func dragFiles(compressed: [UInt8], archiveSize: Int) throws -> [URL] {
        guard archiveSize <= maxDragBytes, compressed.count <= maxDragBytes else {
            throw RFBError.protocolError("Apple drag archive exceeds 5 MiB")
        }
        let raw = try AppleClipboard.inflate(compressed, expectedSize: archiveSize)
        var offset = 0
        func number() throws -> Int {
            guard raw.count - offset >= 4 else { throw RFBError.protocolError("truncated Apple drag archive") }
            defer { offset += 4 }
            return Int(UInt32.be(raw[offset], raw[offset + 1], raw[offset + 2], raw[offset + 3]))
        }
        func field() throws -> [UInt8] {
            let size = try number()
            guard size <= raw.count - offset else { throw RFBError.protocolError("invalid Apple drag field") }
            defer { offset += size }
            return Array(raw[offset..<(offset + size)])
        }
        var files: [URL] = []
        while offset < raw.count {
            let count = try number()
            guard count <= (raw.count - offset) / 16 else { throw RFBError.protocolError("invalid Apple drag flavor count") }
            for _ in 0..<count {
                let type = try field()
                _ = try number()
                let tags = try number()
                guard tags <= (raw.count - offset) / 8 else { throw RFBError.protocolError("invalid Apple drag tag count") }
                for _ in 0..<tags { _ = try field(); _ = try field() }
                let data = try field()
                if type == Array("public.file-url".utf8) {
                    let string = try pathString(data)
                    guard let url = URL(string: string), url.isFileURL,
                          url.host == nil || url.host == "" || url.host == "localhost" else {
                        throw RFBError.protocolError("invalid Apple drag file URL")
                    }
                    guard !url.path.contains("\0") else { throw RFBError.protocolError("invalid drag file path") }
                    files.append(url.standardizedFileURL)
                    guard files.count <= 256 else { throw RFBError.protocolError("too many dragged files") }
                }
            }
        }
        return files
    }
}

extension FixedWidthInteger {
    var nativeBytes: [UInt8] { withUnsafeBytes(of: self) { Array($0) } }
}
