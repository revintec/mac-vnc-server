import Foundation

enum SessionCaptureBackend {
    case screenCaptureKit, coreGraphics

    static func select(uid: UInt32, majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> Self {
        // Ventura rejects the separate root replayd launch. Its public
        // CGDisplayStream API captures within the already-attached worker.
        uid == 0 && majorVersion == 13 ? .coreGraphics : .screenCaptureKit
    }

    static func needsConsoleService(uid: UInt32, majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> Bool {
        uid == 0 && select(uid: uid, majorVersion: majorVersion) == .screenCaptureKit
    }
}

protocol SessionScreenCapture: FramebufferSource {
    func stop() async
}

extension StreamingScreenCapture: SessionScreenCapture {}
