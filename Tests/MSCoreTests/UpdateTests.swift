import XCTest
@testable import MSCore

final class SemanticVersionTests: XCTestCase {
    private func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    func testParsesAndPrints() {
        XCTAssertEqual(v("v1.2.3").description, "1.2.3")
        XCTAssertEqual(v("0.1.0-beta.2").description, "0.1.0-beta.2")
        XCTAssertEqual(v("1.0.0+build5").description, "1.0.0")
    }

    func testRejectsInvalid() {
        for bad in ["", "1", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "1.2.3-", "1.2.3-beta..1", "-1.2.3", "1.2.3-be ta"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testOrdering() {
        XCTAssertLessThan(v("0.1.0-beta.1"), v("0.1.0-beta.2"))
        XCTAssertLessThan(v("0.1.0-beta.2"), v("0.1.0-beta.10"))     // numeric, not lexical
        XCTAssertLessThan(v("0.1.0-beta.2"), v("0.1.0"))             // release beats its pre-release
        XCTAssertLessThan(v("0.1.0"), v("0.1.1"))
        XCTAssertLessThan(v("0.9.9"), v("1.0.0"))
        XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-alpha.1"))
        XCTAssertLessThan(v("1.0.0-1"), v("1.0.0-alpha"))            // numeric before alphanumeric
        XCTAssertLessThan(v("1.0.0-alpha"), v("1.0.0-beta"))
        XCTAssertFalse(v("1.0.0") < v("1.0.0"))
    }
}

final class ReleaseFeedTests: XCTestCase {
    private func asset(_ tag: String, _ name: String, repo: String = "danyk20/MacScreen", host: String = "github.com") -> String {
        "{\"name\":\"\(name)\",\"browser_download_url\":\"https://\(host)/\(repo)/releases/download/\(tag)/\(name)\",\"size\":123}"
    }

    private func release(_ tag: String, pre: Bool = false, draft: Bool = false, assets: [String]? = nil) -> String {
        let a = assets ?? [asset(tag, "MacScreen-\(tag).dmg"), asset(tag, "SHA256SUMS.txt"), asset(tag, "MacScreen-\(tag)-macOS.zip")]
        return "{\"tag_name\":\"\(tag)\",\"draft\":\(draft),\"prerelease\":\(pre),\"html_url\":\"https://github.com/danyk20/MacScreen/releases/tag/\(tag)\",\"body\":\"notes \(tag)\",\"assets\":[\(a.joined(separator: ","))]}"
    }

    private func feed(_ items: [String]) -> Data { Data("[\(items.joined(separator: ","))]".utf8) }

    func testParsesUsableRelease() {
        let r = ReleaseFeed.parse(feed([release("v0.1.0-beta.3", pre: true)]))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].version.description, "0.1.0-beta.3")
        XCTAssertEqual(r[0].dmg.name, "MacScreen-v0.1.0-beta.3.dmg")
        XCTAssertEqual(r[0].checksums.name, "SHA256SUMS.txt")
        XCTAssertEqual(r[0].notes, "notes v0.1.0-beta.3")
    }

    func testSkipsDraftsAndReleasesWithoutAssets() {
        let r = ReleaseFeed.parse(feed([
            release("v1.0.0", draft: true),
            release("v0.9.0", assets: [asset("v0.9.0", "MacScreen-v0.9.0-macOS.zip")]),
            release("v0.8.0"),
        ]))
        XCTAssertEqual(r.map(\.tag), ["v0.8.0"])
    }

    func testRejectsForeignDownloadURLs() {
        let evilHost = release("v2.0.0", assets: [asset("v2.0.0", "MacScreen-v2.0.0.dmg", host: "evil.example"),
                                                  asset("v2.0.0", "SHA256SUMS.txt")])
        let evilRepo = release("v2.0.1", assets: [asset("v2.0.1", "MacScreen-v2.0.1.dmg", repo: "someone/else"),
                                                  asset("v2.0.1", "SHA256SUMS.txt")])
        XCTAssertTrue(ReleaseFeed.parse(feed([evilHost, evilRepo])).isEmpty)
    }

    func testGarbageJSONIsEmpty() {
        XCTAssertTrue(ReleaseFeed.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(ReleaseFeed.parse(Data("{}".utf8)).isEmpty)
    }

    func testNewerPicksHighestAndRespectsChannel() {
        let rs = ReleaseFeed.parse(feed([
            release("v0.1.0-beta.3", pre: true), release("v0.1.0-beta.4", pre: true), release("v0.0.9"),
        ]))
        let beta2 = SemanticVersion("0.1.0-beta.2")!
        XCTAssertEqual(ReleaseFeed.newer(than: beta2, in: rs)?.tag, "v0.1.0-beta.4")
        // A stable build ignores pre-releases.
        XCTAssertNil(ReleaseFeed.newer(than: SemanticVersion("0.1.0")!, in: rs))
        // Already current: nothing.
        XCTAssertNil(ReleaseFeed.newer(than: SemanticVersion("0.1.0-beta.4")!, in: rs))
    }

    func testStableFollowsStable() {
        let rs = ReleaseFeed.parse(feed([release("v1.0.0"), release("v1.1.0-rc.1", pre: true)]))
        XCTAssertEqual(ReleaseFeed.newer(than: SemanticVersion("0.9.0")!, in: rs)?.tag, "v1.0.0")
    }
}

final class ChecksumFileTests: XCTestCase {
    func testParsesShasumFormats() {
        let h1 = String(repeating: "a", count: 64), h2 = String(repeating: "B", count: 64)
        let m = ChecksumFile.parse("\(h1)  ./MacScreen-v1.dmg\n\(h2) *other.zip\nbad line\n\(h1)\n")
        XCTAssertEqual(m["MacScreen-v1.dmg"], h1)
        XCTAssertEqual(m["other.zip"], h2.lowercased())
        XCTAssertEqual(m.count, 2)
    }
}

final class SwapScriptTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeApp(_ url: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try marker.write(to: url.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
    }

    private func marker(_ url: URL) -> String? {
        try? String(contentsOf: url.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }

    private func runSwap(target: URL, new: URL) throws -> Int32 {
        let script = root.appendingPathComponent("swap.sh")
        try SwapScript.text.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // pid 1 is alive forever, so use a pid that cannot exist to skip the wait loop.
        p.arguments = [script.path, "99999999", target.path, new.path]
        p.environment = ["MS_OPEN": "/usr/bin/true", "PATH": "/usr/bin:/bin"]
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    func testReplacesAppAndRemovesBackupAndStaging() throws {
        let target = root.appendingPathComponent("Apps/MacScreen.app")
        let new = root.appendingPathComponent("work/new/MacScreen.app")
        try makeApp(target, marker: "old"); try makeApp(new, marker: "new")
        XCTAssertEqual(try runSwap(target: target, new: new), 0)
        XCTAssertEqual(marker(target), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".previous"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("work").path))
    }

    func testKeepsOldAppWhenNewBundleIsMissing() throws {
        let target = root.appendingPathComponent("Apps/MacScreen.app")
        try makeApp(target, marker: "old")
        let missing = root.appendingPathComponent("work/new/MacScreen.app")
        XCTAssertEqual(try runSwap(target: target, new: missing), 0)
        XCTAssertEqual(marker(target), "old")
    }

    func testPathsWithSpacesAndQuotes() throws {
        let target = root.appendingPathComponent("My Apps/Mac \"Screen\".app")
        let new = root.appendingPathComponent("work dir/new/MacScreen.app")
        try makeApp(target, marker: "old"); try makeApp(new, marker: "new")
        XCTAssertEqual(try runSwap(target: target, new: new), 0)
        XCTAssertEqual(marker(target), "new")
    }
}
