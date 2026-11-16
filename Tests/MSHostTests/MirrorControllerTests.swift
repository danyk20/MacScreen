import CoreGraphics
import XCTest
@testable import MSHost

private final class FakeBackend: MirrorBackend {
    var main: CGDirectDisplayID = 1
    var calls: [(CGDirectDisplayID, CGDirectDisplayID?)] = []
    var fail = false
    func mainDisplayID() -> CGDirectDisplayID { main }
    func configureMirror(display: CGDirectDisplayID, of target: CGDirectDisplayID?) throws {
        if fail { throw VirtualDisplayError.mirrorFailed(1) }
        calls.append((display, target))
    }
}

final class MirrorControllerTests: XCTestCase {
    func testExtendByDefault() {
        let b = FakeBackend()
        let m = MirrorController(backend: b)
        m.attach(displayID: 9)
        XCTAssertFalse(m.isMirroring)
        XCTAssertTrue(b.calls.isEmpty)
    }

    func testToggleAndRestoreOnDetach() {
        let b = FakeBackend()
        let m = MirrorController(backend: b)
        m.attach(displayID: 9)
        XCTAssertTrue(m.setMirror(true))
        XCTAssertEqual(b.calls.count, 1)
        XCTAssertEqual(b.calls[0].0, 9); XCTAssertEqual(b.calls[0].1, 1)
        m.detach()
        XCTAssertFalse(m.isMirroring)
        XCTAssertEqual(b.calls.count, 2)
        XCTAssertNil(b.calls[1].1)
        XCTAssertTrue(m.wantsMirror, "preference survives the session")
        m.attach(displayID: 10)
        XCTAssertTrue(m.isMirroring, "preference re-applied to the next display")
    }

    func testToggleWithoutSessionOnlyStoresPreference() {
        let b = FakeBackend()
        let m = MirrorController(backend: b)
        XCTAssertFalse(m.setMirror(true))
        XCTAssertTrue(b.calls.isEmpty)
        m.detach()
        XCTAssertTrue(b.calls.isEmpty)
    }

    func testFailureLeavesExtendAndNeverMirrorsSelf() {
        let b = FakeBackend()
        let m = MirrorController(backend: b)
        m.attach(displayID: 9)
        b.fail = true
        XCTAssertFalse(m.setMirror(true))
        b.fail = false
        b.main = 9
        m.setMirror(false); m.setMirror(true)
        XCTAssertFalse(m.isMirroring)
        XCTAssertTrue(b.calls.isEmpty)
    }

    func testSerialDerivationIsStableSha256Prefix() {
        // SHA-256("abc") = ba7816bf 8f01cfea ...
        XCTAssertEqual(VirtualDisplay.serial(forDeviceId: "abc"), 0xba7816bf)
        XCTAssertEqual(VirtualDisplay.serial(forDeviceId: "x"), VirtualDisplay.serial(forDeviceId: "x"))
        XCTAssertNotEqual(VirtualDisplay.serial(forDeviceId: "x"), VirtualDisplay.serial(forDeviceId: "y"))
    }

    func testWakeResumeWaitsAndNeedsDisplaySeen() {
        var p = ReconnectPolicy()
        p.userConnect(id: "d")
        XCTAssertEqual(p.sleepResumeTarget, "d")
        p.sessionEnded(.stopped, now: 10)
        XCTAssertFalse(p.enabled)
        p.resumeAfterWake(id: "d", now: 100)
        XCTAssertFalse(p.shouldReconnect(seenIds: ["d"], now: 101), "settle delay")
        XCTAssertFalse(p.shouldReconnect(seenIds: [], now: 200), "display not seen")
        XCTAssertTrue(p.shouldReconnect(seenIds: ["d"], now: 100 + ReconnectPolicy.wakeSettleDelay))
    }
}
