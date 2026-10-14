import CoreGraphics
import CVNCSession
import Foundation

/// Instantiated only in a verified UID 0 console worker. The normal user
/// backend and logged-in console workers keep their session-scoped event tap.
final class ConsoleRootInput {
    private let input: VNCConsoleInputRef
    private let lock = NSLock()
    private var failure: Int32 = 0

    init(identity: ConsoleIdentity) throws {
        var error: Int32 = 0
        guard let input = VNCConsoleInputCreate(identity.native, &error) else {
            throw CLIError.commandFailed("loginwindow HID input unavailable (code \(error)); check Post Event/Accessibility permission")
        }
        self.input = input
    }

    deinit { VNCConsoleInputDestroy(input) }

    func post(_ event: CGEvent) {
        // Shared input serializes event delivery; this lock also synchronizes
        // the worker's independent health check. Preserve the first error.
        lock.withLock {
            guard failure == 0 else { return }
            failure = VNCConsoleInputPost(input, event)
        }
    }

    func checkDelivery() throws {
        try lock.withLock {
            guard failure == 0 else {
                throw CLIError.commandFailed("loginwindow HID input stopped (code \(failure))")
            }
        }
    }
}
