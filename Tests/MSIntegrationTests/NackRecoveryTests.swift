import XCTest
import MSCore
import MSProtocol
@testable import MSHost

/// Fragmenter -> lossy channel -> Reassembler, with PacketHistory answering NACKs over the encoded wire formats.
final class NackRecoveryTests: XCTestCase {
    private func payload(_ id: UInt32, count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(id)) })
    }

    func testNackRetransmitRecoversFrameWithoutKeyframe() throws {
        let history = PacketHistory()
        let rx = Reassembler()
        var now: UInt64 = 1_000_000
        var delivered: [UInt32] = []
        var payloads: [UInt32: Data] = [:]
        var lost = 0, keyframeRequests = 0, nacksSent = 0, retransmitted = 0

        func handle(_ events: [Reassembler.Event]) {
            for e in events {
                switch e {
                case .frame(let id, let p, _, _): delivered.append(id); payloads[id] = p
                case .frameLost: lost += 1
                case .requestKeyframe: keyframeRequests += 1
                case .nack(let n):
                    nacksSent += 1
                    // Wire round trip, then the Host answers from history.
                    guard let decoded = try? NackPacket.decode(n.encode()) else { return XCTFail("nack decode") }
                    for (t, d) in history.retransmissions(for: decoded, nowMicros: now) {
                        retransmitted += 1
                        guard let f = try? VideoFragment.decode(d) else { return XCTFail("fragment decode") }
                        now += 500
                        handle(rx.ingest(type: t, fragment: f, nowMicros: now, rttMs: 1.0))
                    }
                }
            }
        }

        // Frame 1 (keyframe) and 2..4 (delta, FEC off so a lost data fragment cannot be rebuilt).
        for id in UInt32(1)...4 {
            let fr = try Fragmenter.fragment(payload: payload(id, count: 6000), frameId: id, isKeyframe: id == 1,
                                             captureTimeMicros: UInt64(id), fecRatio: 0)
            history.record(frameId: id, fragments: fr, nowMicros: now)
            for o in fr {
                // The channel drops data fragment 2 of frame 3.
                if id == 3, o.type == .videoData, o.fragment.fragIndex == 2 { continue }
                now += 1000
                handle(rx.ingest(type: o.type, fragment: o.fragment, nowMicros: now, rttMs: 1.0))
            }
            now += 16_000
        }
        handle(rx.tick(nowMicros: now, rttMs: 1.0))

        XCTAssertEqual(delivered, [1, 2, 3, 4])
        XCTAssertEqual(payloads[3], payload(3, count: 6000))
        XCTAssertGreaterThan(nacksSent, 0)
        XCTAssertEqual(retransmitted, 1, "only the missing fragment is resent")
        XCTAssertEqual(lost, 0)
        XCTAssertEqual(keyframeRequests, 0, "recovered by NACK, no keyframe needed")
        XCTAssertFalse(rx.awaitingKeyframe)
    }

    func testWithoutHistoryTheLossNeedsAKeyframe() throws {
        let rx = Reassembler()
        var now: UInt64 = 1_000_000
        var lost = 0, requests = 0
        func handle(_ events: [Reassembler.Event]) {
            for e in events {
                if case .frameLost = e { lost += 1 }
                if case .requestKeyframe = e { requests += 1 }
            }
        }
        for id in UInt32(1)...3 {
            let fr = try Fragmenter.fragment(payload: payload(id, count: 6000), frameId: id, isKeyframe: id == 1,
                                             captureTimeMicros: 1, fecRatio: 0)
            for o in fr {
                if id == 2, o.fragment.fragIndex == 2 { continue }
                now += 1000
                handle(rx.ingest(type: o.type, fragment: o.fragment, nowMicros: now, rttMs: 1.0))
            }
            now += 16_000
        }
        now += 20_000
        handle(rx.tick(nowMicros: now, rttMs: 1.0))
        XCTAssertEqual(lost, 1)
        XCTAssertGreaterThan(requests, 0)
    }
}
