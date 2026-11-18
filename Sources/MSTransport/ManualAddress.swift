import Foundation
import Network
import MSCore

/// A Display address typed by the user: "192.168.1.20", "192.168.1.20:47800", "5k-imac.local",
/// "[fe80::1]:47800". The port defaults to `MSConstants.defaultControlPort`.
public struct ManualAddress: Equatable {
    public let host: String
    public let port: UInt16

    public var endpoint: NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    }

    /// Text shown to the user (IPv6 literals in brackets when a port is shown).
    public var display: String {
        let h = host.contains(":") ? "[\(host)]" : host
        return port == MSConstants.defaultControlPort ? host : "\(h):\(port)"
    }

    /// Stable key for connection bookkeeping (never shown).
    public var key: String { "addr:\(host):\(port)" }

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// nil when the text is not a usable address.
    public static func parse(_ text: String) -> ManualAddress? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 255 else { return nil }
        if let r = t.range(of: "://") { t = String(t[r.upperBound...]) }   // tolerate "tcp://host"
        var host: String
        var portText: String?
        if t.hasPrefix("[") {
            guard let close = t.firstIndex(of: "]") else { return nil }
            host = String(t[t.index(after: t.startIndex)..<close])
            let rest = t[t.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                portText = String(rest.dropFirst())
            }
        } else if t.filter({ $0 == ":" }).count == 1, let i = t.firstIndex(of: ":") {
            host = String(t[..<i])
            portText = String(t[t.index(after: i)...])
        } else {
            host = t            // hostname, IPv4, or a bare IPv6 literal (several colons)
        }
        guard isValidHost(host) else { return nil }
        var port = MSConstants.defaultControlPort
        if let p = portText {
            guard let n = UInt16(p), n >= 1 else { return nil }
            port = n
        }
        return ManualAddress(host: host, port: port)
    }

    private static func isValidHost(_ h: String) -> Bool {
        guard !h.isEmpty, h.count <= 253 else { return false }
        if IPv4Address(h) != nil || IPv6Address(h) != nil { return true }
        // Hostname: letters, digits, '-', '_' and '.' separators; no empty labels.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard h.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return !h.hasPrefix(".") && !h.hasSuffix(".") && !h.contains("..")
    }
}
