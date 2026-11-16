import Foundation
import CryptoKit
import MSCore

public enum HandshakeError: Error, Equatable {
    case versionMismatch(UInt8)
    case malformed(String)
    case commitMismatch
    case badSignature
    case wrongState
}

/// Default randomness source.
public func secureRandomData(_ count: Int) -> Data {
    var g = SystemRandomNumberGenerator()
    var d = Data(capacity: count)
    for _ in 0..<count { d.append(UInt8.random(in: 0...255, using: &g)) }
    return d
}

enum HandshakeCrypto {
    static let keyLen = 32

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var acc: UInt8 = 0
        for (x, y) in zip(a, b) { acc |= x ^ y }
        return acc == 0
    }

    static func commit(eph: Data, nonce: Data) -> Data {
        var buf = Data(eph)
        buf.append(nonce)
        return Data(SHA256.hash(data: buf))
    }

    static func transcript(idH: Data, idD: Data, ephH: Data, ephD: Data, nonceH: Data, nonceD: Data) -> Data {
        var buf = Data("MacScreen-v1".utf8)
        for part in [idH, idD, ephH, ephD, nonceH, nonceD] { buf.append(part) }
        return Data(SHA256.hash(data: buf))
    }

    static func pairingCode(transcript t: Data) -> String {
        var buf = Data("SAS".utf8)
        buf.append(t)
        let h = Array(SHA256.hash(data: buf))
        let v = (UInt32(h[0]) << 24) | (UInt32(h[1]) << 16) | (UInt32(h[2]) << 8) | UInt32(h[3])
        let s = String(v % 1_000_000)
        return String(repeating: "0", count: 6 - s.count) + s
    }

    static func deriveKeys(own: Curve25519.KeyAgreement.PrivateKey,
                           peer: Curve25519.KeyAgreement.PublicKey,
                           transcript t: Data) throws -> SessionKeys {
        let shared: SharedSecret
        do { shared = try own.sharedSecretFromKeyAgreement(with: peer) } catch {
            throw HandshakeError.malformed("key agreement failed")
        }
        func k(_ label: String) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: t,
                                           sharedInfo: Data(label.utf8), outputByteCount: 32)
        }
        return SessionKeys(ctlH2D: k("ctl-h2d"), ctlD2H: k("ctl-d2h"),
                           medH2D: k("med-h2d"), medD2H: k("med-d2h"))
    }

    static func checkLen(_ d: Data, _ n: Int, _ name: String) throws {
        guard d.count == n else { throw HandshakeError.malformed("\(name) must be \(n) bytes") }
    }

    static func edKey(_ d: Data) throws -> Curve25519.Signing.PublicKey {
        do { return try Curve25519.Signing.PublicKey(rawRepresentation: d) } catch {
            throw HandshakeError.malformed("invalid identity key")
        }
    }

    static func xKey(_ d: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        do { return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: d) } catch {
            throw HandshakeError.malformed("invalid ephemeral key")
        }
    }

    static func verify(_ sig: Data, over t: Data, key: Curve25519.Signing.PublicKey) throws {
        guard sig.count == 64, key.isValidSignature(sig, for: t) else { throw HandshakeError.badSignature }
    }

    static func sign(_ t: Data, _ id: Identity) throws -> Data {
        do { return try id.signingKey.signature(for: t) } catch {
            throw HandshakeError.malformed("signing failed")
        }
    }
}

/// Host side (initiator). Single use.
public final class HostHandshake {
    private enum State { case new, helloSent, revealSent, done }

    private let identity: Identity
    private let isKnownPeer: (Data) -> Bool
    private let random: (Int) -> Data
    private var state = State.new
    private var eph: Curve25519.KeyAgreement.PrivateKey?
    private var nonce = Data()
    private var pending: HandshakeResult?
    private var peerSigningKey: Curve25519.Signing.PublicKey?
    private var sentHello: HelloMessage?

    public init(identity: Identity, isKnownPeer: @escaping (Data) -> Bool,
                random: @escaping (Int) -> Data = secureRandomData) {
        self.identity = identity
        self.isKnownPeer = isKnownPeer
        self.random = random
    }

    public func makeHello() -> HelloMessage {
        if let h = sentHello { return h }  // idempotent: never regenerate keys or nonce
        let seed = random(32)
        let key = (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed))
            ?? Curve25519.KeyAgreement.PrivateKey()
        eph = key
        nonce = random(32)
        state = .helloSent
        let h = HelloMessage(v: MSConstants.protoVersion, deviceId: identity.deviceId,
                             deviceName: identity.deviceName, identityKey: identity.publicKey,
                             commit: HandshakeCrypto.commit(eph: key.publicKey.rawRepresentation, nonce: nonce))
        sentHello = h
        return h
    }

    public func handleHelloReply(_ r: HelloReplyMessage) throws -> RevealMessage {
        guard state == .helloSent, let eph = eph else { throw HandshakeError.wrongState }
        guard r.v == MSConstants.protoVersion else { throw HandshakeError.versionMismatch(r.v) }
        try HandshakeCrypto.checkLen(r.identityKey, 32, "identityKey")
        try HandshakeCrypto.checkLen(r.ephKey, 32, "ephKey")
        try HandshakeCrypto.checkLen(r.nonce, 32, "nonce")
        let peerId = try HandshakeCrypto.edKey(r.identityKey)
        let peerEph = try HandshakeCrypto.xKey(r.ephKey)
        let t = HandshakeCrypto.transcript(idH: identity.publicKey, idD: r.identityKey,
                                           ephH: eph.publicKey.rawRepresentation, ephD: r.ephKey,
                                           nonceH: nonce, nonceD: r.nonce)
        let keys = try HandshakeCrypto.deriveKeys(own: eph, peer: peerEph, transcript: t)
        let sig = try HandshakeCrypto.sign(t, identity)
        pending = HandshakeResult(keys: keys, peerIdentityKey: r.identityKey, peerDeviceId: r.deviceId,
                                  peerDeviceName: r.deviceName, transcript: t,
                                  pairingCode: HandshakeCrypto.pairingCode(transcript: t),
                                  peerWasKnown: isKnownPeer(r.identityKey), peerKnowsUs: r.knowsPeer)
        peerSigningKey = peerId
        state = .revealSent
        return RevealMessage(ephKey: eph.publicKey.rawRepresentation, nonce: nonce, signature: sig)
    }

    public func handleRevealReply(_ r: RevealReplyMessage) throws -> HandshakeResult {
        guard state == .revealSent, let result = pending, let key = peerSigningKey else {
            throw HandshakeError.wrongState
        }
        try HandshakeCrypto.verify(r.signature, over: result.transcript, key: key)
        state = .done
        pending = nil
        return result
    }
}

/// Display side (responder). Single use.
public final class DisplayHandshake {
    private enum State { case new, replied, done }

    private let identity: Identity
    private let isKnownPeer: (Data) -> Bool
    private let random: (Int) -> Data
    private var state = State.new
    private var hello: HelloMessage?
    private var eph: Curve25519.KeyAgreement.PrivateKey?
    private var nonce = Data()

    public init(identity: Identity, isKnownPeer: @escaping (Data) -> Bool,
                random: @escaping (Int) -> Data = secureRandomData) {
        self.identity = identity
        self.isKnownPeer = isKnownPeer
        self.random = random
    }

    public func handleHello(_ h: HelloMessage) throws -> HelloReplyMessage {
        guard state == .new else { throw HandshakeError.wrongState }
        guard h.v == MSConstants.protoVersion else { throw HandshakeError.versionMismatch(h.v) }
        try HandshakeCrypto.checkLen(h.identityKey, 32, "identityKey")
        try HandshakeCrypto.checkLen(h.commit, 32, "commit")
        _ = try HandshakeCrypto.edKey(h.identityKey)
        let key = (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: random(32)))
            ?? Curve25519.KeyAgreement.PrivateKey()
        eph = key
        nonce = random(32)
        hello = h
        state = .replied
        return HelloReplyMessage(v: MSConstants.protoVersion, deviceId: identity.deviceId,
                                 deviceName: identity.deviceName, identityKey: identity.publicKey,
                                 ephKey: key.publicKey.rawRepresentation, nonce: nonce,
                                 knowsPeer: isKnownPeer(h.identityKey))
    }

    public func handleReveal(_ r: RevealMessage) throws -> (RevealReplyMessage, HandshakeResult) {
        guard state == .replied, let h = hello, let eph = eph else { throw HandshakeError.wrongState }
        try HandshakeCrypto.checkLen(r.ephKey, 32, "ephKey")
        try HandshakeCrypto.checkLen(r.nonce, 32, "nonce")
        let expected = HandshakeCrypto.commit(eph: r.ephKey, nonce: r.nonce)
        guard HandshakeCrypto.constantTimeEqual(expected, h.commit) else { throw HandshakeError.commitMismatch }
        let hostId = try HandshakeCrypto.edKey(h.identityKey)
        let hostEph = try HandshakeCrypto.xKey(r.ephKey)
        let t = HandshakeCrypto.transcript(idH: h.identityKey, idD: identity.publicKey,
                                           ephH: r.ephKey, ephD: eph.publicKey.rawRepresentation,
                                           nonceH: r.nonce, nonceD: nonce)
        try HandshakeCrypto.verify(r.signature, over: t, key: hostId)
        let keys = try HandshakeCrypto.deriveKeys(own: eph, peer: hostEph, transcript: t)
        let sig = try HandshakeCrypto.sign(t, identity)
        state = .done
        let result = HandshakeResult(keys: keys, peerIdentityKey: h.identityKey, peerDeviceId: h.deviceId,
                                     peerDeviceName: h.deviceName, transcript: t,
                                     pairingCode: HandshakeCrypto.pairingCode(transcript: t),
                                     peerWasKnown: isKnownPeer(h.identityKey))
        return (RevealReplyMessage(signature: sig), result)
    }
}
