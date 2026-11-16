import XCTest
import MSCore
@testable import MSProtocol

private let ms: UInt64 = 1000

private func frameEvents(_ events: [Reassembler.Event]) -> [(id: UInt32, payload: Data, key: Bool)] {
    events.compactMap {
        if case let .frame(id, p, k, _) = $0 { return (id, p, k) }
        return nil
    }
}

final class ReassemblerTests: XCTestCase {
    private var rng = TestRNG(seed: 42)

    private func make(_ id: UInt32, size: Int, key: Bool, fec: Double = 0) throws -> (Data, [OutgoingFragment]) {
        let p = rng.payload(size)
        let f = try Fragmenter.fragment(payload: p, frameId: id, isKeyframe: key,
                                        captureTimeMicros: UInt64(id) * 16_000, fecRatio: fec)
        return (p, f)
    }

    @discardableResult
    private func feed(_ r: Reassembler, _ frags: [OutgoingFragment], at t: UInt64, rtt: Double? = nil)
        -> [Reassembler.Event] {
        var ev: [Reassembler.Event] = []
        for f in frags {
            ev += r.ingest(type: f.type, fragment: f.fragment, nowMicros: t, rttMs: rtt)
            XCTAssertLessThanOrEqual(r.framesInAssembly, MSConstants.reassemblyMaxFrames)
        }
        return ev
    }

    /// Delivers a keyframe 0 so that the reassembler is in normal state.
    private func primed() throws -> Reassembler {
        let r = Reassembler()
        let (_, f) = try make(0, size: 500, key: true)
        let ev = feed(r, f, at: 0)
        XCTAssertEqual(frameEvents(ev).count, 1)
        XCTAssertFalse(r.awaitingKeyframe)
        return r
    }

    // MARK: Delivery

    func testInOrderLossless() throws {
        for fec in [0.0, 0.1] {
            let r = Reassembler()
            var originals: [Data] = []
            var got: [(id: UInt32, payload: Data, key: Bool)] = []
            for i in 0..<20 {
                let (p, f) = try make(UInt32(i), size: 1 + rng.below(6000), key: i == 0, fec: fec)
                originals.append(p)
                got += frameEvents(feed(r, f, at: UInt64(i) * 16 * ms))
            }
            XCTAssertEqual(got.count, 20)
            for (i, g) in got.enumerated() {
                XCTAssertEqual(g.id, UInt32(i))
                XCTAssertEqual(g.payload, originals[i])
                XCTAssertEqual(g.key, i == 0)
            }
            XCTAssertEqual(r.counters.framesDelivered, 20)
            XCTAssertEqual(r.counters.framesLost, 0)
            XCTAssertEqual(r.framesInAssembly, 0)
            if fec == 0 { XCTAssertEqual(r.counters.fragsLostEstimate, 0) }
        }
    }

    func testSizesRoundTrip() throws {
        for n in [1, 1199, 1200, 1201, 76_800, 76_801, 1_048_576] {
            for fec in [0.0, 0.1] {
                let r = Reassembler()
                let (p, f) = try make(5, size: n, key: true, fec: fec)
                let got = frameEvents(feed(r, f, at: 0))
                XCTAssertEqual(got.count, 1, "size \(n)")
                XCTAssertEqual(got.first?.payload, p, "size \(n)")
            }
        }
    }

    func testRandomOrderAndDuplicates() throws {
        let r = Reassembler()
        let (p, f) = try make(0, size: 76_801, key: true, fec: 0.1)
        var doubled = f + f
        rng.shuffle(&doubled)
        let got = frameEvents(feed(r, doubled, at: 0))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.payload, p)
        XCTAssertGreaterThanOrEqual(r.counters.fragsDuplicate, UInt64(f.count))
        XCTAssertEqual(r.counters.framesDelivered, 1)
        XCTAssertEqual(r.counters.fragsInvalid, 0)
    }

    func testDuplicateWithinIncompleteFrameCounted() throws {
        let r = Reassembler()
        let (_, f) = try make(0, size: 3000, key: true)
        feed(r, [f[0], f[0]], at: 0)
        XCTAssertEqual(r.counters.fragsDuplicate, 1)
        XCTAssertEqual(r.counters.fragsReceived, 1)
    }

    func testLossWithinFecCapacity() throws {
        for n in [3000, 76_801, 200_000] {
            let r = Reassembler()
            let (p, f) = try make(0, size: n, key: true, fec: 0.1)
            // Drop m fragments of every block, about half of them data.
            var kept: [OutgoingFragment] = []
            var blocks: [UInt8: [OutgoingFragment]] = [:]
            for o in f { blocks[o.fragment.blockIndex, default: []].append(o) }
            for b in blocks.keys.sorted() {
                let all = blocks[b] ?? []
                let m = Int(all[0].fragment.m)
                let dropData = m - m / 2
                let dropParity = m / 2
                kept += all.filter { ($0.type == .videoData && Int($0.fragment.fragIndex) >= dropData) ||
                                     ($0.type == .videoParity && Int($0.fragment.fragIndex) >= dropParity) }
            }
            XCTAssertLessThan(kept.count, f.count)
            rng.shuffle(&kept)
            let got = frameEvents(feed(r, kept, at: 0))
            XCTAssertEqual(got.count, 1, "size \(n)")
            XCTAssertEqual(got.first?.payload, p, "size \(n)")
            XCTAssertGreaterThan(r.counters.fragsRecovered, 0)
        }
    }

    // MARK: Startup

    func testStartupWaitsForKeyframe() throws {
        let r = Reassembler()
        XCTAssertTrue(r.awaitingKeyframe)
        XCTAssertEqual(r.tick(nowMicros: 0, rttMs: nil), [])
        let (_, n0) = try make(0, size: 2000, key: false)
        XCTAssertEqual(frameEvents(feed(r, n0, at: 10 * ms)).count, 0)
        XCTAssertEqual(r.ingest(type: n0[0].type, fragment: n0[0].fragment, nowMicros: 10 * ms, rttMs: nil), [])
        XCTAssertEqual(r.tick(nowMicros: 11 * ms, rttMs: nil), [.requestKeyframe])
        XCTAssertEqual(r.tick(nowMicros: 16 * ms, rttMs: nil), [])
        XCTAssertEqual(r.tick(nowMicros: 100 * ms, rttMs: nil), [])
        XCTAssertEqual(r.tick(nowMicros: 111 * ms, rttMs: nil), [.requestKeyframe])
        XCTAssertEqual(r.tick(nowMicros: 150 * ms, rttMs: nil), [])
        XCTAssertEqual(r.tick(nowMicros: 211 * ms, rttMs: nil), [.requestKeyframe])
        XCTAssertEqual(r.counters.framesDelivered, 0)
        XCTAssertEqual(r.counters.framesLost, 0)

        let (kp, kf) = try make(5, size: 2500, key: true)
        let got = frameEvents(feed(r, kf, at: 220 * ms))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.id, 5)
        XCTAssertEqual(got.first?.payload, kp)
        XCTAssertFalse(r.awaitingKeyframe)
        XCTAssertEqual(r.tick(nowMicros: 400 * ms, rttMs: nil), [])
        let (p6, f6) = try make(6, size: 100, key: false)
        XCTAssertEqual(frameEvents(feed(r, f6, at: 410 * ms)).first?.payload, p6)
    }

    // MARK: Loss

    func testLossBeyondFecWithoutRtt() throws {
        let r = try primed()
        let (_, f1) = try make(1, size: 3000, key: false)
        feed(r, Array(f1.dropFirst()), at: 16 * ms)               // fragment 0 missing, no FEC
        let (_, f2) = try make(2, size: 3000, key: false)
        let ev = feed(r, f2, at: 32 * ms)
        XCTAssertEqual(ev, [.frameLost(frameId: 1), .requestKeyframe])
        XCTAssertTrue(r.awaitingKeyframe)
        XCTAssertEqual(r.counters.framesLost, 1)
        XCTAssertEqual(r.framesInAssembly, 0)

        let (_, f3) = try make(3, size: 3000, key: false)
        XCTAssertEqual(frameEvents(feed(r, f3, at: 48 * ms)).count, 0)
        XCTAssertEqual(r.tick(nowMicros: 100 * ms, rttMs: nil), [])
        XCTAssertEqual(r.tick(nowMicros: 132 * ms, rttMs: nil), [.requestKeyframe])

        let (kp, k4) = try make(4, size: 4000, key: true)
        let got = frameEvents(feed(r, k4, at: 140 * ms))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.payload, kp)
        XCTAssertFalse(r.awaitingKeyframe)
        let (p5, f5) = try make(5, size: 1500, key: false)
        XCTAssertEqual(frameEvents(feed(r, f5, at: 150 * ms)).first?.payload, p5)
        XCTAssertEqual(r.tick(nowMicros: 400 * ms, rttMs: nil), [])
    }

    func testLossEstimateForLostFrame() throws {
        let r = try primed()
        let (_, f1) = try make(1, size: 3000, key: false)   // 3 fragments
        feed(r, [f1[1]], at: 16 * ms)
        let (_, f2) = try make(2, size: 100, key: false)
        feed(r, f2, at: 32 * ms)
        // Only the block header of the one received fragment is known: expected 3, received 1.
        XCTAssertEqual(r.counters.fragsLostEstimate, 2)
    }

    func testForceKeyframeResync() throws {
        let r = try primed()
        for id in UInt32(1)...2 { feed(r, try make(id, size: 500, key: false).1, at: UInt64(id) * 16 * ms) }
        XCTAssertEqual(r.forceKeyframeResync(nowMicros: 50 * ms), [.requestKeyframe])
        XCTAssertTrue(r.awaitingKeyframe)
        // Repeated call within the interval is silent.
        XCTAssertEqual(r.forceKeyframeResync(nowMicros: 60 * ms), [])
        // Non-keyframes are not delivered.
        let ev = feed(r, try make(3, size: 500, key: false).1, at: 70 * ms)
        XCTAssertTrue(frameEvents(ev).isEmpty)
        XCTAssertEqual(r.tick(nowMicros: 100 * ms, rttMs: nil), [])
        XCTAssertEqual(r.tick(nowMicros: 150 * ms, rttMs: nil), [.requestKeyframe])
        XCTAssertEqual(r.tick(nowMicros: 200 * ms, rttMs: nil), [])
        XCTAssertEqual(r.tick(nowMicros: 250 * ms, rttMs: nil), [.requestKeyframe])
        // Keyframe resumes delivery.
        let (pk, fk) = try make(10, size: 800, key: true)
        let got = frameEvents(feed(r, fk, at: 260 * ms))
        XCTAssertEqual(got.map { $0.id }, [10])
        XCTAssertEqual(got.first?.payload, pk)
        XCTAssertFalse(r.awaitingKeyframe)
        let (p11, f11) = try make(11, size: 500, key: false)
        XCTAssertEqual(frameEvents(feed(r, f11, at: 270 * ms)).map { $0.payload }, [p11])
    }

    // MARK: NACK

    func testNackThenRetransmission() throws {
        let r = try primed()
        let (p1, f1) = try make(1, size: 4000, key: false)         // 4 data fragments
        feed(r, f1.filter { $0.fragment.fragIndex == 0 || $0.fragment.fragIndex == 3 }, at: 16 * ms, rtt: 2)
        let (p2, f2) = try make(2, size: 1000, key: false)
        let ev = feed(r, f2, at: 20 * ms, rtt: 2)
        XCTAssertEqual(ev, [.nack(NackPacket(frameId: 1, blockIndex: 0, fragIndices: [1, 2]))])
        XCTAssertEqual(r.counters.framesLost, 0)

        // A further complete frame must not produce a second NACK.
        let (p3, f3) = try make(3, size: 1000, key: false)
        XCTAssertEqual(feed(r, f3, at: 22 * ms, rtt: 2), [])
        XCTAssertEqual(r.tick(nowMicros: 24 * ms, rttMs: 2), [])

        let got = frameEvents(feed(r, f1.filter { $0.fragment.fragIndex == 1 || $0.fragment.fragIndex == 2 },
                                   at: 25 * ms, rtt: 2))
        XCTAssertEqual(got.map { $0.id }, [1, 2, 3])
        XCTAssertEqual(got.map { $0.payload }, [p1, p2, p3])
        XCTAssertFalse(r.awaitingKeyframe)
    }

    func testNackTimeoutLosesFrameOnce() throws {
        let r = try primed()
        let (_, f1) = try make(1, size: 4000, key: false)
        feed(r, Array(f1.dropFirst(2)), at: 16 * ms, rtt: 2)
        let (_, f2) = try make(2, size: 1000, key: false)
        let ev = feed(r, f2, at: 20 * ms, rtt: 2)
        XCTAssertEqual(ev, [.nack(NackPacket(frameId: 1, blockIndex: 0, fragIndices: [0, 1]))])
        XCTAssertEqual(r.tick(nowMicros: 25 * ms, rttMs: 2), [])     // deadline is 20 + 6 = 26 ms
        XCTAssertEqual(r.tick(nowMicros: 26 * ms, rttMs: 2), [.frameLost(frameId: 1), .requestKeyframe])
        XCTAssertTrue(r.awaitingKeyframe)
        XCTAssertEqual(r.counters.framesLost, 1)
        XCTAssertEqual(r.tick(nowMicros: 40 * ms, rttMs: 2), [])
    }

    func testNackListsIncompleteBlocksOnly() throws {
        let r = try primed()
        let (_, f1) = try make(1, size: 76_801, key: false)        // blocks of 64 and 1
        // Block 0 gets data 5 and 6 missing; block 1 has nothing.
        feed(r, f1.filter { $0.fragment.blockIndex == 0 && $0.fragment.fragIndex != 5 && $0.fragment.fragIndex != 6 },
             at: 16 * ms, rtt: 2)
        let (_, f2) = try make(2, size: 100, key: false)
        let ev = feed(r, f2, at: 20 * ms, rtt: 2)
        XCTAssertEqual(ev, [.nack(NackPacket(frameId: 1, blockIndex: 0, fragIndices: [5, 6])),
                            .nack(NackPacket(frameId: 1, blockIndex: 1, fragIndices: []))])
    }

    func testEntirelyMissingFrameNack() throws {
        let r = try primed()
        let (p1, f1) = try make(1, size: 1500, key: false)
        let (p2, f2) = try make(2, size: 1500, key: false)
        let ev = feed(r, f2, at: 20 * ms, rtt: 2)
        XCTAssertEqual(ev, [.nack(NackPacket(frameId: 1, blockIndex: 0, fragIndices: []))])
        let got = frameEvents(feed(r, f1, at: 23 * ms, rtt: 2))
        XCTAssertEqual(got.map { $0.payload }, [p1, p2])

        // Without a retransmission the missing frame is lost at the deadline.
        let r2 = try primed()
        XCTAssertEqual(feed(r2, f2, at: 20 * ms, rtt: 2).count, 1)
        XCTAssertEqual(r2.tick(nowMicros: 26 * ms, rttMs: 2), [.frameLost(frameId: 1), .requestKeyframe])
    }

    func testHighRttSkipsNack() throws {
        let r = try primed()
        let (_, f2) = try make(2, size: 1500, key: false)
        XCTAssertEqual(feed(r, f2, at: 20 * ms, rtt: 12), [.frameLost(frameId: 1), .requestKeyframe])
    }

    // MARK: Stall

    func testStallNack() throws {
        let r = try primed()
        let (p1, f1) = try make(1, size: 3000, key: false)
        feed(r, Array(f1.dropLast()), at: 100 * ms, rtt: 2)
        XCTAssertEqual(r.tick(nowMicros: 130 * ms, rttMs: 2), [])    // not yet more than 30 ms
        XCTAssertEqual(r.tick(nowMicros: 131 * ms, rttMs: 2),
                       [.nack(NackPacket(frameId: 1, blockIndex: 0, fragIndices: [2]))])
        XCTAssertEqual(r.tick(nowMicros: 135 * ms, rttMs: 2), [])
        let got = frameEvents(feed(r, [f1[2]], at: 136 * ms, rtt: 2))
        XCTAssertEqual(got.first?.payload, p1)
    }

    func testStallLossWithoutRtt() throws {
        let r = try primed()
        let (_, f1) = try make(1, size: 3000, key: false)
        feed(r, Array(f1.dropLast()), at: 100 * ms)
        XCTAssertEqual(r.tick(nowMicros: 130 * ms, rttMs: nil), [])
        XCTAssertEqual(r.tick(nowMicros: 131 * ms, rttMs: nil), [.frameLost(frameId: 1), .requestKeyframe])
        XCTAssertTrue(r.awaitingKeyframe)
    }

    func testStallNackThenTimeout() throws {
        let r = try primed()
        let (_, f1) = try make(1, size: 3000, key: false)
        feed(r, Array(f1.dropLast()), at: 100 * ms, rtt: 2)
        XCTAssertEqual(r.tick(nowMicros: 131 * ms, rttMs: 2).count, 1)
        XCTAssertEqual(r.tick(nowMicros: 137 * ms, rttMs: 2), [.frameLost(frameId: 1), .requestKeyframe])
    }

    // MARK: Keyframe jump

    func testKeyframeJump() throws {
        let r = try primed()
        let (_, f1) = try make(1, size: 3000, key: false)
        feed(r, Array(f1.dropFirst()), at: 16 * ms)
        let (_, f2) = try make(2, size: 3000, key: false)
        feed(r, Array(f2.dropFirst()), at: 32 * ms)
        let (kp, k4) = try make(4, size: 5000, key: true)
        let ev = feed(r, k4, at: 64 * ms)
        XCTAssertEqual(ev.count, 3)
        XCTAssertEqual(ev[0], .frameLost(frameId: 1))
        XCTAssertEqual(ev[1], .frameLost(frameId: 2))
        if case let .frame(id, payload, key, _) = ev[2] {
            XCTAssertEqual(id, 4)
            XCTAssertEqual(payload, kp)
            XCTAssertTrue(key)
        } else {
            XCTFail("expected frame")
        }
        XCTAssertFalse(ev.contains(.requestKeyframe))
        XCTAssertFalse(r.awaitingKeyframe)
        XCTAssertEqual(r.counters.framesLost, 2)
        XCTAssertEqual(r.framesInAssembly, 0)
        let (p5, f5) = try make(5, size: 800, key: false)
        XCTAssertEqual(frameEvents(feed(r, f5, at: 80 * ms)).first?.payload, p5)
    }

    func testOutOfOrderCompletionStillDeliversInOrder() throws {
        let r = try primed()
        let (p1, f1) = try make(1, size: 3000, key: false)
        let (p2, f2) = try make(2, size: 3000, key: false)
        // Frame 2 completes first with a generous RTT: frame 1 is NACKed, then arrives.
        var ev = feed(r, f1.filter { $0.fragment.fragIndex != 2 }, at: 10 * ms, rtt: 2)
        ev += feed(r, f2, at: 11 * ms, rtt: 2)
        XCTAssertEqual(ev, [.nack(NackPacket(frameId: 1, blockIndex: 0, fragIndices: [2]))])
        let got = frameEvents(feed(r, [f1[2]], at: 12 * ms, rtt: 2))
        XCTAssertEqual(got.map { $0.payload }, [p1, p2])
    }

    // MARK: Capacity

    func testCapacityAtStartup() throws {
        let r = Reassembler()
        for i in 0..<12 {
            let (_, f) = try make(UInt32(10 + i), size: 3000, key: false)
            feed(r, [f[0]], at: UInt64(i) * ms)
            XCTAssertLessThanOrEqual(r.framesInAssembly, 8)
        }
        XCTAssertEqual(r.framesInAssembly, 8)
        XCTAssertEqual(r.counters.framesLost, 0)
    }

    func testCapacityEvictionCountsLoss() throws {
        let r = try primed()
        var all: [Reassembler.Event] = []
        for i in 1...12 {
            let (_, f) = try make(UInt32(i), size: 3000, key: false)
            all += feed(r, [f[0]], at: UInt64(i) * ms, rtt: 2)
            XCTAssertLessThanOrEqual(r.framesInAssembly, 8)
        }
        XCTAssertTrue(all.contains(.frameLost(frameId: 1)))
        XCTAssertTrue(all.contains(.requestKeyframe))
        XCTAssertTrue(r.awaitingKeyframe)
    }

    func testStaleFragmentOlderThanAllHeldIsIgnoredWhenFull() throws {
        let r = Reassembler()
        for i in 0..<8 {
            let (_, f) = try make(UInt32(100 + i), size: 3000, key: false)
            feed(r, [f[0]], at: 0)
        }
        let (_, old) = try make(50, size: 3000, key: false)
        feed(r, [old[0]], at: ms)
        XCTAssertEqual(r.framesInAssembly, 8)
    }

    // MARK: Invalid input

    func testInvalidFragmentsIgnored() throws {
        let r = try primed()
        let (_, f) = try make(1, size: 3000, key: false, fec: 0.1)   // k = 3, m = 1
        let d0 = f[0].fragment
        func variant(_ edit: (inout VideoFragment) -> Void) -> VideoFragment {
            var v = d0
            edit(&v)
            return v
        }
        let bad: [(PacketType, VideoFragment)] = [
            (.videoData, variant { $0.fragIndex = 3 }),                       // index >= k
            (.videoData, variant { $0.k = 4 }),                               // k inconsistent with length
            (.videoParity, variant { $0.payload = Data(count: 1000) }),       // wrong parity size
            (.audio, d0),                                                     // wrong type
            (.videoData, variant { $0.payload = Data(count: 100) }),          // short non-last data
            (.videoData, variant { $0.blockIndex = 3 }),                      // block out of range
            (.videoData, variant { $0.m = 40 }),                              // m too large
            (.videoData, variant { $0.frameLength = 0 }),
        ]
        for (t, v) in bad {
            XCTAssertEqual(r.ingest(type: t, fragment: v, nowMicros: 0, rttMs: nil), [])
        }
        XCTAssertEqual(r.counters.fragsInvalid, UInt64(bad.count))
        XCTAssertEqual(r.framesInAssembly, 0)

        // Inconsistent with the frame seen first.
        feed(r, [f[0]], at: 0)
        var wrongKey = f[1].fragment
        wrongKey.isKeyframe = true
        XCTAssertEqual(r.ingest(type: .videoData, fragment: wrongKey, nowMicros: 0, rttMs: nil), [])
        var wrongM = f[1].fragment
        wrongM.m = 2
        XCTAssertEqual(r.ingest(type: .videoData, fragment: wrongM, nowMicros: 0, rttMs: nil), [])
        XCTAssertEqual(r.counters.fragsInvalid, UInt64(bad.count) + 2)
        XCTAssertEqual(r.counters.fragsReceived, 2)   // keyframe 0 fragment + f[0]
    }

    func testOldFramesIgnored() throws {
        let r = try primed()
        let (_, old) = try make(0, size: 500, key: true)
        let before = r.counters.fragsDuplicate
        XCTAssertEqual(feed(r, old, at: ms), [])
        XCTAssertEqual(r.counters.fragsDuplicate, before + UInt64(old.count))
        XCTAssertEqual(r.framesInAssembly, 0)
    }

    func testReset() throws {
        let r = try primed()
        let (_, f1) = try make(1, size: 3000, key: false)
        feed(r, [f1[0]], at: 0)
        r.reset()
        XCTAssertTrue(r.awaitingKeyframe)
        XCTAssertEqual(r.framesInAssembly, 0)
        XCTAssertEqual(r.counters.framesDelivered, 0)
        XCTAssertEqual(r.tick(nowMicros: 500 * ms, rttMs: nil), [])
    }

    // MARK: Fuzz

    func testFuzzLossyReordered() throws {
        var prng = TestRNG(seed: 2024)
        let r = Reassembler()
        var originals: [UInt32: Data] = [:]
        var buffer: [(OutgoingFragment, UInt64)] = []
        var needKey = true
        var now: UInt64 = 0
        var lastDelivered: UInt32?
        var lossPending = true      // nothing delivered yet: the first delivery must be a keyframe
        var delivered = 0

        func handle(_ events: [Reassembler.Event]) {
            XCTAssertLessThanOrEqual(r.framesInAssembly, MSConstants.reassemblyMaxFrames)
            for e in events {
                switch e {
                case .requestKeyframe: needKey = true
                case .frameLost: lossPending = true
                case .nack: XCTFail("rtt is nil, no NACK expected")
                case let .frame(id, payload, key, _):
                    XCTAssertEqual(payload, originals[id], "payload of frame \(id)")
                    if let last = lastDelivered {
                        XCTAssertGreaterThan(id, last)
                        if !key { XCTAssertEqual(id, last + 1) }
                    }
                    if lossPending { XCTAssertTrue(key, "frame \(id) after loss must be a keyframe") }
                    lossPending = false
                    lastDelivered = id
                    delivered += 1
                }
            }
        }
        func ingestOne() {
            let window = min(30, buffer.count)
            let (o, t) = buffer.remove(at: prng.below(window))
            handle(r.ingest(type: o.type, fragment: o.fragment, nowMicros: max(now, t), rttMs: nil))
        }

        for id in 0..<300 {
            let isKey = needKey
            if isKey { needKey = false }
            let size = 1 + prng.below(prng.chance(0.1) ? 100_000 : 6000)
            let payload = prng.payload(size)
            originals[UInt32(id)] = payload
            let frags = try Fragmenter.fragment(payload: payload, frameId: UInt32(id), isKeyframe: isKey,
                                                captureTimeMicros: now, fecRatio: 0.1)
            for f in frags where !prng.chance(0.05) { buffer.append((f, now)) }
            while buffer.count > 30 { ingestOne() }
            for _ in 0..<3 {
                now += 5 * ms
                handle(r.tick(nowMicros: now, rttMs: nil))
            }
            now += ms
        }
        while !buffer.isEmpty { ingestOne() }
        for _ in 0..<40 {
            now += 5 * ms
            handle(r.tick(nowMicros: now, rttMs: nil))
        }
        XCTAssertGreaterThan(delivered, 30)  // each loss costs >= 100 ms of keyframe wait
        XCTAssertEqual(r.counters.framesDelivered, UInt64(delivered))
        XCTAssertGreaterThan(r.counters.fragsRecovered, 0)
    }
}
