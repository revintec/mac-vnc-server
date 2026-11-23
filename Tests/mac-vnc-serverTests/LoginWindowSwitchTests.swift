import Foundation
import Testing
@testable import mac_vnc_server

struct LoginWindowSwitchTests {
    private let own = ConsoleIdentity(uid: 501, auditID: 100)
    private let loginwindow = ConsoleIdentity(uid: 0, auditID: 200)

    @Test func acceptedRequestWaitsThroughLoginUIStartup() async throws {
        var time: TimeInterval = 0
        var checks = 0
        let target = try await LoginWindowSwitch.waitForCompletion(from: own,
            readConsole: { time < 32 ? own : loginwindow },
            verifySession: { identity in #expect(identity == own); checks += 1 },
            now: { time }, pause: { time += 1 })
        #expect(target == loginwindow)
        #expect(time == 32 && checks == 33)
    }

    @Test func unavailableOrInvalidConsoleDoesNotCountAsCompletion() async throws {
        var time: TimeInterval = 0
        let target = try await LoginWindowSwitch.waitForCompletion(from: own,
            readConsole: {
                if time == 0 { return nil }
                if time == 1 { return ConsoleIdentity(uid: 0, auditID: 0) }
                return loginwindow
            }, verifySession: { _ in }, now: { time }, pause: { time += 1 })
        #expect(target == loginwindow && time == 2)
    }

    @Test func neverCompletedSwitchReportsTimeout() async {
        for console: ConsoleIdentity? in [own, nil] {
            var time: TimeInterval = 0
            do {
                _ = try await LoginWindowSwitch.waitForCompletion(from: own, timeout: 60,
                    readConsole: { console }, verifySession: { _ in }, now: { time }, pause: { time += 1 })
                Issue.record("An acknowledgement must not be reported as a completed physical switch")
            } catch {
                #expect(error.localizedDescription.contains("within 60 seconds"))
                #expect(error.localizedDescription.contains("connection remains open"))
            }
            #expect(time == 60)
        }
    }

    @Test func anotherUserTakingConsoleIsNotLoginwindowSuccess() async {
        for other in [ConsoleIdentity(uid: 502, auditID: 300), ConsoleIdentity(uid: 501, auditID: 301)] {
            do {
                _ = try await LoginWindowSwitch.waitForCompletion(from: own,
                    readConsole: { other }, verifySession: { _ in },
                    pause: { Issue.record("Do not keep waiting after another user took the console") })
                Issue.record("Expected changed-session error")
            } catch { #expect(error.localizedDescription.contains("Another user session")) }
        }
    }

    @Test func expiredSourceSessionCannotReportSuccess() async {
        do {
            _ = try await LoginWindowSwitch.waitForCompletion(from: own,
                readConsole: { loginwindow },
                verifySession: { _ in throw CLIError.commandFailed("source session ended") },
                pause: { Issue.record("No wait is needed after logout") })
            Issue.record("Expected source identity failure")
        } catch { #expect(error.localizedDescription == "source session ended") }
    }

    @Test func cancellationStopsWaiting() async {
        var reads = 0
        do {
            _ = try await LoginWindowSwitch.waitForCompletion(from: own,
                readConsole: { reads += 1; return own }, verifySession: { _ in },
                pause: { throw CancellationError() })
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(reads == 1)
    }
}
