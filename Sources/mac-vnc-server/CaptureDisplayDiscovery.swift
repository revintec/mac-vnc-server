import Foundation
import ScreenCaptureKit

enum CaptureDisplaysUnavailable: LocalizedError {
    case empty
    case consoleMismatch(offered: [UInt32], active: [UInt32])

    var errorDescription: String? {
        switch self {
        case .empty:
            return "ScreenCaptureKit found no displays"
        case .consoleMismatch(let offered, let active):
            return "ScreenCaptureKit displays do not match the attached console " +
                "(offered=\(offered.sorted()), active=\(active.sorted())); no user-desktop fallback"
        }
    }
}

/// A sleeping display or a console transition can temporarily produce an empty
/// or stale SCK snapshot. Wake once, then obtain fresh, verified snapshots. Do
/// not retry permissions, invalid geometry, or a change in session ownership.
enum CaptureDisplayDiscovery {
    static func run<Value>(
        logger: ServerLogger,
        verify: () throws -> Void,
        wake: () throws -> Void = DisplayWakeup.signal,
        pause: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
        discover: () async throws -> Value
    ) async throws -> Value {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            try verify()
            do {
                let value = try await discover()
                try Task.checkCancellation()
                try verify()
                return value
            } catch {
                let native = error as NSError
                guard error is CaptureDisplaysUnavailable ||
                    (native.domain == SCStreamErrorDomain && native.code == SCStreamError.noDisplayList.rawValue) else {
                    throw error
                }
                logger.warning("ScreenCaptureKit display discovery attempt \(attempt)/4: \(error.localizedDescription)")
                guard attempt < 4 else { throw RFBError.captureFailed(error.localizedDescription) }
                try Task.checkCancellation()
                try verify()
                if attempt == 1 {
                    do {
                        try wake()
                        logger.info("Sent display wake signal for unavailable capture displays.")
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        logger.warning("display wake signal failed: \(error.localizedDescription)")
                    }
                }
                try await pause()
                attempt += 1
            }
        }
    }
}
