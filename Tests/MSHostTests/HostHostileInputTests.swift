import XCTest
import MSCore
import MSProtocol
@testable import MSHost

/// Host-side handling of values a (paired but misbehaving) Display can put in feedback, NACK and pong packets.
final class HostHostileInputTests: XCTestCase {
    private struct RNG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testRateControllerSurvivesRandomFeedback() {
        var rng = RNG(s: 51)
        for round in 0..<20 {
            var rc = RateController(profileBitrate: [0, 3_000_000, 50_000_000, Int.max / 4][round % 4],
                                    linkFecRatio: [-1, 0, 0.1, 5, .nan][round % 5],
                                    throughputCapBps: round % 3 == 0 ? nil : [0, -5, Int.max / 4][round % 3])
            var now: UInt64 = UInt64.random(in: 0...UInt64.max, using: &rng)
            for _ in 0..<1000 {
                now = now &+ UInt64.random(in: 0...3_000_000, using: &rng)
                let pick = { () -> UInt32 in Bool.random(using: &rng) ? UInt32.random(in: 0...UInt32.max, using: &rng) : UInt32.random(in: 0...50, using: &rng) }
                let fb = FeedbackPacket(highestDecodedFrame: pick(), framesDecoded: pick(), framesDropped: pick(),
                                        fragsReceived: pick(), fragsLost: pick(), fragsRecovered: pick(),
                                        avgDecodeMsX10: UInt16.random(in: 0...UInt16.max, using: &rng),
                                        jitterMsX10: UInt16.random(in: 0...UInt16.max, using: &rng),
                                        requestKeyframe: Bool.random(using: &rng))
                let rtt: Double? = [nil, 0, 10, 1e12, -1, .nan, .infinity, -.infinity].randomElement(using: &rng)!
                if let out = rc.ingest(fb, nowMicros: now, rttMs: rtt) {
                    XCTAssertGreaterThanOrEqual(out.bitrate, MSConstants.minBitrate)
                    XCTAssertTrue(out.fecRatio >= 0 && out.fecRatio <= MSConstants.fecRatioMax, "fec \(out.fecRatio)")
                }
            }
        }
    }

    func testPacketHistoryRandomNacksBounded() throws {
        var rng = RNG(s: 52)
        let h = PacketHistory()
        for id in 0..<20 as Range<UInt32> {
            let f = try Fragmenter.fragment(payload: Data(repeating: UInt8(id), count: 1200 * 70 + 5), frameId: id,
                                            isKeyframe: false, captureTimeMicros: 1, fecRatio: 0.1)
            h.record(frameId: id, fragments: f, nowMicros: UInt64(id) * 1000)
        }
        for _ in 0..<20_000 {
            let n = NackPacket(frameId: UInt32.random(in: 0...30, using: &rng),
                               blockIndex: UInt8.random(in: 0...255, using: &rng),
                               fragIndices: (0..<Int.random(in: 0...255, using: &rng)).map { _ in UInt16.random(in: 0...UInt16.max, using: &rng) })
            let out = h.retransmissions(for: n, nowMicros: UInt64.random(in: 0...30_000, using: &rng))
            // A NACK can never fetch more than the data fragments of one frame.
            XCTAssertLessThanOrEqual(out.count, 70 + 1)
        }
        XCTAssertLessThanOrEqual(h.frameCount, 20)
    }
}
