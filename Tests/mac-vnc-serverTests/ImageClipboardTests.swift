import AppKit
import Foundation
import ImageIO
import Testing
@testable import mac_vnc_server

@Suite(.serialized)
struct ImageClipboardTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!

    @Test(arguments: [
        "com.compuserve.gif", "com.microsoft.bmp", "org.webmproject.webp",
        "public.heic", "public.heif", "public.avif", "public.jpeg-2000"
    ])
    func additionalFormatsPreserveOpaqueBytesAndPromises(type: String) throws {
        // Clipboard transport must not depend on the host's image decoders.
        // Exercise all byte values rather than using a transcoded image here.
        let data = Data((0...255).map { UInt8($0) })
        let content = ClipboardContent(items: [[.init(type: type, data: data)]])
        for promises in [true, false] {
            let message = try AppleClipboard.message(content: content, requestID: 124, promises: promises)
            let header = try AppleClipboard.Header(bytes: Array(message[1..<16]))
            let received = try #require(AppleClipboard.decode(header: header, compressed: Array(message.dropFirst(16))).supportedContent)
            #expect(received == ClipboardContent(items: [[.init(type: type, data: promises ? nil : data)]]))
            #expect(received.hasImages)
        }

        let board = NSPasteboard(name: .init("mac-vnc-formats-\(UUID())"))
        defer { board.releaseGlobally() }
        let writer = MacClipboard(pasteboard: board)
        let observer = MacClipboard(pasteboard: board)
        let classic = MacClipboard(pasteboard: board)
        writer.setRemoteContent(content)
        #expect(writer.currentContent() == content)
        #expect(observer.localContentIfChanged() == content)
        #expect(classic.localTextIfChanged() == nil)
        let generation = board.changeCount
        observer.setRemoteContent(content)
        #expect(board.changeCount == generation)
        #expect(writer.localContentIfChanged() == nil)
    }

    private func animatedGIF() throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for (index, color) in [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                               CGColor(red: 0, green: 0, blue: 1, alpha: 1)].enumerated() {
            let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                                bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            let image = try #require(context.makeImage())
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: Double(index + 1) / 10]
            ] as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func animatedGIFSurvivesPasteboardAndArchiveRoundTripWithStaticFallback() throws {
        let source = NSPasteboard(name: .init("mac-vnc-gif-source-\(UUID())"))
        let target = NSPasteboard(name: .init("mac-vnc-gif-target-\(UUID())"))
        defer { source.releaseGlobally(); target.releaseGlobally() }
        let gif = try animatedGIF()
        let item = NSPasteboardItem()
        item.setData(gif, forType: .init("com.compuserve.gif"))
        item.setData(png, forType: .png)
        item.setString("animated image", forType: .string)
        #expect(source.writeObjects([item]))
        let content = try #require(MacClipboard(pasteboard: source).currentContent())
        #expect(content.items.first?.count == 3)
        let message = try AppleClipboard.message(content: content, requestID: 125)
        let header = try AppleClipboard.Header(bytes: Array(message[1..<16]))
        let received = try #require(AppleClipboard.decode(header: header, compressed: Array(message.dropFirst(16))).supportedContent)
        let receiver = MacClipboard(pasteboard: target)
        receiver.setRemoteContent(received)
        #expect(receiver.currentContent() == content)
        #expect(target.data(forType: .png) == png)
        #expect(target.string(forType: .string) == "animated image")
        let receivedGIF = try #require(target.data(forType: .init("com.compuserve.gif")))
        #expect(receivedGIF == gif)
        let frames = try #require(CGImageSourceCreateWithData(receivedGIF as CFData, nil))
        #expect(CGImageSourceGetCount(frames) == 2)
        let properties = try #require(CGImageSourceCopyProperties(frames, nil) as? [CFString: Any])
        let gifProperties = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect(gifProperties[kCGImagePropertyGIFLoopCount] as? Int == 0)
        for index in 0..<2 {
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(frames, index, nil) as? [CFString: Any])
            let gifProperties = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            #expect(gifProperties[kCGImagePropertyGIFDelayTime] as? Double == Double(index + 1) / 10)
            #expect(CGImageSourceCreateImageAtIndex(frames, index, nil) != nil)
        }
    }

    @Test func archivesPreserveImageRepresentationsAndText() throws {
        let content = ClipboardContent(items: [[
            .init(type: "public.png", data: png),
            .init(type: ClipboardContent.textType, data: Data("caption".utf8)),
            .init(type: "public.tiff", data: Data([0x49, 0x49, 42, 0]))
        ], [.init(type: "public.jpeg", data: Data([0xff, 0xd8, 0xff, 0xd9]))]])
        for promises in [false, true] {
            let message = try AppleClipboard.message(content: content, requestID: 123, promises: promises)
            let header = try AppleClipboard.Header(bytes: Array(message[1..<16]))
            let decoded = try #require(AppleClipboard.decode(header: header, compressed: Array(message.dropFirst(16))).supportedContent)
            #expect(header.requestID == 123)
            #expect(decoded.items.map { $0.map(\.type) } == content.items.map { $0.map(\.type) })
            #expect(decoded.hasPromises == promises)
            if !promises { #expect(decoded == content) }
        }
    }

    @Test func pasteboardRoundTripSuppressesImageEchoAndSkipsClassicImageUpdate() throws {
        let board = NSPasteboard(name: .init("mac-vnc-images-\(UUID())"))
        defer { board.releaseGlobally() }
        let first = MacClipboard(pasteboard: board)
        let second = MacClipboard(pasteboard: board)
        let classic = MacClipboard(pasteboard: board)
        let content = ClipboardContent(items: [[.init(type: "public.png", data: png)]])
        first.setRemoteContent(content)
        #expect(board.data(forType: .png) == png)
        #expect(first.currentContent() == content)
        #expect(first.localContentIfChanged() == nil)
        #expect(second.localContentIfChanged() == content)
        #expect(classic.localTextIfChanged() == nil)
        let generation = board.changeCount
        second.setRemoteContent(content)
        #expect(board.changeCount == generation)
        #expect(first.localContentIfChanged() == nil)
        second.setRemoteContent(.empty)
        #expect(first.localContentIfChanged() == .empty)
        #expect(board.data(forType: .png) == nil)
    }

    @Test func fetchWaitsForPromisedImageAndClearSupersedesIt() throws {
        let peer = try ClipboardTestPeer()
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.enableAppleClipboard()
        let image = ClipboardContent(items: [[.init(type: "public.png", data: png)]])
        try peer.write(AppleClipboard.message(content: image, requestID: 0, promises: true))
        #expect(try peer.read(8) == AppleRFB.status(3))
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 80])
        #expect(!peer.hasData(timeout: 0.2))
        try peer.write([0x1f, 0, 1, 0] + [UInt8](repeating: 0, count: 12))
        let cleared = try peer.readClipboard()
        #expect(cleared.0.requestID == 80)
        #expect(cleared.1 == .text(""))
        #expect(!peer.hasData(timeout: 0.2))
    }

    @Test func localCopySupersedesADelayedImageResponse() throws {
        let peer = try ClipboardTestPeer()
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.enableAppleClipboard()
        let image = ClipboardContent(items: [[.init(type: "public.png", data: png)]])
        try peer.write(AppleClipboard.message(content: image, requestID: 0, promises: true))
        #expect(try peer.read(8) == AppleRFB.status(3))
        peer.clipboard.copyLocal("newer server copy")
        #expect(try peer.read(8) == AppleRFB.status(2))
        try peer.write(AppleClipboard.message(content: image, requestID: 0))
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 82])
        #expect(try peer.readClipboard().1 == .text("newer server copy"))
    }

    @Test func fullImageReplyCanOmitAnUnavailableRepresentation() throws {
        let peer = try ClipboardTestPeer()
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.enableAppleClipboard()
        let image = ClipboardContent(items: [[.init(type: "public.png", data: png), .init(type: "public.tiff", data: nil)]])
        try peer.write(AppleClipboard.message(content: image, requestID: 0))
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 81])
        #expect(try peer.readClipboard().1.supportedContent == image.resolved)
    }

    @Test func imageArchivesCanExceedTheClassicTextLimit() throws {
        let image = ClipboardContent(items: [[.init(type: "public.tiff", data: Data(repeating: 0xa5, count: 17 * 1_024 * 1_024))]])
        let message = try AppleClipboard.message(content: image, requestID: 0)
        let header = try AppleClipboard.Header(bytes: Array(message[1..<16]))
        #expect(try AppleClipboard.decode(header: header, compressed: Array(message.dropFirst(16))).supportedContent == image)
    }

    @Test(arguments: ["public.png", "com.compuserve.gif"])
    func imagePromisesTransferInBothDirectionsWithoutFramebufferRequests(type: String) throws {
        let peer = try ClipboardTestPeer()
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.enableAppleClipboard()
        let imageData = try type == "com.compuserve.gif" ? animatedGIF() : png
        let serverImage = ClipboardContent(items: [[.init(type: type, data: imageData)]])
        peer.clipboard.copyLocal(serverImage)
        #expect(try peer.read(8) == [0x14, 0, 0, 4, 0, 1, 0, 2])
        try peer.write([0x0b, 1, 0, 0, 0, 0, 0, 61])
        let promised = try #require(peer.readClipboard().1.supportedContent)
        #expect(promised.hasImages && promised.hasPromises)
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 62])
        #expect(try peer.readClipboard().1.supportedContent == serverImage)

        let clientImage = ClipboardContent(items: [[
            .init(type: type, data: imageData),
            .init(type: ClipboardContent.textType, data: Data("client image".utf8))
        ]])
        try peer.write(AppleClipboard.message(content: clientImage, requestID: 0, promises: true))
        #expect(try peer.read(8) == [0x14, 0, 0, 4, 0, 1, 0, 3])
        #expect(peer.clipboard.currentContent() == serverImage)
        try peer.write(AppleClipboard.message(content: clientImage, requestID: 0))
        try peer.write([0x0b, 0, 0, 0, 0, 0, 0, 63])
        #expect(try peer.readClipboard().1.supportedContent == clientImage)
        #expect(peer.clipboard.currentContent() == clientImage)
        #expect(!peer.hasData(timeout: 0.25))
    }
}
