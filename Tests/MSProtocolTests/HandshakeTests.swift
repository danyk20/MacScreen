import XCTest
import CryptoKit
@testable import MSProtocol

final class HandshakeTests: XCTestCase {
    func ident(_ name: String) -> Identity {
        Identity(deviceId: UUID().uuidString, deviceName: name, signingKey: Curve25519.Signing.PrivateKey())
    }

    /// Deterministic counter-based randomness.
    func fixedRandom(_ seed: UInt8) -> (Int) -> Data {
        var n: UInt8 = seed
        return { count in
            n = n &+ 1
            return Data((0..<count).map { UInt8(truncatingIfNeeded: Int(n) &* 31 &+ $0 &* 7) })
        }
    }

    func rt<T: Codable>(_ v: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(v))
    }

    func raw(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

    struct Run {
        var hello: HelloMessage
        var reply: HelloReplyMessage
        var reveal: RevealMessage
        var hostRes: HandshakeResult
        var dispRes: HandshakeResult
    }

    func run(host: Identity, disp: Identity, hostKnows: Bool = false, dispKnows: Bool = false,
             hr: ((Int) -> Data)? = nil, dr: ((Int) -> Data)? = nil) throws -> Run {
        let h = HostHandshake(identity: host, isKnownPeer: { _ in hostKnows }, random: hr ?? secureRandomData)
        let d = DisplayHandshake(identity: disp, isKnownPeer: { _ in dispKnows }, random: dr ?? secureRandomData)
        let hello = try rt(h.makeHello())
        let reply = try rt(try d.handleHello(hello))
        let reveal = try rt(try h.handleHelloReply(reply))
        let (rr, dres) = try d.handleReveal(reveal)
        let hres = try h.handleRevealReply(try rt(rr))
        return Run(hello: hello, reply: reply, reveal: reveal, hostRes: hres, dispRes: dres)
    }

    func testHappyPath() throws {
        let host = ident("Host Mac"), disp = ident("iMac")
        let r = try run(host: host, disp: disp, hostKnows: true, dispKnows: false)
        XCTAssertEqual(raw(r.hostRes.keys.ctlH2D), raw(r.dispRes.keys.ctlH2D))
        XCTAssertEqual(raw(r.hostRes.keys.ctlD2H), raw(r.dispRes.keys.ctlD2H))
        XCTAssertEqual(raw(r.hostRes.keys.medH2D), raw(r.dispRes.keys.medH2D))
        XCTAssertEqual(raw(r.hostRes.keys.medD2H), raw(r.dispRes.keys.medD2H))
        XCTAssertEqual(Set([raw(r.hostRes.keys.ctlH2D), raw(r.hostRes.keys.ctlD2H),
                            raw(r.hostRes.keys.medH2D), raw(r.hostRes.keys.medD2H)]).count, 4)
        XCTAssertEqual(r.hostRes.transcript, r.dispRes.transcript)
        XCTAssertEqual(r.hostRes.transcript.count, 32)
        XCTAssertEqual(r.hostRes.pairingCode, r.dispRes.pairingCode)
        XCTAssertEqual(r.hostRes.pairingCode.count, 6)
        XCTAssertTrue(r.hostRes.pairingCode.allSatisfy { $0.isASCII && $0.isNumber })
        XCTAssertEqual(r.hostRes.peerIdentityKey, disp.publicKey)
        XCTAssertEqual(r.hostRes.peerDeviceId, disp.deviceId)
        XCTAssertEqual(r.hostRes.peerDeviceName, "iMac")
        XCTAssertEqual(r.dispRes.peerIdentityKey, host.publicKey)
        XCTAssertEqual(r.dispRes.peerDeviceId, host.deviceId)
        XCTAssertEqual(r.dispRes.peerDeviceName, "Host Mac")
        XCTAssertTrue(r.hostRes.peerWasKnown)
        XCTAssertFalse(r.dispRes.peerWasKnown)
        XCTAssertFalse(r.reply.knowsPeer)
        let r2 = try run(host: host, disp: disp, hostKnows: false, dispKnows: true)
        XCTAssertTrue(r2.reply.knowsPeer)
        XCTAssertFalse(r2.hostRes.peerWasKnown)
        XCTAssertTrue(r2.dispRes.peerWasKnown)
    }

    func testPeerKnowsUs() throws {
        let host = ident("Host Mac"), disp = ident("iMac")
        let a = try run(host: host, disp: disp, dispKnows: true)
        XCTAssertEqual(a.hostRes.peerKnowsUs, true)
        XCTAssertNil(a.dispRes.peerKnowsUs)
        let b = try run(host: host, disp: disp, dispKnows: false)
        XCTAssertEqual(b.hostRes.peerKnowsUs, false)
        XCTAssertNil(b.dispRes.peerKnowsUs)
    }

    func testDeterministicVector() throws {
        let host = ident("H"), disp = ident("D")
        let a = try run(host: host, disp: disp, hr: fixedRandom(1), dr: fixedRandom(100))
        let b = try run(host: host, disp: disp, hr: fixedRandom(1), dr: fixedRandom(100))
        XCTAssertEqual(a.hostRes.transcript, b.hostRes.transcript)
        XCTAssertEqual(a.hostRes.pairingCode, b.hostRes.pairingCode)
        XCTAssertEqual(raw(a.hostRes.keys.medH2D), raw(b.hostRes.keys.medH2D))
        let c = try run(host: host, disp: disp, hr: fixedRandom(2), dr: fixedRandom(100))
        XCTAssertNotEqual(a.hostRes.transcript, c.hostRes.transcript)
        XCTAssertNotEqual(a.hostRes.pairingCode, c.hostRes.pairingCode)
    }

    func testPairingCodeFormat() {
        // Leading zeros preserved.
        for i in 0..<200 {
            let code = HandshakeCrypto.pairingCode(transcript: Data([UInt8(i), 1, 2]))
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy { $0.isASCII && $0.isNumber })
        }
    }

    func parties() -> (HostHandshake, DisplayHandshake) {
        (HostHandshake(identity: ident("H"), isKnownPeer: { _ in false }),
         DisplayHandshake(identity: ident("D"), isKnownPeer: { _ in false }))
    }

    func testTamperedCommit() throws {
        let (h, d) = parties()
        var hello = h.makeHello()
        hello.commit[0] ^= 1
        let reply = try d.handleHello(hello)
        let reveal = try h.handleHelloReply(reply)
        XCTAssertThrowsError(try d.handleReveal(reveal)) { XCTAssertEqual($0 as? HandshakeError, .commitMismatch) }
    }

    func testTamperedRevealEph() throws {
        let (h, d) = parties()
        let reply = try d.handleHello(h.makeHello())
        var reveal = try h.handleHelloReply(reply)
        reveal.ephKey[5] ^= 0x40
        XCTAssertThrowsError(try d.handleReveal(reveal)) { XCTAssertEqual($0 as? HandshakeError, .commitMismatch) }
    }

    func testTamperedHostSignature() throws {
        let (h, d) = parties()
        let reply = try d.handleHello(h.makeHello())
        var reveal = try h.handleHelloReply(reply)
        reveal.signature[3] ^= 1
        XCTAssertThrowsError(try d.handleReveal(reveal)) { XCTAssertEqual($0 as? HandshakeError, .badSignature) }
    }

    func testTamperedDisplaySignature() throws {
        let (h, d) = parties()
        let reply = try d.handleHello(h.makeHello())
        let reveal = try h.handleHelloReply(reply)
        var (rr, _) = try d.handleReveal(reveal)
        rr.signature[10] ^= 1
        XCTAssertThrowsError(try h.handleRevealReply(rr)) { XCTAssertEqual($0 as? HandshakeError, .badSignature) }
        // short signature too
        let (h2, d2) = parties()
        let rev2 = try h2.handleHelloReply(try d2.handleHello(h2.makeHello()))
        _ = try d2.handleReveal(rev2)
        XCTAssertThrowsError(try h2.handleRevealReply(RevealReplyMessage(signature: Data(count: 10)))) {
            XCTAssertEqual($0 as? HandshakeError, .badSignature)
        }
    }

    func testManInTheMiddleDifferentCodes() throws {
        let host = ident("H"), disp = ident("D"), mallory = ident("M")
        // Leg 1: Host <-> MITM (acting as display, own eph key); Leg 2: MITM (acting as host) <-> Display.
        let leg1 = try run(host: host, disp: mallory)
        let leg2 = try run(host: mallory, disp: disp)
        XCTAssertNotEqual(leg1.hostRes.pairingCode, leg2.dispRes.pairingCode)
        // MITM that only substitutes its ephemeral key in helloReply: signature check fails.
        let h = HostHandshake(identity: host, isKnownPeer: { _ in false })
        let d = DisplayHandshake(identity: disp, isKnownPeer: { _ in false })
        var reply = try d.handleHello(h.makeHello())
        reply.ephKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let reveal = try h.handleHelloReply(reply)
        // The Host signed a transcript with the MITM's key; the Display's transcript differs.
        XCTAssertThrowsError(try d.handleReveal(reveal)) { XCTAssertEqual($0 as? HandshakeError, .badSignature) }
    }

    func testVersionMismatch() throws {
        let (h, d) = parties()
        var hello = h.makeHello()
        hello.v = 9
        XCTAssertThrowsError(try d.handleHello(hello)) { XCTAssertEqual($0 as? HandshakeError, .versionMismatch(9)) }
        let (h2, d2) = parties()
        var reply = try d2.handleHello(h2.makeHello())
        reply.v = 2
        XCTAssertThrowsError(try h2.handleHelloReply(reply)) { XCTAssertEqual($0 as? HandshakeError, .versionMismatch(2)) }
    }

    func isMalformed(_ e: Error) -> Bool {
        if case .malformed = e as? HandshakeError { return true }
        return false
    }

    func testMalformedLengths() throws {
        let (h, d) = parties()
        var hello = h.makeHello()
        hello.commit = Data(count: 31)
        XCTAssertThrowsError(try d.handleHello(hello)) { XCTAssertTrue(isMalformed($0)) }
        var hello2 = h.makeHello()
        hello2.identityKey = Data(count: 33)
        let d2 = DisplayHandshake(identity: ident("D"), isKnownPeer: { _ in false })
        XCTAssertThrowsError(try d2.handleHello(hello2)) { XCTAssertTrue(isMalformed($0)) }

        for mutate in [{ (r: inout HelloReplyMessage) in r.nonce = Data(count: 16) },
                       { (r: inout HelloReplyMessage) in r.ephKey = Data(count: 31) },
                       { (r: inout HelloReplyMessage) in r.identityKey = Data(count: 0) }] {
            let ha = HostHandshake(identity: ident("H"), isKnownPeer: { _ in false })
            let da = DisplayHandshake(identity: ident("D"), isKnownPeer: { _ in false })
            var reply = try da.handleHello(ha.makeHello())
            mutate(&reply)
            XCTAssertThrowsError(try ha.handleHelloReply(reply)) { XCTAssertTrue(isMalformed($0)) }
        }

        let (h3, d3) = parties()
        let reply3 = try d3.handleHello(h3.makeHello())
        var reveal = try h3.handleHelloReply(reply3)
        reveal.nonce = Data(count: 31)
        XCTAssertThrowsError(try d3.handleReveal(reveal)) { XCTAssertTrue(isMalformed($0)) }
    }

    func testWrongState() throws {
        let (h, d) = parties()
        XCTAssertThrowsError(try h.handleHelloReply(HelloReplyMessage(v: 1, deviceId: "", deviceName: "", identityKey: Data(count: 32), ephKey: Data(count: 32), nonce: Data(count: 32), knowsPeer: false))) {
            XCTAssertEqual($0 as? HandshakeError, .wrongState)
        }
        XCTAssertThrowsError(try h.handleRevealReply(RevealReplyMessage(signature: Data(count: 64)))) {
            XCTAssertEqual($0 as? HandshakeError, .wrongState)
        }
        XCTAssertThrowsError(try d.handleReveal(RevealMessage(ephKey: Data(count: 32), nonce: Data(count: 32), signature: Data(count: 64)))) {
            XCTAssertEqual($0 as? HandshakeError, .wrongState)
        }
        let hello = h.makeHello()
        XCTAssertEqual(h.makeHello(), hello)  // idempotent
        let reply = try d.handleHello(hello)
        XCTAssertThrowsError(try d.handleHello(hello)) { XCTAssertEqual($0 as? HandshakeError, .wrongState) }
        XCTAssertThrowsError(try h.handleRevealReply(RevealReplyMessage(signature: Data(count: 64)))) {
            XCTAssertEqual($0 as? HandshakeError, .wrongState)
        }
        let reveal = try h.handleHelloReply(reply)
        XCTAssertThrowsError(try h.handleHelloReply(reply)) { XCTAssertEqual($0 as? HandshakeError, .wrongState) }
        let (rr, _) = try d.handleReveal(reveal)
        XCTAssertThrowsError(try d.handleReveal(reveal)) { XCTAssertEqual($0 as? HandshakeError, .wrongState) }
        _ = try h.handleRevealReply(rr)
        XCTAssertThrowsError(try h.handleRevealReply(rr)) { XCTAssertEqual($0 as? HandshakeError, .wrongState) }
    }
}
