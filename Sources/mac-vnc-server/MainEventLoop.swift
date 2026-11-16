import CoreFoundation

enum MainEventLoop {
    @MainActor static func run() {
        // dispatchMain() exits the original main thread. Its queue can then
        // execute on another thread, violating AppKit/MainActor thread checks
        // in root workers (cursor sampling and session activity callbacks).
        // Service the main queue on the original thread without creating UI.
        CFRunLoopRun()
    }
}
