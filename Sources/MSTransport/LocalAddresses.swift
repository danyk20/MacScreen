import Foundation
import Darwin

/// This Mac's reachable IPv4 addresses, for "Show Address" on the Display.
public enum LocalAddresses {
    public struct Entry: Equatable {
        public let interface: String
        public let address: String
        public init(interface: String, address: String) {
            self.interface = interface
            self.address = address
        }
    }

    /// Up, non-loopback IPv4 addresses (Wi-Fi, Ethernet, Thunderbolt Bridge), en* first.
    public static func ipv4() -> [Entry] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [Entry] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            out.append(Entry(interface: name, address: String(cString: host)))
        }
        return out.sorted { ($0.interface.hasPrefix("en") ? 0 : 1, $0.interface) < ($1.interface.hasPrefix("en") ? 0 : 1, $1.interface) }
    }
}
