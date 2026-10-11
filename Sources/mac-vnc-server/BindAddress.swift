import Darwin
import Foundation

/// Resolve a CLI bind target when the listener starts, so a LaunchAgent keeps
/// the interface name rather than an address that can change between launches.
enum BindAddress {
    static let defaultValue = "utun4"

    static func resolve(_ value: String) throws -> String {
        var address = in_addr()
        if inet_pton(AF_INET, value, &address) == 1 { return value }
        guard !value.isEmpty, if_nametoindex(value) != 0 else {
            throw RFBError.socketError("bind target '\(value)' is neither an IPv4 address nor an existing interface; use --bind ADDRESS or --bind INTERFACE")
        }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else {
            throw RFBError.socketError("could not enumerate interface \(value): \(String(cString: strerror(errno)))")
        }
        defer { freeifaddrs(first) }
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == value,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let raw = entry.pointee.ifa_addr, raw.pointee.sa_family == AF_INET else { continue }
            address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard address.s_addr != INADDR_ANY else { continue }
            var bytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &bytes, socklen_t(bytes.count)) != nil else { continue }
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        throw RFBError.socketError("interface \(value) has no active IPv4 address; bring it up or choose another --bind target")
    }

    static func isLoopback(_ address: String) -> Bool {
        var parsed = in_addr()
        return inet_pton(AF_INET, address, &parsed) == 1 && UInt32(bigEndian: parsed.s_addr) >> 24 == 127
    }
}
