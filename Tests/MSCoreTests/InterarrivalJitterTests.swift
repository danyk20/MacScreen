import XCTest
@testable import MSCore

final class InterarrivalJitterTests: XCTestCase {
    func testConstantDelayIsZeroJitter() {
        var j = InterarrivalJitter()
        for i in 0..<100 { j.add(key: UInt32(i), sentMicros: UInt64(i) * 16_667, arrivedMicros: 5_000_000 + UInt64(i) * 16_667) }
        XCTAssertEqual(j.jitterMs, 0, accuracy: 0.001)
    }

    func testAlternatingDelayConvergesToDeviation() {
        // Transit alternates 10 ms / 30 ms: |D| = 20 ms every frame, so J converges to 20 ms.
        var j = InterarrivalJitter()
        for i in 0..<400 {
            let transit: UInt64 = i % 2 == 0 ? 10_000 : 30_000
            j.add(key: UInt32(i), sentMicros: UInt64(i) * 16_667, arrivedMicros: UInt64(i) * 16_667 + transit)
        }
        XCTAssertEqual(j.jitterMs, 20, accuracy: 0.5)
    }

    func testIgnoresOldFramesAndLongGaps() {
        var j = InterarrivalJitter()
        j.add(key: 10, sentMicros: 0, arrivedMicros: 1_000)
        j.add(key: 9, sentMicros: 100_000, arrivedMicros: 900_000)      // older frame: ignored
        XCTAssertEqual(j.jitterMicros, 0)
        j.add(key: 11, sentMicros: 5_000_000, arrivedMicros: 9_000_000) // 5 s gap: no sample
        XCTAssertEqual(j.jitterMicros, 0)
        j.add(key: 12, sentMicros: 5_016_667, arrivedMicros: 9_016_667 + 16_000)
        XCTAssertEqual(j.jitterMicros, 1_000, accuracy: 1)
    }
}
