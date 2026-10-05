import Darwin
import Foundation

final class ClientSocket {
    let fd: Int32
    // Accessed only by the session reader, independently of the writer's timeout.
    private var readDeadline: (time: DispatchTime, operation: String)?
    private static let writeIdleTimeout: TimeInterval = 3
    private let stateLock = NSLock()
    private var didShutdown = false

    init(fd: Int32) throws {
        self.fd = fd

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(fd)
            throw RFBError.socketError("failed to configure client socket")
        }
    }

    deinit {
        close(fd)
    }

    func configureTCP() throws {
        // Probe quiet viewers without requiring an RFB extension. Also bound
        // retransmissions when data is buffered in the kernel awaiting an ACK:
        // a successful write alone does not prove that the viewer received it.
        let options: [(level: Int32, name: Int32, value: Int32, label: String)] = [
            (SOL_SOCKET, SO_NOSIGPIPE, 1, "SO_NOSIGPIPE"),
            (IPPROTO_TCP, TCP_NODELAY, 1, "TCP_NODELAY"),
            (SOL_SOCKET, SO_KEEPALIVE, 1, "SO_KEEPALIVE"),
            (IPPROTO_TCP, TCP_KEEPALIVE, 3, "TCP_KEEPALIVE"),
            (IPPROTO_TCP, TCP_KEEPINTVL, 1, "TCP_KEEPINTVL"),
            (IPPROTO_TCP, TCP_KEEPCNT, 3, "TCP_KEEPCNT"),
            (IPPROTO_TCP, TCP_RXT_CONNDROPTIME, 6, "TCP_RXT_CONNDROPTIME"),
        ]
        for option in options {
            var value = option.value
            guard setsockopt(fd, option.level, option.name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw RFBError.socketError("could not set \(option.label): \(String(cString: strerror(errno)))")
            }
        }
    }

    // One total deadline across every field of a handshake or client message.
    // Partial progress must not let a peer extend the deadline indefinitely.
    func withReadTimeout<T>(_ timeout: TimeInterval, operation: String, _ body: () throws -> T) rethrows -> T {
        let previous = readDeadline
        readDeadline = (.now() + timeout, operation)
        defer { readDeadline = previous }
        return try body()
    }

    func readExact(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0

        while offset < count {
            let remaining: TimeInterval?
            if let deadline = readDeadline {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline.time.uptimeNanoseconds else {
                    throw RFBError.socketError("\(deadline.operation) timed out")
                }
                remaining = Double(deadline.time.uptimeNanoseconds - now) / 1_000_000_000
            } else { remaining = nil }
            let readCount = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(fd, pointer.baseAddress!.advanced(by: offset), count - offset)
            }
            if readCount == 0 {
                throw RFBError.socketError("client disconnected")
            }
            if readCount < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    guard try waitForEvent(Int16(POLLIN), timeout: remaining) else {
                        throw RFBError.socketError("\(readDeadline?.operation ?? "socket read") timed out")
                    }
                    continue
                }
                throw RFBError.socketError(String(cString: strerror(errno)))
            }
            offset += readCount
        }

        return buffer
    }

    func writeAll(
        _ bytes: [UInt8],
        idleTimeout: TimeInterval = ClientSocket.writeIdleTimeout,
        onStall: (() -> Void)? = nil
    ) throws {
        var offset = 0
        var lastProgress = DispatchTime.now().uptimeNanoseconds
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { pointer in
                Darwin.write(fd, pointer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
                lastProgress = DispatchTime.now().uptimeNanoseconds
                continue
            }
            if written == 0 {
                try waitForWritable(
                    since: lastProgress,
                    idleTimeout: idleTimeout,
                    onStall: onStall
                )
                continue
            }
            if written < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForWritable(
                        since: lastProgress,
                        idleTimeout: idleTimeout,
                        onStall: onStall
                    )
                    continue
                }
                throw RFBError.socketError(String(cString: strerror(errno)))
            }
        }
    }

    func writeAll(
        _ chunks: [[UInt8]],
        idleTimeout: TimeInterval = ClientSocket.writeIdleTimeout,
        onStall: (() -> Void)? = nil
    ) throws {
        guard chunks.count <= 1_024 else {
            for chunk in chunks {
                try writeAll(chunk, idleTimeout: idleTimeout, onStall: onStall)
            }
            return
        }

        let totalBytes = chunks.reduce(0) { $0 + $1.count }
        guard totalBytes > 0 else {
            return
        }

        var offsets = [Int](repeating: 0, count: chunks.count)
        var writtenTotal = 0
        var lastProgress = DispatchTime.now().uptimeNanoseconds

        while writtenTotal < totalBytes {
            let written = withIOVectors(chunks: chunks, offsets: offsets) { vectors in
                vectors.withUnsafeBufferPointer { pointer in
                    Darwin.writev(fd, pointer.baseAddress, Int32(pointer.count))
                }
            }
            if written > 0 {
                writtenTotal += written
                var remaining = written
                for index in offsets.indices {
                    let available = chunks[index].count - offsets[index]
                    let consumed = min(remaining, available)
                    offsets[index] += consumed
                    remaining -= consumed
                    if remaining == 0 {
                        break
                    }
                }
                lastProgress = DispatchTime.now().uptimeNanoseconds
                continue
            }
            if written == 0 {
                try waitForWritable(
                    since: lastProgress,
                    idleTimeout: idleTimeout,
                    onStall: onStall
                )
                continue
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                try waitForWritable(
                    since: lastProgress,
                    idleTimeout: idleTimeout,
                    onStall: onStall
                )
                continue
            }
            throw RFBError.socketError(String(cString: strerror(errno)))
        }
    }

    func writeString(_ string: String) throws {
        try writeAll(Array(string.utf8))
    }

    func shutdown() {
        stateLock.lock()
        guard !didShutdown else {
            stateLock.unlock()
            return
        }
        didShutdown = true
        stateLock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    private func withIOVectors<T>(
        chunks: [[UInt8]],
        offsets: [Int],
        _ body: ([iovec]) -> T
    ) -> T {
        func appendVectors(_ index: Int, _ vectors: [iovec]) -> T {
            guard index < chunks.count else {
                return body(vectors)
            }

            let offset = offsets[index]
            guard offset < chunks[index].count else {
                return appendVectors(index + 1, vectors)
            }

            return chunks[index].withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return appendVectors(index + 1, vectors)
                }
                var nextVectors = vectors
                nextVectors.append(
                    iovec(
                        iov_base: UnsafeMutableRawPointer(mutating: baseAddress).advanced(by: offset),
                        iov_len: chunks[index].count - offset
                    )
                )
                return appendVectors(index + 1, nextVectors)
            }
        }

        return appendVectors(0, [])
    }

    private func waitForWritable(
        since start: UInt64,
        idleTimeout: TimeInterval,
        onStall: (() -> Void)?
    ) throws {
        let remaining = remainingTimeout(since: start, idleTimeout: idleTimeout)
        guard let remaining, remaining > 0 else {
            throw RFBError.socketError("socket write stalled for \(idleTimeout) seconds")
        }

        let pollInterval = min(remaining, 0.25)
        if try !waitForEvent(Int16(POLLOUT), timeout: pollInterval) {
            onStall?()
            if (remainingTimeout(since: start, idleTimeout: idleTimeout) ?? 0) <= 0 {
                throw RFBError.socketError("socket write stalled for \(idleTimeout) seconds")
            }
        }
    }

    private func waitForEvent(_ events: Int16, timeout: TimeInterval?) throws -> Bool {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let deadline = timeout.map { DispatchTime.now() + max(0, $0) }
        while true {
            let timeoutMilliseconds: Int32
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline.uptimeNanoseconds else {
                    return false
                }
                let remaining = Double(deadline.uptimeNanoseconds - now) / 1_000_000_000
                timeoutMilliseconds = Int32(min(Double(Int32.max), max(1, ceil(remaining * 1_000))))
            } else {
                timeoutMilliseconds = -1
            }

            let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if result > 0 {
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    throw RFBError.socketError("client socket closed while waiting for I/O")
                }
                if descriptor.revents & events != 0 {
                    return true
                }
                continue
            }
            if result == 0 {
                return false
            }
            if errno == EINTR {
                continue
            }
            throw RFBError.socketError(String(cString: strerror(errno)))
        }
    }

    private func remainingTimeout(since start: UInt64, idleTimeout: TimeInterval) -> TimeInterval? {
        let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return idleTimeout - elapsed
    }
}

final class ListeningSocket {
    let fd: Int32

    init(bindAddress: String, port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw RFBError.socketError(String(cString: strerror(errno)))
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, bindAddress, &address.sin_addr) == 1 else {
            close(fd)
            throw RFBError.socketError("invalid IPv4 bind address: \(bindAddress)")
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw RFBError.socketError("bind \(bindAddress):\(port) failed: \(message)")
        }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(fd)
            throw RFBError.socketError("failed to configure listening socket")
        }
        guard listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw RFBError.socketError("listen failed: \(message)")
        }
    }

    deinit {
        close(fd)
    }

    func acceptClient(timeout: TimeInterval) throws -> ClientSocket? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = Darwin.poll(&descriptor, 1, Int32(timeout * 1_000))
        if result == 0 || (result < 0 && errno == EINTR) { return nil }
        guard result > 0, descriptor.revents & Int16(POLLIN) != 0 else {
            throw RFBError.socketError("listener poll failed")
        }
        let clientFD = accept(fd, nil, nil)
        guard clientFD >= 0 else {
            if [EINTR, EAGAIN, EWOULDBLOCK, ECONNABORTED].contains(errno) { return nil }
            throw RFBError.socketError(String(cString: strerror(errno)))
        }
        return try ClientSocket(fd: clientFD)
    }
}
