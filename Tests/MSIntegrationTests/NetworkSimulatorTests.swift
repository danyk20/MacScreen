import XCTest
import CoreVideo
import MSCore
import MSCodec
import MSProtocol
import MSProbe
@testable import MSHost

// T3.4: in-process lossy/jittery channel between Fragmenter(+FEC) and Reassembler, with the real
// VideoEncoder/VideoDecoder, TestPattern frames, PacketHistory/NACK and keyframe-request recovery.
// Virtual time: a discrete-event loop, so the run is fast and deterministic given the seed.

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

private final class Locked<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

private struct Scenario {
    var name: String
    var lossRate: Double
    /// Start times (virtual micros after stream start) of 20 ms windows in which the link drops everything.
    var bursts: [UInt64] = []
    var seed: UInt64
    /// Uniform extra one-way delay per packet, 0 ... jitterMicros.
    var jitterMicros: Double = 3000
}

private struct Decoded {
    var captureMicros: UInt64
    var atMicros: UInt64
    var clean: Bool
}

private struct SimResult {
    var framesSent = 0
    var framesDecoded = 0
    var framesLostEvents = 0
    var lostFrameSendTimes: [UInt64] = []
    var decoded: [Decoded] = []
    var keyframesEncoded = 0
    var nacks = 0
    var retransmitted = 0
    var packetsDropped = 0
    var packetsSent = 0
    var fecRatios: [Double] = []
    var bitrates: [Int] = []
    /// Display-measured RFC 3550 jitter sent in each feedback (P1).
    var jitterMs: [Double] = []
}

/// Subsampled luma of a pixel buffer (every 4th pixel both ways).
private func lumaSample(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return [] }
    let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    var out: [UInt8] = []
    out.reserveCapacity((w / 4) * (h / 4))
    for y in Swift.stride(from: 0, to: h, by: 4) {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in Swift.stride(from: 0, to: w, by: 4) { out.append(row[x]) }
    }
    return out
}

private func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 255 }
    var s = 0
    for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }
    return Double(s) / Double(a.count)
}

private final class Simulator {
    // Channel model.
    let oneWayMicros: UInt64 = 1500
    var jitterMicros: Double { scenario.jitterMicros }
    var jitter = InterarrivalJitter()
    let rttMs = 3.0
    let fps = 60
    let frameCount: Int
    let width = 1280, height = 720

    let scenario: Scenario
    var rng: SplitMix64

    // Virtual clock and event queue (sorted by time, then insertion order).
    private var queue: [(t: UInt64, seq: Int, run: () -> Void)] = []
    private var seqCounter = 0
    var now: UInt64 = 0
    let base: UInt64 = 1_000_000

    // Host side.
    var encoder: VideoEncoder!
    let history = PacketHistory()
    var rate: RateController
    var fec: Double
    var frameCounter: UInt32 = 0
    var lastForcedKeyframe: UInt64?
    var keyframePending = false
    let encoded = Locked<[EncodedFrame]>([])
    let encodedSignal = DispatchSemaphore(value: 0)
    var sendTimeOf: [UInt32: UInt64] = [:]
    var sentPackets: UInt32 = 0
    var lostPackets: UInt32 = 0

    // Display side.
    let rx = Reassembler()
    var decoder: VideoDecoder!
    var pending: [UInt64: [UInt8]] = [:]   // captureMicros -> source luma
    let decodedOut = Locked<[(UInt64, [UInt8])]>([])
    var receivedPackets: UInt32 = 0
    var highestDecoded: UInt32 = 0
    var framesDecodedCount: UInt32 = 0
    var framesDropped: UInt32 = 0

    var result = SimResult()
    var frameIdOfCapture: [UInt64: UInt32] = [:]

    init(scenario: Scenario, frameCount: Int) {
        self.scenario = scenario
        self.frameCount = frameCount
        rng = SplitMix64(state: scenario.seed)
        let profile = 6_000_000
        rate = RateController(profileBitrate: profile, linkFecRatio: MSConstants.fecRatioWiFi)
        fec = MSConstants.fecRatioWiFi
    }

    // MARK: event queue

    func schedule(at t: UInt64, _ run: @escaping () -> Void) {
        seqCounter += 1
        let item = (t: t, seq: seqCounter, run: run)
        var lo = 0, hi = queue.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if queue[mid].t <= t { lo = mid + 1 } else { hi = mid }
        }
        queue.insert(item, at: lo)
    }

    func inBurst(_ t: UInt64) -> Bool {
        let rel = t &- base
        guard t >= base else { return false }
        return scenario.bursts.contains { rel >= $0 && rel < $0 + 20_000 }
    }

    /// True if the packet sent at `t` is dropped (random loss or burst window).
    func drops(at t: UInt64) -> Bool {
        let r = rng.unit()
        return inBurst(t) || r < scenario.lossRate
    }

    func arrival(sentAt t: UInt64) -> UInt64 {
        t + oneWayMicros + UInt64(rng.unit() * jitterMicros)
    }

    // MARK: run

    func run() throws -> SimResult {
        let fmt = VideoFormat(codec: .hevc, width: width, height: height, fps: fps, bitDepth: 8)
        encoder = try VideoEncoder(format: fmt, bitrate: rate.initialBitrate) { [encoded, encodedSignal] f in
            encoded.mutate { $0.append(f) }
            encodedSignal.signal()
        }
        decoder = VideoDecoder(codec: .hevc) { [decodedOut] pb, micros, _ in
            let luma = lumaSample(pb)
            decodedOut.mutate { $0.append((micros, luma)) }
        }
        defer { encoder.invalidate(); decoder.invalidate() }

        let pattern = try TestPattern(width: width, height: height)
        let interval = UInt64(1_000_000 / fps)
        for i in 0..<frameCount {
            let t = base + UInt64(i) * interval
            schedule(at: t) { [unowned self] in self.capture(pattern: pattern, index: i) }
        }
        let end = base + UInt64(frameCount) * interval + 1_500_000
        var tickT = base
        while tickT <= end {
            let t = tickT
            schedule(at: t) { [unowned self] in self.process(self.rx.tick(nowMicros: t, rttMs: self.rttMs)) }
            tickT += 5000
        }
        var sec = base + 1_000_000
        while sec <= base + UInt64(frameCount) * interval {
            let t = sec
            schedule(at: t) { [unowned self] in self.sendFeedback() }
            sec += 1_000_000
        }

        while !queue.isEmpty {
            let ev = queue.removeFirst()
            now = ev.t
            ev.run()
            if let e = failure { throw e }
        }
        decoder.flush()
        collectDecoded()
        result.framesSent = Int(frameCounter)
        return result
    }

    var failure: Error?

    // MARK: Host

    func capture(pattern: TestPattern, index: Int) {
        do {
            let pb = try pattern.frame(index)
            let luma = lumaSample(pb)
            if keyframePending {
                keyframePending = false
                encoder.requestKeyframe()
            }
            let captureMicros = now
            pending[captureMicros] = luma
            encoder.encode(pb, captureTimeMicros: captureMicros)
            guard encodedSignal.wait(timeout: .now() + 5) == .success else {
                throw NSError(domain: "sim", code: 1, userInfo: [NSLocalizedDescriptionKey: "encoder produced no frame"])
            }
            guard let f = encoded.get().last else { return }
            sendFrame(f)
        } catch {
            failure = error
        }
    }

    func sendFrame(_ f: EncodedFrame) {
        frameCounter &+= 1
        let id = frameCounter
        if f.isKeyframe { result.keyframesEncoded += 1 }
        sendTimeOf[id] = now
        do {
            let payload = FramePayload.encode(f)
            let frags = try Fragmenter.fragment(payload: payload, frameId: id, isKeyframe: f.isKeyframe,
                                                captureTimeMicros: f.captureTimeMicros,
                                                fecRatio: RateController.frameFecRatio(fec, isKeyframe: f.isKeyframe))
            history.record(frameId: id, fragments: frags, nowMicros: now)
            // Pace evenly over 4 ms.
            for (n, o) in frags.enumerated() {
                let sentAt = now + UInt64(n) * 4000 / UInt64(frags.count)
                transmit(type: o.type, data: o.fragment.encode(), sentAt: sentAt, countForFeedback: true)
            }
        } catch {
            failure = error
        }
    }

    func transmit(type: PacketType, data: Data, sentAt: UInt64, countForFeedback: Bool) {
        result.packetsSent += 1
        sentPackets &+= 1
        if drops(at: sentAt) {
            result.packetsDropped += 1
            lostPackets &+= 1
            return
        }
        let at = arrival(sentAt: sentAt)
        schedule(at: at) { [unowned self] in
            self.receivedPackets &+= 1
            guard let frag = try? VideoFragment.decode(data) else { return }
            self.jitter.add(key: frag.frameId, sentMicros: frag.captureTimeMicros, arrivedMicros: self.now)
            self.process(self.rx.ingest(type: type, fragment: frag, nowMicros: self.now, rttMs: self.rttMs))
        }
    }

    func hostReceivesKeyframeRequest() {
        if let last = lastForcedKeyframe, now &- last < UInt64(MSConstants.keyframeMinIntervalMs) * 1000 { return }
        lastForcedKeyframe = now
        keyframePending = true
    }

    func hostReceivesNack(_ n: NackPacket) {
        for (t, d) in history.retransmissions(for: n, nowMicros: now) {
            result.retransmitted += 1
            transmit(type: t, data: d, sentAt: now, countForFeedback: false)
        }
    }

    // MARK: Display

    func process(_ events: [Reassembler.Event]) {
        for e in events {
            switch e {
            case .frame(let id, let payload, let isKey, let capture):
                do {
                    let f = try FramePayload.decode(payload, isKeyframe: isKey, captureTimeMicros: capture)
                    try decoder.decode(f)
                    decoder.flush()
                    frameIdOfCapture[capture] = id
                    highestDecoded = id
                    framesDecodedCount &+= 1
                    collectDecoded()
                } catch {
                    framesDropped &+= 1
                    process(rx.forceKeyframeResync(nowMicros: now))
                }
            case .requestKeyframe:
                // Feedback packet with requestKeyframe, sent immediately; may itself be lost.
                let t = now
                if !drops(at: t) {
                    schedule(at: arrival(sentAt: t)) { [unowned self] in self.hostReceivesKeyframeRequest() }
                }
            case .frameLost(let id):
                result.framesLostEvents += 1
                framesDropped &+= 1
                if let t = sendTimeOf[id] { result.lostFrameSendTimes.append(t) }
            case .nack(let n):
                result.nacks += 1
                guard let wire = try? NackPacket.decode(n.encode()) else { failure = NSError(domain: "nack", code: 1); continue }
                let t = now
                if !drops(at: t) {
                    schedule(at: arrival(sentAt: t)) { [unowned self] in self.hostReceivesNack(wire) }
                }
            }
        }
    }

    /// Moves decoder output into the result, marking each frame clean or not against its source.
    func collectDecoded() {
        let outs = decodedOut.get()
        decodedOut.mutate { $0.removeAll() }
        for (micros, luma) in outs {
            guard let src = pending[micros] else { continue }
            let diff = meanAbsDiff(luma, src)
            result.decoded.append(Decoded(captureMicros: micros, atMicros: now, clean: diff < 4.0))
            result.framesDecoded += 1
        }
    }

    /// Once-per-second feedback to the Host's RateController (adaptive FEC), over the lossy return path.
    func sendFeedback() {
        let fb = FeedbackPacket(highestDecodedFrame: highestDecoded, framesDecoded: framesDecodedCount,
                                framesDropped: framesDropped, fragsReceived: receivedPackets,
                                fragsLost: lostPackets, fragsRecovered: UInt32(truncatingIfNeeded: rx.counters.fragsRecovered),
                                avgDecodeMsX10: 10, jitterMsX10: UInt16(min(6553, jitter.jitterMs * 10)),
                                requestKeyframe: false)
        let t = now
        result.jitterMs.append(jitter.jitterMs)
        if drops(at: t) { return }
        schedule(at: arrival(sentAt: t)) { [unowned self] in
            if let out = self.rate.ingest(fb, nowMicros: self.now) {
                self.fec = out.fecRatio
                self.encoder.setBitrate(out.bitrate)
                self.result.bitrates.append(out.bitrate)
                self.result.fecRatios.append(out.fecRatio)
            }
        }
    }
}

final class NetworkSimulatorTests: XCTestCase {
    private let frameCount = 300   // 5 s at 60 fps

    private func runScenario(_ s: Scenario) throws -> SimResult {
        let sim = Simulator(scenario: s, frameCount: frameCount)
        return try sim.run()
    }

    /// Every decoded frame after `fromMicros` (virtual) belongs to the picture chain; return the time of the first
    /// clean decoded frame sent after `fromMicros`, relative to it.
    private func recoveryMicros(_ r: SimResult, after lossAt: UInt64) -> UInt64? {
        // A frame sent after the loss is clean only if the chain was rebuilt from a keyframe.
        // `clean` compares pixels with the source, so a clean frame after a loss proves recovery
        // (or that the lost frame was not needed, which is also a clean picture).
        guard let d = r.decoded.first(where: { $0.captureMicros > lossAt && $0.clean }) else { return nil }
        return d.atMicros - lossAt
    }

    private func check(_ s: Scenario, requireZeroLoss: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let r = try runScenario(s)
        let summary = "\(s.name): sent \(r.framesSent) decoded \(r.framesDecoded) lostEvents \(r.framesLostEvents) " +
            "keyframes \(r.keyframesEncoded) nacks \(r.nacks) retx \(r.retransmitted) " +
            "dropped \(r.packetsDropped)/\(r.packetsSent) fec \(r.fecRatios.last ?? -1)"
        print("NETSIM \(summary)")

        XCTAssertEqual(r.framesSent, frameCount, summary, file: file, line: line)
        if requireZeroLoss {
            XCTAssertEqual(r.framesLostEvents, 0, "lost frames; \(summary)", file: file, line: line)
            XCTAssertEqual(r.framesDecoded, frameCount, "not every frame decoded; \(summary)", file: file, line: line)
            XCTAssertEqual(r.keyframesEncoded, 1, "unneeded keyframes; \(summary)", file: file, line: line)
        }
        // Every loss: a clean picture within 500 ms.
        for t in r.lostFrameSendTimes {
            guard let rec = recoveryMicros(r, after: t) else {
                XCTFail("no clean picture after loss at \(t); \(summary)", file: file, line: line); continue
            }
            XCTAssertLessThanOrEqual(rec, 500_000, "recovery \(rec) us after loss at \(t); \(summary)", file: file, line: line)
        }
        // The picture ends clean: the last decoded frames match their source.
        let tail = r.decoded.suffix(10)
        XCTAssertEqual(tail.count, 10, summary, file: file, line: line)
        XCTAssertTrue(tail.allSatisfy { $0.clean }, "picture not clean at the end; \(summary)", file: file, line: line)
    }

    func testNoLoss() throws {
        try check(Scenario(name: "0%", lossRate: 0, seed: 1), requireZeroLoss: true)
    }

    func testOnePercentLoss() throws {
        try check(Scenario(name: "1%", lossRate: 0.01, seed: 42), requireZeroLoss: true)
    }

    func testFivePercentLoss() throws {
        try check(Scenario(name: "5%", lossRate: 0.05, seed: 7), requireZeroLoss: false)
    }

    func testTwentyMillisecondBursts() throws {
        try check(Scenario(name: "bursts", lossRate: 0, bursts: [1_000_000, 2_300_000, 3_600_000], seed: 3),
                  requireZeroLoss: false)
    }

    /// P1: the Display measures RFC 3550 jitter itself. Uniform 0-3 ms delay gives ~1 ms (no back-off);
    /// Wi-Fi-like 0-30 ms gives ~10 ms, still below the back-off threshold, and the stream stays clean.
    func testMeasuredJitter() throws {
        let calm = try runScenario(Scenario(name: "calm", lossRate: 0, seed: 1))
        let calmJ = try XCTUnwrap(calm.jitterMs.last)
        XCTAssertGreaterThan(calmJ, 0.2)
        XCTAssertLessThan(calmJ, 3)
        let s = Scenario(name: "wifi-jitter", lossRate: 0, seed: 5, jitterMicros: 30_000)
        try check(s, requireZeroLoss: false)
        let r = try runScenario(s)
        let j = try XCTUnwrap(r.jitterMs.last)
        print("NETSIM jitter calm \(calmJ) ms, wifi \(j) ms, bitrates \(r.bitrates)")
        XCTAssertGreaterThan(j, 4)
        XCTAssertLessThan(j, RateController.jitterBadMs)
        XCTAssertFalse(r.bitrates.contains { $0 < 6_000_000 * 6 / 10 }, "jitter alone must not back off")
    }
}
