import XCTest
import MSCore
import MSCodec
import MSProtocol
@testable import MSProbe

final class ProbeHostileInputTests: XCTestCase {
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

    // MARK: probeBlob (SampleFile.parse)

    private func validBlob() -> Data {
        let fmt = VideoFormat(codec: .hevc, width: 640, height: 360, fps: 60, bitDepth: 8)
        var frames: [EncodedFrame] = []
        for i in 0..<3 {
            let t: UInt64 = UInt64(i) * 16_666
            let sets: [Data]? = i == 0 ? [Data([1, 2, 3])] : nil
            frames.append(EncodedFrame(data: Data(repeating: UInt8(i), count: 20), parameterSets: sets,
                                       isKeyframe: i == 0, captureTimeMicros: t))
        }
        return SampleFile(header: .init(format: fmt, frameCount: 3, bitrate: 1), frames: frames).serialize()
    }

    func testSampleFileParseRandomAndMutatedNeverTraps() {
        var rng = RNG(s: 41)
        let good = validBlob()
        for i in 0..<20_000 {
            var d: Data
            if i % 2 == 0 {
                d = Data((0..<Int.random(in: 0...120, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            } else {
                d = good
                for _ in 0..<Int.random(in: 1...4, using: &rng) {
                    d[Int.random(in: 0..<d.count, using: &rng)] ^= UInt8(1 << Int.random(in: 0...7, using: &rng))
                }
                if i % 5 == 1 { d = d.prefix(Int.random(in: 0...d.count, using: &rng)) }
            }
            _ = try? SampleFile.parse(d)
        }
    }

    func testSampleFileLengthFieldAttacks() throws {
        func blob(jsonLen: UInt32, json: String = "{}", extra: Data = Data()) -> Data {
            var w = ByteWriter(capacity: 64)
            w.bytes(Data("MSV1".utf8)); w.u32(jsonLen); w.bytes(Data(json.utf8)); w.bytes(extra)
            return w.data
        }
        XCTAssertThrowsError(try SampleFile.parse(blob(jsonLen: UInt32.max)))
        XCTAssertThrowsError(try SampleFile.parse(blob(jsonLen: 0x7FFF_FFFF)))
        // Header claiming Int.max frames with no data: must hit `truncated` on the first frame, not allocate.
        let hdr = #"{"format":{"codec":2,"width":640,"height":360,"fps":60,"bitDepth":8},"frameCount":9223372036854775807,"bitrate":1}"#
        XCTAssertThrowsError(try SampleFile.parse(blob(jsonLen: UInt32(hdr.utf8.count), json: hdr)))
        // A frame length of 0xFFFFFFFF with a short body.
        var w = ByteWriter(capacity: 8)
        w.u8(1); w.u32(UInt32.max)
        let hdr1 = hdr.replacingOccurrences(of: "9223372036854775807", with: "1")
        XCTAssertThrowsError(try SampleFile.parse(blob(jsonLen: UInt32(hdr1.utf8.count), json: hdr1, extra: w.data)))
        // Negative frame count and zero fps are rejected as a bad header.
        let neg = hdr.replacingOccurrences(of: "9223372036854775807", with: "-5")
        XCTAssertThrowsError(try SampleFile.parse(blob(jsonLen: UInt32(neg.utf8.count), json: neg)))
        let fps0 = hdr.replacingOccurrences(of: "\"fps\":60", with: "\"fps\":0")
        XCTAssertThrowsError(try SampleFile.parse(blob(jsonLen: UInt32(fps0.utf8.count), json: fps0)))
    }

    /// The Display must answer a garbage probeBlob with a failed result, never crash.
    func testResponderAnswersGarbageBlobWithFailedResult() {
        let got = XCTestExpectation(description: "probeResult")
        var result: ProbeResultMessage?
        let r = ProbeResponder(sendControl: { m in
            if case .probeResult(let p) = m { result = p; got.fulfill() }
        }, openMedia: {})
        XCTAssertTrue(r.handle(.probeBlob(Data([1, 2, 3, 4, 5]))))
        wait(for: [got], timeout: 10)
        let res = try? JSONDecoder().decode(BenchResult.self, from: result?.json ?? Data())
        XCTAssertEqual(res?.passed, false)
        r.stop()
    }

    // MARK: Link probe bookkeeping

    func testLinkProbeReceiverBoundsTrainsAndArrivals() {
        let rx = LinkProbeReceiver()
        // Packets for endless train ids (what a hostile authenticated peer can do) keep memory bounded.
        for id in 0..<5000 as Range<UInt32> { rx.packet(LinkProbePacket(trainId: id, seq: 0), at: UInt64(id)) }
        rx.expect(LinkProbeStartMessage(trainId: 4999, rateBps: 1, durationMs: 1, packetCount: 1))
        XCTAssertNotNil(rx.finish(4999))   // the newest train survives pruning
        // Endless packets of one train stop being stored at the cap.
        let rx2 = LinkProbeReceiver()
        for i in 0..<(LinkProbeReceiver.maxArrivalsPerTrain + 1000) {
            rx2.packet(LinkProbePacket(trainId: 7, seq: UInt32(truncatingIfNeeded: i)), at: UInt64(i))
        }
        rx2.expect(LinkProbeStartMessage(trainId: 7, rateBps: 1, durationMs: 1, packetCount: Int.max))
        XCTAssertEqual(rx2.finish(7)?.received, LinkProbeReceiver.maxArrivalsPerTrain)
    }

    func testLinkProbeReceiverHostileStartValues() {
        let rx = LinkProbeReceiver()
        for (rate, dur, count) in [(Int.max, Int.max, Int.max), (Int.min, Int.min, Int.min), (0, 0, 0), (-1, -1, -1)] {
            rx.expect(LinkProbeStartMessage(trainId: 1, rateBps: rate, durationMs: dur, packetCount: count))
            _ = rx.isComplete(1)
            _ = rx.finish(1)
            rx.expect(LinkProbeStartMessage(trainId: 2, rateBps: rate, durationMs: dur, packetCount: count))
            _ = rx.finish(2)
        }
        // Result values from a hostile Display feed delivery math: no trap.
        _ = LinkTrainResult.deliveryBps(received: Int.max, firstArrivalMicros: 0, lastArrivalMicros: UInt64.max, packetBytes: 1200)
        _ = LinkTrainResult.deliveryBps(received: -1, firstArrivalMicros: UInt64.max, lastArrivalMicros: 0, packetBytes: 1200)
        _ = LinkTrainResult.stretchMs(received: Int.max, sent: Int.min, durationMs: Int.max, firstArrivalMicros: 0, lastArrivalMicros: UInt64.max)
        _ = LinkTrainResult.stretchMs(received: 0, sent: 0, durationMs: Int.min, firstArrivalMicros: UInt64.max, lastArrivalMicros: 0)
    }
}
