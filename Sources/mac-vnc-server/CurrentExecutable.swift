import Darwin
import Foundation

enum CurrentExecutable {
    enum Failure: LocalizedError {
        case unavailable
        case notExecutable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "could not determine the running server executable path"
            case .notExecutable(let path):
                return "server executable is missing or not executable at \(path); keep the binary at its launch location while the listener is running"
            }
        }
    }

    /// argv[0] can be just a command name when invoked through PATH or sudo.
    /// dyld records the loaded image's path independently of that argument.
    static func url() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { throw Failure.unavailable }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { throw Failure.unavailable }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw Failure.notExecutable(url.path)
        }
        return url
    }
}
