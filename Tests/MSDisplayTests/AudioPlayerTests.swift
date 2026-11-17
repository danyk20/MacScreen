import XCTest
import MSCore
import MSProtocol
@testable import MSDisplay

final class FakeAudioOutput: AudioOutput {
    var render: AudioRenderCallback?
    var started = 0, stopped = 0
    func start(render: @escaping AudioRenderCallback) throws { self.render = render; started += 1 }
    func stop() { render = nil; stopped += 1 }
    /// Pulls `frames` frames as an array of interleaved s16 samples.
    func pull(_ frames: Int) -> [Int16] {
        var out = [Int16](repeating: 7, count: frames * 2)
        out.withUnsafeMutableBufferPointer { render!($0.baseAddress!, frames) }
        return out
    }
}

private func packet(_ seq: UInt32, value: Int16 = 100, host: UInt64 = 0) -> AudioPacket {
    AudioPacket(seq: seq, hostTimeMicros: host,
                pcm: Data(count: 0) + [Int16](repeating: value, count: 480).withUnsafeBytes { Data($0) })
}

/// Packet whose frames count up globally (frame n has value n % 30000 on both channels).
private func rampPacket(_ seq: UInt32) -> AudioPacket {
    var s = [Int16](); s.reserveCapacity(480)
    for i in 0..<240 { let v = Int16((Int(seq) * 240 + i) % 30000); s.append(v); s.append(v) }
    return AudioPacket(seq: seq, hostTimeMicros: 0, pcm: s.withUnsafeBytes { Data($0) })
}

final class AudioPlayerTests: XCTestCase {
    // MARK: DriftController

    func testDriftNoCorrectionInDeadband() {
        var d = DriftController(targetFrames: 1920)
        for _ in 0..<50 {
            let o = d.update(fillFrames: 1920 + 50, renderedFrames: 480)
            XCTAssertEqual(o.ratio, 1)
            XCTAssertEqual(o.skipFrames, 0)
        }
    }

    func testDriftDirectionAndBounds() {
        var d = DriftController(targetFrames: 1920)
        var o = DriftController.Output(ratio: 1, skipFrames: 0)
        for _ in 0..<50 { o = d.update(fillFrames: 1920 + 500, renderedFrames: 480) }
        XCTAssertGreaterThan(o.ratio, 1)
        XCTAssertLessThanOrEqual(o.ratio, 1.005 + 1e-9)
        var d2 = DriftController(targetFrames: 1920)
        for _ in 0..<50 { o = d2.update(fillFrames: 1920 - 500, renderedFrames: 480) }
        XCTAssertLessThan(o.ratio, 1)
        XCTAssertGreaterThanOrEqual(o.ratio, 0.995 - 1e-9)
    }

    func testDriftHardOverflowSkips() {
        var d = DriftController(targetFrames: 1920)
        let o = d.update(fillFrames: 1920 + 48000, renderedFrames: 480)
        XCTAssertGreaterThan(o.skipFrames, 40000)
        XCTAssertEqual(o.ratio, 1)
    }

    /// Simulated clocks: producer rate (1 + ppm) vs consumer 48000 Hz; fill must stay bounded.
    private func simulate(ppm: Double, seconds: Int) -> (minFill: Double, maxFill: Double, final: Double) {
        let target = 1920
        var d = DriftController(targetFrames: target)
        var fill = Double(target)
        var lo = fill, hi = fill
        let chunk = 480
        for _ in 0..<(seconds * 100) {
            let o = d.update(fillFrames: Int(fill), renderedFrames: chunk)
            fill += Double(chunk) * (1 + ppm * 1e-6)         // produced
            fill -= Double(chunk) * o.ratio                  // consumed
            fill -= Double(o.skipFrames)
            lo = min(lo, fill); hi = max(hi, fill)
        }
        return (lo, hi, fill)
    }

    func testDriftBoundedForPlusMinus100ppm() {
        for ppm in [100.0, -100.0, 300.0, -300.0] {
            let r = simulate(ppm: ppm, seconds: 1800)
            XCTAssertGreaterThan(r.minFill, 1920 - 300, "ppm \(ppm)")
            XCTAssertLessThan(r.maxFill, 1920 + 300, "ppm \(ppm)")
        }
    }

    // MARK: Sequence tracker

    func testSequenceHandling() {
        var t = AudioSequenceTracker()
        XCTAssertEqual(t.classify(10), .accept(missingBefore: 0))
        XCTAssertEqual(t.classify(11), .accept(missingBefore: 0))
        XCTAssertEqual(t.classify(14), .accept(missingBefore: 2))
        XCTAssertEqual(t.classify(12), .drop)            // late
        XCTAssertEqual(t.classify(14), .drop)            // duplicate
        XCTAssertEqual(t.classify(15), .accept(missingBefore: 0))
        XCTAssertEqual(t.classify(15 + 50), .accept(missingBefore: AudioSequenceTracker.maxFill))
        XCTAssertEqual(t.classify(1_000_000), .accept(missingBefore: 0))   // resync
        var w = AudioSequenceTracker()
        _ = w.classify(UInt32.max)
        XCTAssertEqual(w.classify(0), .accept(missingBefore: 0))           // wrap
    }

    // MARK: Player

    func testPrimingSilenceThenContinuousPlayback() {
        let out = FakeAudioOutput()
        let p = AudioPlayer(output: out, targetMs: 40)
        try! p.start()
        for s in 0..<3 { p.enqueue(rampPacket(UInt32(s))) }      // 15 ms < 40 ms target
        XCTAssertTrue(out.pull(240).allSatisfy { $0 == 0 })
        for s in 3..<8 { p.enqueue(rampPacket(UInt32(s))) }
        let a = out.pull(480)
        XCTAssertEqual(a[0], 0)
        XCTAssertEqual(Array(a[0..<8]), [0, 0, 1, 1, 2, 2, 3, 3])
        // Continuous ramp (ratio 1 inside the deadband).
        let b = out.pull(480)
        XCTAssertEqual(b[0], 480)
        XCTAssertEqual(p.underruns, 0)
    }

    func testUnderrunSilenceThenRePrime() {
        let out = FakeAudioOutput()
        let p = AudioPlayer(output: out, targetMs: 40)
        try! p.start()
        for s in 0..<8 { p.enqueue(rampPacket(UInt32(s))) }      // 40 ms
        _ = out.pull(1200)
        let x = out.pull(1200)                                   // only 720 frames left
        XCTAssertEqual(x[0], 1200)
        let y = out.pull(480)                                    // empty: silence
        XCTAssertTrue(y.allSatisfy { $0 == 0 })
        XCTAssertGreaterThanOrEqual(p.underruns, 1)
        // Refill below target: still silent; above target: plays again.
        for s in 8..<11 { p.enqueue(rampPacket(UInt32(s))) }
        XCTAssertTrue(out.pull(240).allSatisfy { $0 == 0 })
        for s in 11..<16 { p.enqueue(rampPacket(UInt32(s))) }
        XCTAssertTrue(out.pull(240).contains { $0 != 0 })
    }

    func testLateAndMissingPackets() {
        let out = FakeAudioOutput()
        let p = AudioPlayer(output: out, targetMs: 40)
        try! p.start()
        for s in [0, 1, 2, 3, 4, 5, 6, 7, 9] as [UInt32] { p.enqueue(packet(s)) }   // 8 missing
        p.enqueue(packet(8))                                                         // late: dropped
        let st = p.packetStats
        XCTAssertEqual(st.silencePackets, 1)
        XCTAssertEqual(st.packetsDropped, 1)
        XCTAssertEqual(st.packetsAccepted, 9)
        let s = out.pull(240 * 10)
        // Packet 8 region is silence.
        XCTAssertTrue(s[(240 * 8 + 30) * 2 ..< (240 * 9 - 30) * 2].allSatisfy { $0 == 0 })
        XCTAssertEqual(s[0], 100)
    }

    func testIgnoredWhenNotStartedAndAfterStop() {
        let out = FakeAudioOutput()
        let p = AudioPlayer(output: out)
        p.enqueue(packet(0))
        XCTAssertEqual(p.packetStats.packetsAccepted, 0)
        try! p.start()
        p.enqueue(packet(0))
        XCTAssertEqual(p.packetStats.packetsAccepted, 1)
        p.stop()
        XCTAssertEqual(out.stopped, 1)
        p.enqueue(packet(1))
        XCTAssertEqual(p.packetStats.packetsAccepted, 1)
    }

    func testAudioDelayEstimate() {
        let out = FakeAudioOutput()
        let p = AudioPlayer(output: out, clock: { 1_000_000 })
        try! p.start()
        p.setClockOffset(500_000)                    // host clock = display clock + 0.5 s
        p.enqueue(packet(0, host: 1_500_000 - 20_000))   // captured 20 ms ago
        let d = try! XCTUnwrap(p.audioDelayMs)
        XCTAssertEqual(d, 25, accuracy: 1)           // 20 ms age + 5 ms buffered
    }

    func testPlaybackStaysContinuousWithSkewedClock() {
        // Producer 2000 ppm fast for 20 s of simulated time; output must never underrun and stay bounded.
        let out = FakeAudioOutput()
        let p = AudioPlayer(output: out, targetMs: 40)
        try! p.start()
        var seq: UInt32 = 0
        var produced = 0.0, consumed = 0.0
        for _ in 0..<(100 * 20) {                    // 10 ms steps
            consumed += 480
            produced += 480 * 1.002
            while produced >= 240 { p.enqueue(rampPacket(seq)); seq += 1; produced -= 240 }
            _ = out.pull(480)
        }
        XCTAssertEqual(p.underruns, 0)
        XCTAssertLessThan(p.fillMs, 80)
        XCTAssertGreaterThan(p.fillMs, 10)
    }

    func testDefaultTargetIsPlanConstant() {
        // Provisional decision P2: one value (40 ms) in PLAN 6.9, MSConstants and the player default.
        XCTAssertEqual(MSConstants.audioTargetBufferMs, 40)
        XCTAssertEqual(AudioPlayer(output: FakeAudioOutput()).targetBufferMs, 40, accuracy: 0.01)
    }
}
