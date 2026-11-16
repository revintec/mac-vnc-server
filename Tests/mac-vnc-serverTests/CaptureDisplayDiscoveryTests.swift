import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import mac_vnc_server

struct CaptureDisplayDiscoveryTests {
    private let logger = ServerLogger(verbose: false, output: { _ in })
    private let display = VirtualDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                         pixelWidth: 100, pixelHeight: 100)

    @Test func healthyCaptureDoesNotWakeOrDelay() async throws {
        let value = try await CaptureDisplayDiscovery.run(logger: logger, verify: {},
            wake: { Issue.record("Healthy capture must not wake the physical display") },
            pause: { Issue.record("Healthy capture must not wait") }, discover: { 42 })
        #expect(value == 42)
    }

    @Test func sleepingDisplaysWakeOnceAndRefreshUntilConsoleMatches() async throws {
        var discoveries = 0, wakes = 0, pauses = 0
        let value = try await CaptureDisplayDiscovery.run(logger: logger, verify: {},
            wake: { wakes += 1 }, pause: { pauses += 1 }) {
            discoveries += 1
            if discoveries == 1 { throw CaptureDisplaysUnavailable.empty }
            // SCK and CoreGraphics can become ready at different times.
            try StreamingScreenCapture.validateConsoleDisplays([display],
                activeDisplayIDs: discoveries == 2 ? [] : [1], scale: 1)
            return display.id
        }
        #expect(value == 1 && discoveries == 3 && wakes == 1 && pauses == 2)
    }

    @Test func nativeNoDisplayListErrorAlsoWakesAndRetries() async throws {
        var discoveries = 0, wakes = 0
        let value = try await CaptureDisplayDiscovery.run(logger: logger, verify: {},
            wake: { wakes += 1 }, pause: {}) {
            discoveries += 1
            if discoveries == 1 { throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.noDisplayList.rawValue) }
            return 42
        }
        #expect(value == 42 && discoveries == 2 && wakes == 1)
    }

    @Test func persistentWrongDesktopFailsClosedAfterBoundedRetries() async {
        var discoveries = 0, wakes = 0, pauses = 0
        do {
            try await CaptureDisplayDiscovery.run(logger: logger, verify: {},
                wake: { wakes += 1 }, pause: { pauses += 1 }) {
                discoveries += 1
                try StreamingScreenCapture.validateConsoleDisplays([display], activeDisplayIDs: [30], scale: 1)
            }
            Issue.record("A valid image from the wrong desktop must never be accepted")
        } catch {
            #expect(error.localizedDescription.contains("offered=[1], active=[30]"))
            #expect(error.localizedDescription.contains("no user-desktop fallback"))
        }
        #expect(discoveries == 4 && wakes == 1 && pauses == 3)
    }

    @Test func permissionsAndInvalidGeometryFailWithoutWaking() async {
        for error in [NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue),
                      NSError(domain: SCStreamErrorDomain, code: SCStreamError.missingEntitlements.rawValue)] {
            do {
                try await CaptureDisplayDiscovery.run(logger: logger, verify: {},
                    wake: { Issue.record("Permission failures must not wake") },
                    pause: { Issue.record("Permission failures must not retry") }, discover: { throw error })
                Issue.record("Expected the original permission error")
            } catch let actual as NSError { #expect(actual == error) }
        }
        do {
            try await CaptureDisplayDiscovery.run(logger: logger, verify: {},
                wake: { Issue.record("Invalid geometry must not wake") },
                pause: { Issue.record("Invalid geometry must not retry") }) {
                try StreamingScreenCapture.validateConsoleDisplays([
                    VirtualDisplay(id: 1, bounds: .zero, pixelWidth: 100, pixelHeight: 100)
                ], activeDisplayIDs: [1], scale: 1)
            }
            Issue.record("Invalid geometry must still fail")
        } catch { #expect(error.localizedDescription.contains("no valid CoreGraphics display geometry")) }
    }

    @Test func consoleChangeDuringWakeStopsBeforeAnotherDiscovery() async {
        var current = true, discoveries = 0
        do {
            try await CaptureDisplayDiscovery.run(logger: logger,
                verify: { if !current { throw RFBError.captureFailed("console identity changed") } },
                wake: { current = false }, pause: {}) {
                discoveries += 1
                throw CaptureDisplaysUnavailable.empty
            }
            Issue.record("A changed console must terminate capture startup")
        } catch { #expect(error.localizedDescription.contains("console identity changed")) }
        #expect(discoveries == 1)
    }

    @Test func consoleChangeDuringDiscoveryRejectsEvenAValidSnapshot() async {
        var current = true
        do {
            _ = try await CaptureDisplayDiscovery.run(logger: logger,
                verify: { if !current { throw RFBError.captureFailed("console identity changed") } },
                wake: { Issue.record("A replaced console must not wake") }, pause: {}) {
                current = false
                return 42
            }
            Issue.record("A snapshot of a replaced console must not be returned")
        } catch { #expect(error.localizedDescription.contains("console identity changed")) }
    }

    @Test func cancellationDuringBackoffDoesNotRetry() async {
        var discoveries = 0
        do {
            try await CaptureDisplayDiscovery.run(logger: logger, verify: {}, wake: {},
                pause: { throw CancellationError() }) {
                discoveries += 1
                throw CaptureDisplaysUnavailable.empty
            }
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(discoveries == 1)
    }

    @Test func wakeFailureStillAllowsAConsoleTransitionToSettle() async throws {
        var discoveries = 0, wakes = 0
        let value = try await CaptureDisplayDiscovery.run(logger: logger, verify: {},
            wake: { wakes += 1; throw CLIError.commandFailed("wake failed") }, pause: {}) {
            discoveries += 1
            if discoveries == 1 { throw CaptureDisplaysUnavailable.empty }
            return 42
        }
        #expect(value == 42 && discoveries == 2 && wakes == 1)
    }
}
