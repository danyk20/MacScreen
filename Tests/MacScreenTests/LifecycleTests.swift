import XCTest
@testable import MacScreen

private final class FakeAssertions: PowerAssertions {
    var log: [String] = []
    func holdDisplayAwake() { log.append("hold") }
    func releaseDisplayAwake() { log.append("release") }
    func wakeDisplay() { log.append("wake") }
}

final class LifecycleTests: XCTestCase {
    func testPlistContent() throws {
        let data = try LoginItem.plistContent(executablePath: "/Applications/MacScreen.app/Contents/MacOS/MacScreen")
        let d = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(d["Label"] as? String, "app.macscreen.display")
        XCTAssertEqual(d["ProgramArguments"] as? [String],
                       ["/Applications/MacScreen.app/Contents/MacOS/MacScreen", "--role", "display"])
        XCTAssertEqual(d["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(d["KeepAlive"] as? Bool, false)
    }

    func testEnableDisableInTempDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ms-login-\(UUID().uuidString)/LaunchAgents")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        XCTAssertFalse(LoginItem.isEnabled(in: dir))
        try LoginItem.set(true, executablePath: "/x/MacScreen", in: dir)
        XCTAssertTrue(LoginItem.isEnabled(in: dir))
        XCTAssertEqual(LoginItem.plistURL(in: dir).lastPathComponent, "app.macscreen.display.plist")
        try LoginItem.set(false, executablePath: "/x/MacScreen", in: dir)
        XCTAssertFalse(LoginItem.isEnabled(in: dir))
        XCTAssertNoThrow(try LoginItem.disable(in: dir))
    }

    func testPowerFollowsConnectionAndHostState() {
        let f = FakeAssertions()
        let p = DisplayPowerController(assertions: f)
        p.hostStateChanged(displayAsleep: true)   // ignored: not connected
        XCTAssertEqual(f.log, [])
        p.hostConnected()
        XCTAssertEqual(f.log, ["wake", "hold"])
        p.hostStateChanged(displayAsleep: true)
        XCTAssertEqual(f.log.last, "release")
        p.hostStateChanged(displayAsleep: false)
        XCTAssertEqual(f.log.last, "hold")
        p.hostDisconnected()
        XCTAssertEqual(f.log.last, "release")
    }
}
