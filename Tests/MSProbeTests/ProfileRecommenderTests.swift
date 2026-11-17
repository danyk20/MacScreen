import XCTest
import MSCore
import MSCodec
import MSProtocol
@testable import MSProbe

final class ProfileRecommenderTests: XCTestCase {
    private func cand(_ codec: Codec, _ w: Int, _ h: Int, fps: Int = 60) -> Candidate {
        let bpp = codec == .hevc ? MSConstants.bitsPerPixelHEVC : MSConstants.bitsPerPixelH264
        return Candidate(format: VideoFormat(codec: codec, width: w, height: h, fps: fps, bitDepth: 8), hiDPI: true,
                         bitrate: Int(Double(w * h * fps) * bpp))
    }

    private func enc(_ c: Candidate, p95: Double, passed: Bool = true) -> BenchResult {
        BenchResult(format: c.format, bitrate: c.bitrate, frames: 80, hardware: true, meanMs: p95 / 2, p95Ms: p95,
                    maxMs: p95 * 2, throughputFps: 60, passed: passed, failureReason: passed ? nil : "failed")
    }

    private func dec(_ c: Candidate, p95: Double = 3, fps: Double = 300, hw: Bool = true, passed: Bool = true) -> BenchResult {
        BenchResult(format: c.format, bitrate: c.bitrate, frames: 80, hardware: hw, meanMs: p95 / 2, p95Ms: p95,
                    maxMs: p95 * 2, throughputFps: fps, passed: passed, failureReason: passed ? nil : "failed")
    }

    private func link(_ losses: [(Int, Double)]) -> LinkResult {
        LinkResult(trains: losses.map { LinkTrainResult(rateBps: $0.0 * 1_000_000, sent: 1000,
                                                        received: Int(1000 * (1 - $0.1)), jitterMs: 0.5) })
    }

    private let fast = [(10, 0.0), (20, 0.0), (40, 0.0), (80, 0.0), (160, 0.0)]

    func testPicksFirstFullyPassingCandidate() {
        let a = cand(.hevc, 3840, 2160)          // 29.9 Mbit/s
        let b = cand(.hevc, 2880, 1620)
        let outcomes = [CandidateOutcome(candidate: a, encode: enc(a, p95: 20), decode: dec(a)),  // encode too slow
                        CandidateOutcome(candidate: b, encode: enc(b, p95: 5), decode: dec(b))]
        let r = ProfileRecommender.recommend(outcomes: outcomes, link: link(fast), interface: .wired)
        XCTAssertEqual(r.candidate, b)
        XCTAssertEqual(r.rejections.count, 1)
        XCTAssertEqual(r.rejections[0].candidate, a)
        XCTAssertTrue(r.rejections[0].reason.contains("encode p95"))
        XCTAssertEqual(r.fecRatio, MSConstants.fecRatioWired)
    }

    func testEncodePassRuleBoundary() {
        // 60 fps: interval 16.667 ms, limit 0.85 * interval = 14.167 ms
        let a = cand(.hevc, 1920, 1080)
        func pick(_ p95: Double) -> Candidate? {
            ProfileRecommender.recommend(outcomes: [CandidateOutcome(candidate: a, encode: enc(a, p95: p95), decode: dec(a))],
                                         link: link(fast), interface: .wired).candidate
        }
        XCTAssertNotNil(pick(14.0))
        XCTAssertNil(pick(14.2))
        // The recommender enforces the rule itself even if the bench said "passed".
        XCTAssertNil(pick(16.0))
    }

    func testDecodeRules() {
        let a = cand(.hevc, 1920, 1080)
        func reason(_ d: BenchResult) -> String? {
            ProfileRecommender.recommend(outcomes: [CandidateOutcome(candidate: a, encode: enc(a, p95: 5), decode: d)],
                                         link: link(fast), interface: .wired).rejections.first?.reason
        }
        XCTAssertNil(reason(dec(a)))
        XCTAssertTrue(reason(dec(a, p95: 10.5))?.contains("decode p95") == true)   // limit 0.6 * 16.67 = 10 ms
        XCTAssertTrue(reason(dec(a, fps: 80))?.contains("throughput") == true)    // needs 1.5 * 60 = 90
        XCTAssertTrue(reason(dec(a, hw: false))?.contains("hardware") == true)
        XCTAssertTrue(reason(dec(a, passed: false))?.contains("decode failed") == true)
    }

    func testNoH264AboveLimit() {
        let big = cand(.h264, 5120, 2880)
        let r = ProfileRecommender.recommend(
            outcomes: [CandidateOutcome(candidate: big, encode: enc(big, p95: 1), decode: dec(big))],
            link: link([(10, 0), (160, 0)]), interface: .wired)
        XCTAssertNil(r.candidate)
        XCTAssertTrue(r.rejections[0].reason.contains("4096x2304"))
        // The ladder never generates it.
        XCTAssertFalse(CandidateLadder.make(panelWidth: 5120, panelHeight: 2880)
            .contains { $0.format.codec == .h264 && ($0.format.width > 4096 || $0.format.height > 2304) })
        // Exactly at the limit is allowed.
        let ok = cand(.h264, 4096, 2304)
        XCTAssertNotNil(ProfileRecommender.recommend(
            outcomes: [CandidateOutcome(candidate: ok, encode: enc(ok, p95: 1), decode: dec(ok))],
            link: link([(10, 0), (160, 0)]), interface: .wired).candidate)
    }

    func testHEVCEncoderUsesNoLowLatencyRateControl() throws {
        let f = VideoFormat(codec: .hevc, width: 640, height: 360, fps: 60, bitDepth: 8)
        let e = try VideoEncoder(format: f, bitrate: 3_000_000) { _ in }
        defer { e.invalidate() }
        XCTAssertFalse(e.usesLowLatencyRateControl)
    }

    func testLinkBudget() {
        let a = cand(.hevc, 3840, 2160)   // 29.9 Mbit/s
        let b = cand(.hevc, 1920, 1080)   // 7.5 Mbit/s
        let outcomes = [CandidateOutcome(candidate: a, encode: enc(a, p95: 5), decode: dec(a)),
                        CandidateOutcome(candidate: b, encode: enc(b, p95: 5), decode: dec(b))]
        // 20 Mbit/s usable -> budget 12 Mbit/s: a's bitrate at 0.04 bpp (19.9) does not fit, b's (5.0) does.
        var r = ProfileRecommender.recommend(outcomes: outcomes, link: link([(10, 0), (20, 0), (40, 0.05)]),
                                             interface: .wired)
        XCTAssertEqual(r.throughputBps, 20_000_000)
        XCTAssertEqual(r.candidate, b)
        XCTAssertTrue(r.rejections[0].reason.contains("link budget"))
        XCTAssertEqual(r.bitrate, b.bitrate)    // min(profile 7.46, 12) = profile
        // 40 Mbit/s usable -> budget 24 admits a (min 19.9); start bitrate = min(29.86, 24) = 24 Mbit/s.
        r = ProfileRecommender.recommend(outcomes: outcomes, link: link([(10, 0), (20, 0), (40, 0), (80, 0.05)]),
                                         interface: .wired)
        XCTAssertEqual(r.candidate, a)
        XCTAssertEqual(r.bitrate, 24_000_000)
        // Exact boundary of the minimum: 33.2 Mbit/s * 0.6 = 19.9 admits a, just below does not.
        r = ProfileRecommender.recommend(outcomes: outcomes, link: link([(10, 0), (50, 0)]), interface: .wired)
        XCTAssertEqual(r.candidate, a)
        XCTAssertEqual(r.bitrate, a.bitrate)   // 0.6 * 50 = 30 > profile 29.86
        // Nothing usable: everything rejected.
        r = ProfileRecommender.recommend(outcomes: outcomes, link: link([(10, 0.5)]), interface: .wired)
        XCTAssertNil(r.candidate)
        XCTAssertEqual(r.rejections.count, 2)
    }

    func testManualOnlyNeverChosen() {
        var a = cand(.hevc, 5120, 2880, fps: 30)
        a.manualOnly = true
        let r = ProfileRecommender.recommend(
            outcomes: [CandidateOutcome(candidate: a, encode: enc(a, p95: 5), decode: dec(a))],
            link: link(fast), interface: .wired)
        XCTAssertNil(r.candidate)
        XCTAssertEqual(r.rejections[0].reason, "manual selection only")
    }

    func testSkipAndMissingSteps() {
        let a = cand(.hevc, 1920, 1080)
        let r = ProfileRecommender.recommend(outcomes: [
            CandidateOutcome(candidate: a, skipReason: "Display has no hardware HEVC decoder"),
            CandidateOutcome(candidate: a),
            CandidateOutcome(candidate: a, encode: enc(a, p95: 5)),
        ], link: link(fast), interface: .wired)
        XCTAssertNil(r.candidate)
        XCTAssertEqual(r.rejections.map { $0.reason }, [
            "Display has no hardware HEVC decoder", "encode benchmark not run", "decode benchmark not run"])
    }

    func testFecRatio() {
        XCTAssertEqual(ProfileRecommender.fecRatio(interface: .wired, link: link(fast)), 0.0)
        XCTAssertEqual(ProfileRecommender.fecRatio(interface: .wifi, link: link(fast)), 0.10)
        XCTAssertEqual(ProfileRecommender.fecRatio(interface: .other, link: nil), 0.10)
        // Wired with 0.2 % loss at the usable rate: Wi-Fi default.
        XCTAssertEqual(ProfileRecommender.fecRatio(interface: .wired, link: link([(10, 0), (20, 0.002)])), 0.10)
        // 0.9 % loss: one extra step.
        XCTAssertEqual(ProfileRecommender.fecRatio(interface: .wifi, link: link([(10, 0.009)])), 0.15, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(ProfileRecommender.fecRatio(interface: .wifi, link: link([(10, 0.0099)])),
                                 MSConstants.fecRatioMax)
    }

    func testApplyToSettings() {
        let a = cand(.h264, 2560, 1440, fps: 30)
        let r = Recommendation(candidate: a, bitrate: a.bitrate, fecRatio: 0.1, throughputBps: 1, rejections: [])
        var s = AppSettings()
        s.bitrateCapMbps = 40
        let out = r.apply(to: s, panelHeight: 2880)
        XCTAssertEqual(out.maxHeight, 1440)
        XCTAssertEqual(out.fps, 30)
        XCTAssertEqual(out.codec, "h264")
        XCTAssertEqual(out.bitrateCapMbps, 0)
        XCTAssertEqual(out.fecRatio, 0.1)
        // Native height maps to 0; odd heights snap to the next lower option.
        let full = cand(.hevc, 5120, 2880)
        XCTAssertEqual(Recommendation(candidate: full, bitrate: 1, fecRatio: 0, throughputBps: 1, rejections: [])
            .apply(to: s, panelHeight: 2880).maxHeight, 0)
        let odd = cand(.hevc, 2880, 1620)
        XCTAssertEqual(Recommendation(candidate: odd, bitrate: 1, fecRatio: 0, throughputBps: 1, rejections: [])
            .apply(to: s, panelHeight: 2880).maxHeight, 1440)
        // No candidate: unchanged.
        XCTAssertEqual(Recommendation(candidate: nil, bitrate: 0, fecRatio: 0, throughputBps: 0, rejections: [])
            .apply(to: s, panelHeight: 2880), s)
    }

    func testCachePerDisplayAndInterface() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "ms-probe-test-\(UUID().uuidString)"))
        let a = cand(.hevc, 1920, 1080)
        let rec = Recommendation(candidate: a, bitrate: a.bitrate, fecRatio: 0, throughputBps: 1, rejections: [])
        func outcome(_ id: String, _ i: LinkInterface, _ date: Date) -> ProbeOutcome {
            ProbeOutcome(displayId: id, displayName: "n", interface: i, panelWidth: 1, panelHeight: 1, date: date,
                         link: link(fast), outcomes: [], recommendation: rec)
        }
        ProbeCache.store(outcome("D1", .wired, Date(timeIntervalSince1970: 100)), in: d)
        ProbeCache.store(outcome("D1", .wifi, Date(timeIntervalSince1970: 200)), in: d)
        XCTAssertNotNil(ProbeCache.load(displayId: "D1", interface: .wired, from: d))
        XCTAssertNil(ProbeCache.load(displayId: "D1", interface: .other, from: d))
        XCTAssertNil(ProbeCache.load(displayId: "D2", interface: .wired, from: d))
        XCTAssertEqual(ProbeCache.latest(displayId: "D1", from: d)?.interface, .wifi)
        XCTAssertEqual(ProbeCache.load(displayId: "D1", interface: .wired, from: d)?.recommendation.candidate, a)
    }

    func testLinkResultAndReceiver() {
        let l = link([(10, 0), (20, 0.005), (40, 0.02), (80, 0.0)])
        XCTAssertEqual(l.usableThroughputBps, 80_000_000)    // highest rate under 1 % loss
        XCTAssertEqual(LinkProbe.packetCount(rateBps: 10_000_000, durationMs: 500), 520)
        let rx = LinkProbeReceiver()
        rx.expect(LinkProbeStartMessage(trainId: 5, rateBps: 0, durationMs: 100, packetCount: 4))
        for (i, t) in [UInt64(1000), 26000, 51000, 76000].enumerated() {
            XCTAssertFalse(rx.isComplete(5))
            rx.packet(LinkProbePacket(trainId: 5, seq: UInt32(i)), at: t)
        }
        XCTAssertTrue(rx.isComplete(5))
        let res = rx.finish(5)
        XCTAssertEqual(res?.received, 4)
        XCTAssertEqual(res?.jitterMs ?? 1, 0, accuracy: 1e-9)   // exactly nominal spacing 25 ms
        XCTAssertNil(rx.finish(5))
    }

    // Provisional decision P1: link-only recommendation at connect time.
    func testLinkAwareProfileOnEighteenMegabitLink() {
        // 5K iMac panel; the 20 and 30 Mbit/s trains arrive at only ~18 Mbit/s (deep router queue, no loss).
        let l = LinkResult(trains: [
            LinkTrainResult(rateBps: 10_000_000, sent: 416, received: 416, jitterMs: 1, deliveryBps: 10_100_000),
            LinkTrainResult(rateBps: 20_000_000, sent: 833, received: 833, jitterMs: 4, deliveryBps: 18_000_000),
            LinkTrainResult(rateBps: 30_000_000, sent: 1250, received: 1200, jitterMs: 9, deliveryBps: 18_000_000),
        ])
        XCTAssertEqual(l.usableThroughputBps, 18_000_000)
        XCTAssertFalse(l.trains[0].saturated)
        XCTAssertFalse(l.trains[1].saturated)    // 18 >= 0.8 x 20
        XCTAssertTrue(l.trains[2].saturated)
        // A Wi-Fi stall stretching the first (slowest) train does not stop the check or lower the result.
        let stalled = LinkTrainResult(rateBps: 10_000_000, sent: 416, received: 416, jitterMs: 1, deliveryBps: 7_100_000)
        XCTAssertFalse(LinkResult.shouldStop(after: stalled, index: 0))
        XCTAssertTrue(LinkResult.shouldStop(after: l.trains[2], index: 2))
        XCTAssertEqual(LinkResult(trains: [stalled]).usableThroughputBps, 10_000_000)
        // RTT inflation: a train arriving > 80 ms later than it was sent is saturated even without loss.
        let queued = LinkTrainResult(rateBps: 40_000_000, sent: 1041, received: 1041, jitterMs: 1,
                                     deliveryBps: 39_000_000, stretchMs: 120)
        XCTAssertTrue(LinkResult.shouldStop(after: queued, index: 2))
        XCTAssertEqual(LinkTrainResult.stretchMs(received: 101, sent: 101, durationMs: 250, firstArrivalMicros: 0,
                                                 lastArrivalMicros: 350_000)!, 350 - 250.0 * 100 / 101, accuracy: 0.01)
        let r = LinkAwareProfile.recommend(panelWidth: 5120, panelHeight: 2880, hevc: true, link: l, interface: .wifi)
        let f = try! XCTUnwrap(r.candidate).format
        XCTAssertEqual(f.codec, .hevc)
        XCTAssertEqual(f.fps, 60)
        XCTAssertLessThanOrEqual(f.height, 1800)
        XCTAssertEqual(f.width, 2560)            // budget 10.8: 3200x1800 needs 13.8 at 0.04 bpp
        XCTAssertEqual(r.bitrate, 10_800_000)    // min(profile, 0.6 x 18)
        XCTAssertEqual(LinkAwareProfile.bitrateCap(throughputBps: 18_000_000), 10_800_000)
        // A fast link keeps the G1 default.
        let fastLink = LinkResult(trains: [LinkTrainResult(rateBps: 80_000_000, sent: 100, received: 100, jitterMs: 1)])
        XCTAssertEqual(LinkAwareProfile.recommend(panelWidth: 5120, panelHeight: 2880, hevc: true, link: fastLink,
                                                  interface: .wifi).candidate?.format.width, 3840)
        // ~25 Mbit/s lands on 3200x1800@60.
        let mid = LinkResult(trains: [LinkTrainResult(rateBps: 30_000_000, sent: 100, received: 100, jitterMs: 1,
                                                      deliveryBps: 25_000_000)])
        XCTAssertEqual(LinkAwareProfile.recommend(panelWidth: 5120, panelHeight: 2880, hevc: true, link: mid,
                                                  interface: .wifi).candidate?.format.width, 3200)
    }

    func testDeliveryRateFromArrivalSpan() {
        XCTAssertNil(LinkTrainResult.deliveryBps(received: 3, firstArrivalMicros: 0, lastArrivalMicros: 1000, packetBytes: 1200))
        // 1001 packets of 1200 B over 0.5 s -> 19.2 Mbit/s.
        XCTAssertEqual(LinkTrainResult.deliveryBps(received: 1001, firstArrivalMicros: 1_000, lastArrivalMicros: 501_000,
                                                   packetBytes: 1200), 19_200_000)
        // Old cached results without the field still decode.
        let json = #"{"rateBps":10,"sent":1,"received":1,"jitterMs":0}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(LinkTrainResult.self, from: json).deliveryBps)
    }
}
