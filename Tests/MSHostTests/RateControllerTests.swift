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
        for _ in 0..<41 { second(framesLost: 1) }
        XCTAssertEqual(rc.bitrate, MSConstants.minBitrate)
        _ = second(framesLost: 1)
        XCTAssertGreaterThanOrEqual(rc.bitrate, MSConstants.minBitrate)
    }

    func testSingleLossHoldsConsecutiveLossMultipliesByPointEight() {
        XCTAssertNil(second(framesLost: 1))
        XCTAssertEqual(rc.bitrate, 24_000_000)
        XCTAssertEqual(second(framesLost: 1)?.bitrate, 19_200_000)
        XCTAssertNotNil(second())             // clean: ramps up again
        XCTAssertNil(second(framesLost: 1))   // isolated again: hold
    }

    func testQueueingDelayBacksOffAndBlocksRampUp() {
        t += 1_000_000
        func fb() -> FeedbackPacket {
            FeedbackPacket(highestDecodedFrame: 1, framesDecoded: 1, framesDropped: 0, fragsReceived: 0,
                           fragsLost: 0, fragsRecovered: 0, avgDecodeMs: 0, jitterMs: 0, requestKeyframe: false)
        }
        _ = rc.ingest(fb(), nowMicros: t, rttMs: 20)            // baseline 20 ms, ramps up
        t += 1_000_000
        let b = rc.bitrate
        XCTAssertNil(rc.ingest(fb(), nowMicros: t, rttMs: 70))   // +50 ms: hold
        t += 1_000_000
        XCTAssertEqual(rc.ingest(fb(), nowMicros: t, rttMs: 300)?.bitrate, Int(Double(b) * 0.8))
    }

    func testHeavyPacketLossBacksOffAlone() {
        XCTAssertEqual(second(lost: 150)?.bitrate, 19_200_000)
    }

    func testStaleJitterWithoutMediaIsIgnored() {
        XCTAssertNotEqual(second(received: 5, jitter: 28)?.bitrate, 19_200_000)
        XCTAssertGreaterThanOrEqual(rc.bitrate, 24_000_000)
    }

    func testHighJitterBacksOffMidJitterHolds() {
        XCTAssertEqual(second(jitter: 26)?.bitrate, 19_200_000)
        XCTAssertNil(second(jitter: 15))
    }

    func testRecoveryRampsUpSlowlyAndCaps() {
        for _ in 0..<11 { second(framesLost: 1) }
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

    func testLinkCapSetsStartAndCeiling() {
        // P1: 18 Mbit/s measured -> cap 10.8; start = min(profile, cap), ramp-up never above it.
        var r = RateController(profileBitrate: 40_000_000, linkFecRatio: 0.1, throughputCapBps: 10_800_000)
        XCTAssertEqual(r.initialBitrate, 10_800_000)
        XCTAssertEqual(r.bitrate, 10_800_000)
        func fb(_ n: UInt32) -> FeedbackPacket {
            FeedbackPacket(highestDecodedFrame: n, framesDecoded: n, framesDropped: 0, fragsReceived: n * 100,
                           fragsLost: 0, fragsRecovered: 0, avgDecodeMs: 1, jitterMs: 2, requestKeyframe: false)
        }
        for i in 0..<20 { _ = r.ingest(fb(UInt32(i)), nowMicros: UInt64(i) * 1_000_000) }
        XCTAssertEqual(r.bitrate, 10_800_000)
        // A cap above the profile starts at the profile.
        XCTAssertEqual(RateController(profileBitrate: 8_000_000, linkFecRatio: 0, throughputCapBps: 50_000_000).initialBitrate,
                       8_000_000)
    }

    func testKeyframeFecBump() {
        XCTAssertEqual(RateController.frameFecRatio(0.10, isKeyframe: false), 0.10)
        XCTAssertEqual(RateController.frameFecRatio(0.10, isKeyframe: true), 0.20, accuracy: 1e-9)
        XCTAssertEqual(RateController.frameFecRatio(0.0, isKeyframe: true), 0.10, accuracy: 1e-9)
        XCTAssertEqual(RateController.frameFecRatio(0.25, isKeyframe: true), MSConstants.fecRatioMax)
    }

    /// Provisional decision P2: size-scaled pacing, at least 4 ms, at max(60 Mbit/s, 2.5 x bitrate).
    func testPacingIsSizeScaled() {
        XCTAssertEqual(RateController.paceMicros(wireBytes: 10_000, bitrate: 30_000_000), 4000)          // small: floor
        XCTAssertEqual(RateController.paceMicros(wireBytes: 450_000, bitrate: 30_000_000), 48_000)       // 4K keyframe at 75 Mbit/s
        XCTAssertEqual(RateController.paceMicros(wireBytes: 450_000, bitrate: 10_000_000), 60_000)       // 60 Mbit/s floor rate
        XCTAssertLessThan(RateController.paceMicros(wireBytes: 70_000, bitrate: 30_000_000), 1_000_000 / 60) // P-frame within a frame interval
    }
}
