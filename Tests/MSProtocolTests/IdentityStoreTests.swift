import XCTest
@testable import MSProtocol

final class IdentityStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-idstore-\(UUID().uuidString)")
            .appendingPathComponent("nested")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func peer(_ n: String, key: UInt8) -> Peer {
        Peer(deviceId: UUID().uuidString, deviceName: n, identityKey: Data(repeating: key, count: 32),
             pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testCreateAndReload() throws {
        let s = try IdentityStore(directory: dir, defaultDeviceName: "Test Mac")
        let file = dir.appendingPathComponent("identity.json")
        XCTAssertEqual(try mode(file), 0o600)
        let id = s.identity
        XCTAssertEqual(id.deviceName, "Test Mac")
        XCTAssertNotNil(UUID(uuidString: id.deviceId))
        let s2 = try IdentityStore(directory: dir, defaultDeviceName: "Other")
        XCTAssertEqual(s2.identity.deviceId, id.deviceId)
        XCTAssertEqual(s2.identity.deviceName, "Test Mac")
        XCTAssertEqual(s2.identity.signingKey.rawRepresentation, id.signingKey.rawRepresentation)
        XCTAssertEqual(s2.identity.publicKey, id.publicKey)
    }

    func testPeersPersist() throws {
        let s = try IdentityStore(directory: dir, defaultDeviceName: "M")
        let a = peer("A", key: 1), b = peer("B", key: 2)
        XCTAssertFalse(s.isKnown(identityKey: a.identityKey))
        try s.addPeer(a)
        try s.addPeer(b)
        XCTAssertTrue(s.isKnown(identityKey: a.identityKey))
        var a2 = a
        a2.deviceName = "A renamed"
        try s.addPeer(a2)
        XCTAssertEqual(s.peers.count, 2)
        var r = try IdentityStore(directory: dir, defaultDeviceName: "M")
        XCTAssertEqual(r.peers.count, 2)
        XCTAssertEqual(r.peer(identityKey: a.identityKey), a2)
        XCTAssertEqual(r.peer(identityKey: b.identityKey), b)
        try r.removePeer(identityKey: a.identityKey)
        r = try IdentityStore(directory: dir, defaultDeviceName: "M")
        XCTAssertEqual(r.peers, [b])
        XCTAssertFalse(r.isKnown(identityKey: a.identityKey))
        XCTAssertEqual(try mode(dir.appendingPathComponent("identity.json")), 0o600)
        // no temp files left behind
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["identity.json"])
    }

    func testCorruptFileThrowsAndIsUntouched() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("identity.json")
        let junk = Data("{ not json".utf8)
        try junk.write(to: file)
        XCTAssertThrowsError(try IdentityStore(directory: dir, defaultDeviceName: "M")) {
            XCTAssertEqual($0 as? IdentityStoreError, .corrupt)
        }
        XCTAssertEqual(try Data(contentsOf: file), junk)
    }

    func testDefaultDirectory() {
        XCTAssertTrue(IdentityStore.defaultDirectory().path.hasSuffix("Application Support/MacScreen"))
    }

    func testIdentityDirectoryIsMode0700() throws {
        let fm = FileManager.default
        func mode(_ u: URL) throws -> Int {
            ((try fm.attributesOfItem(atPath: u.path))[.posixPermissions] as! NSNumber).intValue & 0o777
        }
        let base = fm.temporaryDirectory.appendingPathComponent("ms-mode-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let fresh = base.appendingPathComponent("new")
        _ = try IdentityStore(directory: fresh, defaultDeviceName: "x")
        XCTAssertEqual(try mode(fresh), 0o700)
        let old = base.appendingPathComponent("old")
        try fm.createDirectory(at: old, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try IdentityStore(directory: old, defaultDeviceName: "x")
        XCTAssertEqual(try mode(old), 0o700)
    }
}
