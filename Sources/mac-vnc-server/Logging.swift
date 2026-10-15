import Darwin
import Foundation

final class ServerLogger: @unchecked Sendable {
    private let verbose: Bool
    private let lock = NSLock()
    private let context: String
    private let output: (@Sendable (String) -> Void)?
    private let timestamp = ISO8601DateFormatter()

    init(verbose: Bool, context: String = "", output: (@Sendable (String) -> Void)? = nil) {
        self.verbose = verbose
        self.context = context
        self.output = output
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestamp.timeZone = TimeZone(secondsFromGMT: 0)
    }

    /// A descriptor can be reused immediately after disconnect. Keep a distinct
    /// identity and numeric endpoints on every log from this admitted session.
    func forClient(_ socket: ClientSocket) -> ServerLogger {
        ServerLogger(verbose: verbose,
            context: "client_id=\(UUID().uuidString) peer=\(Self.endpoint(socket.fd, peer: true)) local=\(Self.endpoint(socket.fd, peer: false))",
            output: output)
    }

    private static func endpoint(_ fd: Int32, peer: Bool) -> String {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        return withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                let result = peer ? getpeername(fd, address, &length) : getsockname(fd, address, &length)
                guard result == 0 else { return "unknown" }
                guard address.pointee.sa_family != AF_UNIX else { return "unix" }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var port = [CChar](repeating: 0, count: Int(NI_MAXSERV))
                guard getnameinfo(address, length, &host, socklen_t(host.count), &port, socklen_t(port.count),
                                  NI_NUMERICHOST | NI_NUMERICSERV) == 0 else { return "unknown" }
                let name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let service = String(decoding: port.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                return "\(address.pointee.sa_family == AF_INET6 ? "[\(name)]" : name):\(service)"
            }
        }
    }

    var isVerbose: Bool {
        verbose
    }

    func info(_ message: String) {
        write(message, to: stdout)
    }

    func verbose(_ message: String) {
        guard verbose else {
            return
        }
        write(message, to: stdout)
    }

    func warning(_ message: String) {
        write("warning: \(message)", to: stderr)
    }

    func error(_ message: String) {
        write("error: \(message)", to: stderr)
    }

    private func write(_ message: String, to stream: UnsafeMutablePointer<FILE>) {
        lock.lock()
        defer { lock.unlock() }
        let details = context.isEmpty ? "" : " \(context)"
        let line = "\(message) [time=\(timestamp.string(from: Date())) pid=\(getpid())\(details)]"
        if let output { output(line) }
        else {
            fputs("\(line)\n", stream)
            // Preserve event ordering when stdout and stderr share a log file.
            fflush(stream)
        }
    }
}
