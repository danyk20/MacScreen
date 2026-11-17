import XCTest
@testable import MSDisplay

final class NoSignalMonitorTests: XCTestCase {
    func testNoBadgeWithoutSession() {
        let m = NoSignalMonitor()
        XCTAssertFalse(m.showsNoSignal(now: 1000))
    }

    func testShowsAfterThresholdAndClearsOnFrame() {
        var m = NoSignalMonitor()
        m.sessionStarted(now: 10)
        XCTAssertFalse(m.showsNoSignal(now: 12.9))
        m.frame(now: 12)
        XCTAssertFalse(m.showsNoSignal(now: 14.9))
        XCTAssertTrue(m.showsNoSignal(now: 15.1))
        m.frame(now: 16)
        XCTAssertFalse(m.showsNoSignal(now: 16.5))
    }

    func testHostAsleepHasItsOwnMessage() {
        var m = NoSignalMonitor()
        m.sessionStarted(now: 0)
        m.setHostAsleep(true)
        XCTAssertFalse(m.showsNoSignal(now: 100))
        m.setHostAsleep(false)
        XCTAssertTrue(m.showsNoSignal(now: 100))
    }

    func testSessionEndClears() {
        var m = NoSignalMonitor()
        m.sessionStarted(now: 0)
        m.sessionEnded()
        XCTAssertFalse(m.showsNoSignal(now: 100))
    }
}
