import XCTest
@testable import MSCore

final class StatsClockTests: XCTestCase {
    func testRollingStatsKnownData() {
        var s = RollingStats(window: 100)
        XCTAssertEqual(s.count, 0)
        XCTAssertEqual(s.mean, 0)
        XCTAssertEqual(s.p95, 0)
        XCTAssertEqual(s.max, 0)
        for i in 1...100 { s.add(Double(i)) }
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(s.mean, 50.5, accuracy: 1e-9)
        XCTAssertEqual(s.p95, 95)
        XCTAssertEqual(s.max, 100)
        s.reset()
        XCTAssertEqual(s.count, 0)
        XCTAssertEqual(s.p95, 0)
    }

    func testRollingStatsEviction() {
        var s = RollingStats(window: 4)
        for i in 1...10 { s.add(Double(i)) }
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.mean, 8.5, accuracy: 1e-9)  // 7,8,9,10
        XCTAssertEqual(s.max, 10)
        XCTAssertEqual(s.p95, 10)
    }

    func testCounterConcurrent() {
        let c = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<10_000 { c.add(1) }
        }
        XCTAssertEqual(c.value, 80_000)
        XCTAssertEqual(c.takeAndReset(), 80_000)
        XCTAssertEqual(c.value, 0)
    }

    func testMonoClock() {
        let a = MonoClock.nowMicros()
        let b = MonoClock.nowMicros()
        XCTAssertGreaterThanOrEqual(b, a)
        let start = MonoClock.nowMicros()
        Thread.sleep(forTimeInterval: 0.05)
        let dtMs = Double(MonoClock.nowMicros() - start) / 1000
        XCTAssertGreaterThan(dtMs, 40)
        XCTAssertLessThan(dtMs, 200)
        XCTAssertEqual(MonoClock.micros(fromMachTicks: 0), 0)
        _ = MonoClock.micros(fromMachTicks: UInt64.max)  // must not trap
    }

    func testConstantsAndLog() {
        XCTAssertEqual(MSConstants.protoVersion, 1)
        XCTAssertEqual(MSConstants.logSubsystem, "app.macscreen")
        Log.logger("test").debug("ok")
    }
}
