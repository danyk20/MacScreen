import Foundation

/// Semantic version ("1.2.3", "1.2.3-beta.2", optional leading "v"), ordered per semver 2.0 (build metadata ignored).
public struct SemanticVersion: Equatable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        if let plus = t.firstIndex(of: "+") { t = String(t[..<plus]) }
        var pre: [String] = []
        if let dash = t.firstIndex(of: "-") {
            pre = String(t[t.index(after: dash)...]).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            t = String(t[..<dash])
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return nil }
        }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let ma = Int(parts[0]), let mi = Int(parts[1]), let pa = Int(parts[2]),
              ma >= 0, mi >= 0, pa >= 0, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        self.init(major: ma, minor: mi, patch: pa, prerelease: pre)
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A release is newer than any of its pre-releases.
        if a.prerelease.isEmpty { return false }
        if b.prerelease.isEmpty { return true }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (nx?, ny?): return nx < ny
            case (_?, nil): return true      // numeric identifiers sort before alphanumeric ones
            case (nil, _?): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}
