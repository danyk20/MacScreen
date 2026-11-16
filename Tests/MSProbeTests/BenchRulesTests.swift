import XCTest
@testable import MSProbe

final class BenchRulesTests: XCTestCase {
    func testWarmupExclusion() {
        for (count, excluded) in [(5, 0), (10, 0), (11, 10), (90, 10)] {
            let input = (0..<count).map { Double($0) }
            let r = BenchRules.statsInput(latenciesInOrder: input)
            XCTAssertEqual(r.warmupExcluded, excluded, "count \(count)")
            XCTAssertEqual(r.measured.count, count - excluded, "count \(count)")
            if excluded > 0 { XCTAssertEqual(r.measured.first, Double(excluded)) }
        }
    }

    func testSummarizeIgnoresWarmup() {
        var l = [Double](repeating: 100, count: 10)
        l += [Double](repeating: 1, count: 20)
        let s = BenchRules.summarize(latenciesInOrder: l)
        XCTAssertEqual(s.max, 1)
        XCTAssertEqual(s.mean, 1, accuracy: 1e-9)
        XCTAssertEqual(s.warmupExcluded, 10)
    }

    func testConstants() {
        XCTAssertEqual(BenchRules.warmupFrames, 10)
        XCTAssertEqual(BenchRules.encodeP95Share, 0.5)
        XCTAssertEqual(BenchRules.decodeP95Share, 0.6)
        XCTAssertEqual(BenchRules.decodeThroughputFactor, 1.5)
    }
}
