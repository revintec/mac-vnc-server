import CVNCSession
import Darwin
import Foundation

/// Owned by the supervisor's session loop. No separate manager process or
/// lifeline socket: normal teardown attempts cleanup, and startup reaps orphans.
final class ConsoleCaptureService {
    private var handle: VNCConsoleCaptureServiceRef?

    static func recoverOrphans() throws {
        let error = VNCConsoleCaptureServiceRecover()
        guard error == 0 else {
            throw RFBError.captureFailed("console capture cleanup deferred: \(String(cString: strerror(error))) (\(error))")
        }
    }

    init(identity: ConsoleIdentity) throws {
        let executable = try CurrentExecutable.url()
        var error: Int32 = 0
        guard let handle = VNCConsoleCaptureServiceCreate(identity.native, executable.path, &error) else {
            throw RFBError.captureFailed("console capture service unavailable: \(String(cString: strerror(error))) (\(error))")
        }
        self.handle = handle
    }

    deinit { stop() }

    func stop() {
        guard let handle else { return }
        self.handle = nil
        VNCConsoleCaptureServiceDestroy(handle)
    }
}
