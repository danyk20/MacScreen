import Foundation

public enum UpdateConfig {
    /// GitHub "owner/name" that publishes MacScreen releases.
    public static let repository = "danyk20/MacScreen"
    public static let feedURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=15")!
}

public struct ReleaseAsset: Equatable {
    public let name: String
    public let url: URL
    public let size: Int
}

public struct Release: Equatable {
    public let version: SemanticVersion
    public let tag: String
    public let isPrerelease: Bool
    public let pageURL: URL
    public let notes: String
    public let dmg: ReleaseAsset
    public let checksums: ReleaseAsset
}

/// Parses the GitHub "list releases" JSON. Only releases with a DMG and a checksum file are usable, and asset
/// URLs must point at this repository's release downloads (https), never anywhere else.
public enum ReleaseFeed {
    private struct RawAsset: Decodable { let name: String; let browser_download_url: String; let size: Int? }
    private struct RawRelease: Decodable {
        let tag_name: String
        let draft: Bool?
        let prerelease: Bool?
        let html_url: String?
        let body: String?
        let assets: [RawAsset]?
    }

    public static func parse(_ data: Data, repository: String = UpdateConfig.repository) -> [Release] {
        guard let raw = try? JSONDecoder().decode([RawRelease].self, from: data) else { return [] }
        return raw.compactMap { r in
            guard r.draft != true, let v = SemanticVersion(r.tag_name) else { return nil }
            let assets = r.assets ?? []
            func asset(_ match: (String) -> Bool) -> ReleaseAsset? {
                guard let a = assets.first(where: { match($0.name) }), let u = URL(string: a.browser_download_url),
                      u.scheme == "https", u.host == "github.com",
                      u.path.hasPrefix("/\(repository)/releases/download/") else { return nil }
                return ReleaseAsset(name: a.name, url: u, size: a.size ?? 0)
            }
            guard let dmg = asset({ $0 == "MacScreen-\(r.tag_name).dmg" }),
                  let sums = asset({ $0 == "SHA256SUMS.txt" }) else { return nil }
            let page = r.html_url.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
                ?? URL(string: "https://github.com/\(repository)/releases")!
            return Release(version: v, tag: r.tag_name, isPrerelease: r.prerelease ?? v.isPrerelease,
                           pageURL: page, notes: r.body ?? "", dmg: dmg, checksums: sums)
        }
    }

    /// The newest release newer than `current`. A stable build only follows stable releases; a pre-release build
    /// follows pre-releases and stable ones.
    public static func newer(than current: SemanticVersion, in releases: [Release]) -> Release? {
        releases
            .filter { $0.version > current && (current.isPrerelease || !$0.isPrerelease) }
            .max { $0.version < $1.version }
    }
}

/// `SHA256SUMS.txt` lines: "<64 hex>  <name>" (a leading "./" or "*" on the name is ignored).
public enum ChecksumFile {
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            if name.hasPrefix("./") { name.removeFirst(2) }
            out[name] = hash
        }
        return out
    }
}
