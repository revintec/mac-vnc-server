import CoreGraphics
import CoreVideo
import ScreenCaptureKit
import Darwin
import Foundation
import Testing
@testable import mac_vnc_server

struct ConsolePipelineTests {
    private let identity = ConsoleIdentity(uid: 0, auditID: 123)
    private let display = VirtualDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 4, height: 2),
                                        pixelWidth: 4, pixelHeight: 2)

    @Test func screenCaptureKitMustMatchConsoleDisplayIdentityAndGeometry() throws {
        try StreamingScreenCapture.validateConsoleDisplays([display], activeDisplayIDs: [1], scale: 1)
        for ids: [UInt32] in [[], [30], [1, 30]] {
            #expect(throws: (any Error).self) {
                try StreamingScreenCapture.validateConsoleDisplays([display], activeDisplayIDs: ids, scale: 1)
            }
        }
        let wrong = VirtualDisplay(id: 30, bounds: .zero, pixelWidth: 1728, pixelHeight: 1118)
        #expect(throws: (any Error).self) {
            try StreamingScreenCapture.validateConsoleDisplays([wrong], activeDisplayIDs: [30], scale: 1)
        }
    }

    @Test func obsoleteConsoleIsRejectedBeforeStartingCapture() async {
        await #expect(throws: (any Error).self) {
            try await StreamingScreenCapture(scale: 1, fps: 60, displaySelection: .all,
                logger: ServerLogger(verbose: false), consoleIdentity: identity)
        }
    }

    @Test func rootWorkerRetainsCursorChoiceButRejectsClipboardAndTransfer() throws {
        guard case .run(var config) = try CLI.parse(arguments: []) else { throw CLIError.invalidArgument("test config") }
        config.clipboardSync = false; config.fileTransfer = false
        try SessionWorkerOptions(identity: identity, config: config).validate()
        #expect(config.cursorMode == .auto)
        config.cursorMode = .embedded
        try SessionWorkerOptions(identity: identity, config: config).validate()
        config.clipboardSync = true
        #expect(throws: (any Error).self) { try SessionWorkerOptions(identity: identity, config: config).validate() }
        config.clipboardSync = false; config.fileTransfer = true
        #expect(throws: (any Error).self) { try SessionWorkerOptions(identity: identity, config: config).validate() }
    }

    @Test func sharedCaptureQueueCoalescesAndClearsBlankFrames() throws {
        let store = StreamingFrameStore(layout: VirtualDisplayLayout(displays: [display], scaleOverride: 1),
            expectedDisplayIDs: [1], acceptedFrameRate: 60)
        let queue = DispatchQueue(label: "test.capture.delivery")
        let output = ScreenCaptureStreamOutput(displayID: 1, width: 4, height: 2, store: store, deliveryQueue: queue)
        func buffer(_ value: Int32) throws -> CVPixelBuffer {
            var result: CVPixelBuffer?
            try #require(CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess)
            let pixels = try #require(result)
            try #require(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
            memset(CVPixelBufferGetBaseAddress(pixels), value, CVPixelBufferGetBytesPerRow(pixels) * 2)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            return pixels
        }
        let first = try buffer(31), latest = try buffer(87)
        queue.suspend()
        output.receive(status: .complete, pixelBuffer: first, dirtyRects: [], presentationTime: 1)
        output.receive(status: .complete, pixelBuffer: latest,
            dirtyRects: [Rect(x: 0, y: 0, width: 1, height: 1)], presentationTime: 2)
        queue.resume(); queue.sync {}
        #expect(try store.snapshot().bgra.first == 87)
        #expect(try store.currentSequence() == 1) // Only the latest pending buffer was copied.
        #expect(try store.snapshot().dirtyRects == nil) // Its hint cannot cover the skipped frame.
        output.receive(status: .idle, pixelBuffer: first, dirtyRects: nil, presentationTime: 3)
        queue.sync {}
        #expect(try store.currentSequence() == 1)
        output.receive(status: .blank, pixelBuffer: nil, dirtyRects: nil, presentationTime: 3)
        queue.sync {}
        #expect(output.isBlank)
        #expect(try store.snapshot().bgra.allSatisfy { $0 == 0 })
        output.receive(status: .blank, pixelBuffer: nil, dirtyRects: nil, presentationTime: 4)
        queue.sync {}
        #expect(try store.currentSequence() == 2) // Repeated blank samples are idle.
        // A started image resumes capture even when its timestamp falls inside
        // the former stream's throttle interval and its dirty list is empty.
        output.receive(status: .started, pixelBuffer: latest, dirtyRects: [], presentationTime: 2.001)
        queue.sync {}
        #expect(!output.isBlank)
        #expect(try store.snapshot().bgra.first == 87)
        #expect(try store.snapshot().dirtyRects == nil)
    }

    @Test(arguments: [SCFrameStatus.blank, .suspended, .stopped])
    func inputRecoverySurvivesStatusOnlySamplesUntilAnImageResumes(_ status: SCFrameStatus) throws {
        let store = StreamingFrameStore(layout: VirtualDisplayLayout(displays: [display], scaleOverride: 1),
            expectedDisplayIDs: [1], acceptedFrameRate: 60)
        let queue = DispatchQueue(label: "test.capture.resume")
        let output = ScreenCaptureStreamOutput(displayID: 1, width: 4, height: 2, store: store, deliveryQueue: queue)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let image = try #require(buffer)
        try #require(CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess)
        memset(CVPixelBufferGetBaseAddress(image), 87, CVPixelBufferGetBytesPerRow(image) * 2)
        CVPixelBufferUnlockBaseAddress(image, [])
        output.receive(status: .complete, pixelBuffer: image, dirtyRects: nil, presentationTime: 1)
        queue.sync {}
        #expect(!output.needsRecoveryAfterInput)

        output.receive(status: status, pixelBuffer: nil, dirtyRects: nil, presentationTime: nil)
        output.receive(status: .idle, pixelBuffer: image, dirtyRects: [], presentationTime: nil)
        output.receive(status: .started, pixelBuffer: nil, dirtyRects: [], presentationTime: nil)
        output.receive(status: .complete, pixelBuffer: nil, dirtyRects: [], presentationTime: nil)
        queue.sync {}
        #expect(output.needsRecoveryAfterInput)
        #expect(try store.snapshot().bgra.first == (status == .blank ? 0 : 87))
        let sequenceBeforeResume = try store.currentSequence()

        // The resumed complete frame must be delivered even with an empty
        // dirty list and a timestamp that would normally be rate-limited.
        output.receive(status: .complete, pixelBuffer: image, dirtyRects: [], presentationTime: 1.001)
        queue.sync {}
        #expect(!output.needsRecoveryAfterInput)
        #expect(!output.isBlank)
        #expect(try store.snapshot().bgra.first == 87)
        #expect(try store.snapshot().dirtyRects == nil)
        #expect(try store.currentSequence() != sequenceBeforeResume)
    }

}
