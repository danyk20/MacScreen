import XCTest
@testable import MSCore

final class LatencyStatsTests: XCTestCase {
    func testPercentiles() {
        var s = LatencyStats(window: 100)
        XCTAssertEqual(s.p50, 0); XCTAssertEqual(s.p95, 0); XCTAssertEqual(s.max, 0)
        for i in 1...100 { s.add(Double(i)) }
        XCTAssertEqual(s.p50, 50); XCTAssertEqual(s.p95, 95); XCTAssertEqual(s.max, 100)
    }

    func testWindowRolls() {
        var s = LatencyStats(window: 10)
        for _ in 0..<10 { s.add(100) }
        for _ in 0..<10 { s.add(1) }
        XCTAssertEqual(s.count, 10)
        XCTAssertEqual(s.max, 1)
        s.reset()
        XCTAssertEqual(s.count, 0)
    }

    func testRecorderOffsetAndCSV() {
        let r = LatencyRecorder()
        r.setClockOffset(5_000)   // host clock is 5 ms ahead of display clock
        r.frameComplete(frameId: 1, captureMicros: 1_000_000, firstFragMicros: 1_004_000, completeMicros: 1_005_000)
        r.decodeStarted(captureMicros: 1_000_000, atMicros: 1_005_500)
        r.decodeDone(captureMicros: 1_000_000, atMicros: 1_008_000)
        r.presented(captureMicros: 1_000_000, atMicros: 1_015_000)
        XCTAssertEqual(r.snapshot.p50, 20.0, accuracy: 1e-9)
        let lines = r.csv().split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasSuffix("20.000"))
        // Unknown frame is ignored.
        r.presented(captureMicros: 42, atMicros: 50)
        XCTAssertEqual(r.rowCount, 1)
    }
}
