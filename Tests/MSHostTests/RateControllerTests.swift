import XCTest
import MSCore
import MSProtocol
@testable import MSHost

final class RateControllerTests: XCTestCase {
    private var rc = RateController(profileBitrate: 40_000_000, linkFecRatio: 0.10)
    private var t: UInt64 = 1_000_000
    private var recv: UInt32 = 0, lost: UInt32 = 0, dropped: UInt32 = 0

    /// Advance one second and feed a feedback packet with the given per-second counters.
    @discardableResult
    private func second(received: UInt32 = 1000, lost l: UInt32 = 0, framesLost: UInt32 = 0,
                        jitter: Double = 0) -> RateController.Output? {
        recv &+= received; lost &+= l; dropped &+= framesLost
        t += 1_000_000
        let fb = FeedbackPacket(highestDecodedFrame: 1, framesDecoded: 1, framesDropped: dropped,
                                fragsReceived: recv, fragsLost: lost, fragsRecovered: 0,
                                avgDecodeMs: 1, jitterMs: jitter, requestKeyframe: false)
        return rc.ingest(fb, nowMicros: t)
    }

    override func setUp() { _ = second() }  // baseline

    func testStartsAtSixtyPercent() {
        XCTAssertEqual(rc.bitrate, 24_000_000)
        XCTAssertEqual(rc.fecRatio, 0.10)
    }

    func testLossRampsDownToFloor() {
        for _ in 0..<40 { second(framesLost: 1) }
        XCTAssertEqual(rc.bitrate, MSConstants.minBitrate)
        _ = second(framesLost: 1)
        XCTAssertGreaterThanOrEqual(rc.bitrate, MSConstants.minBitrate)
    }

    func testSingleLossMultipliesByPointEight() {
        let o = second(framesLost: 1)
        XCTAssertEqual(o?.bitrate, 19_200_000)
    }

    func testHighJitterBacksOffMidJitterHolds() {
        XCTAssertEqual(second(jitter: 11)?.bitrate, 19_200_000)
        XCTAssertNil(second(jitter: 7))
    }

    func testRecoveryRampsUpSlowlyAndCaps() {
        for _ in 0..<10 { second(framesLost: 1) }
        let low = rc.bitrate
        let o = second()
        XCTAssertEqual(o?.bitrate, Int(Double(low) * 1.05))
        for _ in 0..<200 { second() }
        XCTAssertEqual(rc.bitrate, 40_000_000)
    }

    func testThroughputCap() {
        rc.throughputCapBps = 30_000_000
        for _ in 0..<100 { second() }
        XCTAssertEqual(rc.bitrate, 30_000_000)
    }

    func testEvaluatesOncePerSecond() {
        t += 1_000_000
        func fb() -> FeedbackPacket {
            FeedbackPacket(highestDecodedFrame: 1, framesDecoded: 1, framesDropped: 0, fragsReceived: 0,
                           fragsLost: 0, fragsRecovered: 0, avgDecodeMs: 0, jitterMs: 0, requestKeyframe: false)
        }
        XCTAssertNotNil(rc.ingest(fb(), nowMicros: t + 1_000_000))
        XCTAssertNil(rc.ingest(fb(), nowMicros: t + 1_100_000))
        XCTAssertNil(rc.ingest(fb(), nowMicros: t + 1_900_000))
    }

    func testFecStepsUpOnLossAndCaps() {
        XCTAssertEqual(second(lost: 30)?.fecRatio ?? 0, 0.15, accuracy: 1e-9)
        for _ in 0..<10 { second(lost: 30) }
        XCTAssertEqual(rc.fecRatio, 0.30, accuracy: 1e-9)
    }

    func testFecStepsDownAfterTenCleanSecondsToLinkDefault() {
        second(lost: 30); second(lost: 30)          // 0.20
        XCTAssertEqual(rc.fecRatio, 0.20, accuracy: 1e-9)
        for _ in 0..<9 { second() }
        XCTAssertEqual(rc.fecRatio, 0.20, accuracy: 1e-9)
        second()                                     // 10 s clean
        XCTAssertEqual(rc.fecRatio, 0.15, accuracy: 1e-9)
        for _ in 0..<40 { second() }
        XCTAssertEqual(rc.fecRatio, 0.10, accuracy: 1e-9)  // never below link default
    }

    func testFecFloorIsZeroOnWired() {
        rc = RateController(profileBitrate: 40_000_000, linkFecRatio: 0)
        _ = second()
        second(lost: 30)
        XCTAssertEqual(rc.fecRatio, 0.05, accuracy: 1e-9)
        for _ in 0..<12 { second() }
        XCTAssertEqual(rc.fecRatio, 0)
    }

    func testSwitchTo30fpsAfterFiveSecondsAtFloorOnce() {
        var switches = 0
        for _ in 0..<60 { if second(framesLost: 1)?.switchTo30fps == true { switches += 1 } }
        XCTAssertEqual(switches, 1)
        XCTAssertTrue(rc.fpsReduced)
    }
}
