import CoreGraphics
import Foundation
import Testing
@testable import mac_vnc_server

@Suite(.serialized)
struct AppleScalingTests {
    @Test func physicalDisplayScalingRoundsOriginalPixels() throws {
        let display = VirtualDisplay(id: 1, bounds: CGRect(x: -100, y: 50, width: 17.5, height: 8.5),
            pixelWidth: 35, pixelHeight: 17)
        let layout = VirtualDisplayLayout(displays: [display])
        let frame = Framebuffer(width: 35, height: 17, bgra: [UInt8](repeating: 0, count: 35 * 17 * 4),
            layout: layout, sequence: 7)
        let scaled = try FramebufferResampling.scale(frame, factor: 0.6, roundPixelDimensions: true)
        #expect(scaled.width == 21 && scaled.height == 10)
        #expect(scaled.bgra.count == 21 * 10 * 4)
        #expect(scaled.sequence == 7)
        #expect(frame.layout.globalPoint(framebufferX: 20, framebufferY: 10) == CGPoint(x: -90, y: 55))
    }

    @Test(arguments: [0.0, -1.0, 1.01, Double.nan, Double.infinity])
    func malformedScalingIsRejected(factor: Double) throws {
        let peer = try ClipboardTestPeer()
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.write(message(factor))
        #expect(throws: (any Error).self) { try peer.read(1) }
    }

    @Test func unnegotiatedDisplayInfoDoesNotDesynchronizeMessages() throws {
        let peer = try ClipboardTestPeer()
        defer { peer.finish() }
        _ = try peer.handshake(version: AppleRFB.version)
        try peer.enableAppleClipboard()
        // Consume all ten bytes, but do not resize without an encoding that can
        // report the new dimensions. The following clipboard fetch must work.
        try peer.write(message(0.5) + [0x0b, 0, 0, 0, 0, 0, 0, 42])
        #expect(try peer.readClipboard().1 == .text("initial"))
    }

    @Test func classicSessionDoesNotInterpretAppleScaling() throws {
        let peer = try ClipboardTestPeer()
        defer { peer.finish() }
        _ = try peer.handshake(version: "RFB 003.008\n")
        try peer.write(message(1))
        #expect(throws: (any Error).self) { try peer.read(1) }
    }

    private func message(_ factor: Double) -> [UInt8] {
        [8, 0] + stride(from: 56, through: 0, by: -8).map {
            UInt8(truncatingIfNeeded: factor.bitPattern >> $0)
        }
    }
}
