import Foundation
import CryptoKit

public enum IdentityStoreError: Error, Equatable {
    case corrupt
    case io(String)
}

public struct Peer: Codable, Equatable {
    public var deviceId: String
    public var deviceName: String
    public var identityKey: Data
    public var pairedAt: Date

    public init(deviceId: String, deviceName: String, identityKey: Data, pairedAt: Date) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.identityKey = identityKey
        self.pairedAt = pairedAt
    }
}

private struct IdentityFile: Codable {
    var deviceId: String
    var deviceName: String
    var signingKey: Data
    var peers: [Peer]
}

/// User-chosen device names: printable, single line, at most 40 characters (a Bonjour name is limited to 63 bytes).
public enum DeviceName {
    public static let maxLength = 40

    /// nil when nothing usable is left (the caller then falls back to the Mac's own name).
    public static func sanitize(_ raw: String) -> String? {
        let bad = CharacterSet.controlCharacters.union(.newlines).union(.illegalCharacters)
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !bad.contains($0) }))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }
}

public final class IdentityStore {
    private let lock = NSLock()
    private let fileURL: URL
    private var file: IdentityFile
    private var signingKey: Curve25519.Signing.PrivateKey

    public init(directory: URL, defaultDeviceName: String) throws {
        let fm = FileManager.default
        fileURL = directory.appendingPathComponent("identity.json")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // An existing directory keeps its mode through createDirectory: tighten it if we own it.
            let attrs = try fm.attributesOfItem(atPath: directory.path)
            if let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
               let mode = attrs[.posixPermissions] as? NSNumber, mode.intValue & 0o777 != 0o700 {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
        } catch { throw IdentityStoreError.io("\(error)") }

        if fm.fileExists(atPath: fileURL.path) {
            let data: Data
            do { data = try Data(contentsOf: fileURL) } catch { throw IdentityStoreError.io("\(error)") }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let f = try? decoder.decode(IdentityFile.self, from: data),
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: f.signingKey),
                  UUID(uuidString: f.deviceId) != nil else {
                throw IdentityStoreError.corrupt
            }
            file = f
            signingKey = key
        } else {
            let key = Curve25519.Signing.PrivateKey()
            signingKey = key
            file = IdentityFile(deviceId: UUID().uuidString, deviceName: defaultDeviceName,
                                signingKey: key.rawRepresentation, peers: [])
            try save()
        }
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacScreen", isDirectory: true)
    }

    public var identity: Identity {
        lock.lock(); defer { lock.unlock() }
        return Identity(deviceId: file.deviceId, deviceName: file.deviceName, signingKey: signingKey)
    }

    public var peers: [Peer] {
        lock.lock(); defer { lock.unlock() }
        return file.peers
    }

    public func isKnown(identityKey: Data) -> Bool {
        peer(identityKey: identityKey) != nil
    }

    public func peer(identityKey: Data) -> Peer? {
        lock.lock(); defer { lock.unlock() }
        return file.peers.first { $0.identityKey == identityKey }
    }

    public func addPeer(_ p: Peer) throws {
        lock.lock(); defer { lock.unlock() }
        let old = file
        file.peers.removeAll { $0.identityKey == p.identityKey }
        file.peers.append(p)
        do { try save() } catch { file = old; throw error }
    }

    /// Renames this device (shown to other Macs and in pairing dialogs). The caller passes a sanitized name.
    public func setDeviceName(_ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard name != file.deviceName else { return }
        let old = file
        file.deviceName = name
        do { try save() } catch { file = old; throw error }
    }

    public func removePeer(identityKey: Data) throws {
        lock.lock(); defer { lock.unlock() }
        let old = file
        file.peers.removeAll { $0.identityKey == identityKey }
        do { try save() } catch { file = old; throw error }
    }

    /// Caller holds the lock (or is in init). Atomic: temp file 0600 in the same directory, then replace.
    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".identity-\(UUID().uuidString).tmp")
        do {
            let data = try encoder.encode(file)
            guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw IdentityStoreError.io("cannot create temp file")
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: fileURL.path) {
                _ = try fm.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: fileURL)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch let e as IdentityStoreError {
            try? fm.removeItem(at: tmp)
            throw e
        } catch {
            try? fm.removeItem(at: tmp)
            throw IdentityStoreError.io("\(error)")
        }
    }
}
