import XCTest
@testable import MSProtocol

final class IdentityStoreSecurityTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ms-idsec-\(UUID().uuidString)")
        dirs.append(d)
        return d
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as! NSNumber).intValue & 0o777
    }

    func testIdentityFileIsOwnerOnlyAfterCreateAndEveryWrite() throws {
        let dir = tmp()
        let oldMask = umask(0o000)  // hostile umask must not widen the mode
        defer { umask(oldMask) }
        let s = try IdentityStore(directory: dir, defaultDeviceName: "A")
        let file = dir.appendingPathComponent("identity.json")
        XCTAssertEqual(try mode(file), 0o600)
        try s.addPeer(Peer(deviceId: UUID().uuidString, deviceName: "P", identityKey: Data(count: 32), pairedAt: Date()))
        XCTAssertEqual(try mode(file), 0o600)
        try s.removePeer(identityKey: Data(count: 32))
        XCTAssertEqual(try mode(file), 0o600)
        // No temp files left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["identity.json"])
    }

    func testReopenedFileKeepsIdentityAndMode() throws {
        let dir = tmp()
        let a = try IdentityStore(directory: dir, defaultDeviceName: "A")
        let b = try IdentityStore(directory: dir, defaultDeviceName: "other")
        XCTAssertEqual(a.identity.publicKey, b.identity.publicKey)
        XCTAssertEqual(a.identity.deviceId, b.identity.deviceId)
        XCTAssertEqual(try mode(dir.appendingPathComponent("identity.json")), 0o600)
    }

    func testCorruptAndMutatedFilesFailClosedWithoutCrash() throws {
        let dir = tmp()
        _ = try IdentityStore(directory: dir, defaultDeviceName: "A")
        let file = dir.appendingPathComponent("identity.json")
        let good = try Data(contentsOf: file)
        var rng = SeededRNG(21)
        var loaded = 0, rejected = 0
        for i in 0..<400 {
            var bad = rng.mutate(good)
            if i % 50 == 0 { bad = rng.bytes(Int.random(in: 0...300, using: &rng)) }
            if i % 50 == 1 { bad = Data() }
            try bad.write(to: file)
            do { _ = try IdentityStore(directory: dir, defaultDeviceName: "A"); loaded += 1 }
            catch IdentityStoreError.corrupt { rejected += 1 }
        }
        XCTAssertGreaterThan(rejected, 0)
        _ = loaded
        // Wrong-length key and non-UUID deviceId are rejected, never replaced silently by a fresh identity.
        let json = String(data: good, encoding: .utf8)!
        try Data(json.replacingOccurrences(of: "\"deviceId\" : \"", with: "\"deviceId\" : \"x").utf8).write(to: file)
        XCTAssertThrowsError(try IdentityStore(directory: dir, defaultDeviceName: "A")) {
            XCTAssertEqual($0 as? IdentityStoreError, .corrupt)
        }
        try Data("{\"deviceId\":\"\(UUID().uuidString)\",\"deviceName\":\"n\",\"signingKey\":\"AAAA\",\"peers\":[]}".utf8).write(to: file)
        XCTAssertThrowsError(try IdentityStore(directory: dir, defaultDeviceName: "A"))
    }
}
