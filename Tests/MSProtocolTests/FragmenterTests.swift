import XCTest
import MSCore
@testable import MSProtocol

/// Deterministic PRNG shared by the fragmenter and reassembler tests.
struct TestRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }
    mutating func payload(_ size: Int) -> Data {
        var d = Data(count: size)
        for i in 0..<size { d[i] = UInt8(truncatingIfNeeded: next() >> 24) }
        return d
    }
    mutating func shuffle<T>(_ a: inout [T]) {
        guard a.count > 1 else { return }
        for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, below(i + 1)) }
    }
}

final class FragmenterTests: XCTestCase {
    private func frag(_ size: Int, ratio: Double = 0.1, seed: UInt64 = 1) throws -> (Data, [OutgoingFragment]) {
        var rng = TestRNG(seed: seed)
        let p = rng.payload(size)
        let f = try Fragmenter.fragment(payload: p, frameId: 77, isKeyframe: true,
                                        captureTimeMicros: 123_456, fecRatio: ratio)
        return (p, f)
    }

    func testParityCountTable() {
        XCTAssertEqual(Fragmenter.parityCount(k: 1, fecRatio: 0.1), 1)
        XCTAssertEqual(Fragmenter.parityCount(k: 64, fecRatio: 0.1), 7)
        XCTAssertEqual(Fragmenter.parityCount(k: 64, fecRatio: 0.3), 20)
        XCTAssertEqual(Fragmenter.parityCount(k: 64, fecRatio: 0.9), 32)
        XCTAssertEqual(Fragmenter.parityCount(k: 64, fecRatio: 0), 0)
        XCTAssertEqual(Fragmenter.parityCount(k: 5, fecRatio: -1), 0)
        XCTAssertEqual(Fragmenter.parityCount(k: 5, fecRatio: .nan), 0)
        XCTAssertEqual(Fragmenter.parityCount(k: 5, fecRatio: .infinity), 32)
    }

    func testSizesAndLayout() throws {
        let size = MSConstants.fragmentSize
        for n in [1, 1199, 1200, 1201, 76_800, 76_801, 1_048_576] {
            for ratio in [0.0, 0.1, 0.3] {
                let (payload, out) = try frag(n, ratio: ratio, seed: UInt64(n))
                let total = (n + size - 1) / size
                let blockCount = (total + 63) / 64
                var pos = 0
                var rebuilt = Data()
                for b in 0..<blockCount {
                    let k = min(64, total - 64 * b)
                    let m = Fragmenter.parityCount(k: k, fecRatio: ratio)
                    for i in 0..<k {
                        let o = out[pos]; pos += 1
                        XCTAssertEqual(o.type, .videoData)
                        XCTAssertEqual(Int(o.fragment.fragIndex), i)
                        let isLast = b == blockCount - 1 && i == k - 1
                        XCTAssertEqual(o.fragment.payload.count, isLast ? n - size * (total - 1) : size)
                        rebuilt.append(o.fragment.payload)
                        check(o.fragment, b: b, bc: blockCount, k: k, m: m, len: n)
                    }
                    for i in 0..<m {
                        let o = out[pos]; pos += 1
                        XCTAssertEqual(o.type, .videoParity)
                        XCTAssertEqual(Int(o.fragment.fragIndex), i)
                        XCTAssertEqual(o.fragment.payload.count, size)
                        check(o.fragment, b: b, bc: blockCount, k: k, m: m, len: n)
                    }
                }
                XCTAssertEqual(pos, out.count)
                XCTAssertEqual(rebuilt, payload)
            }
        }
    }

    private func check(_ f: VideoFragment, b: Int, bc: Int, k: Int, m: Int, len: Int) {
        XCTAssertEqual(f.frameId, 77)
        XCTAssertTrue(f.isKeyframe)
        XCTAssertEqual(Int(f.blockIndex), b)
        XCTAssertEqual(Int(f.blockCount), bc)
        XCTAssertEqual(Int(f.k), k)
        XCTAssertEqual(Int(f.m), m)
        XCTAssertEqual(Int(f.frameLength), len)
        XCTAssertEqual(f.captureTimeMicros, 123_456)
    }

    func testSpecificCounts() throws {
        XCTAssertEqual(try frag(1).1.count, 2)            // 1 data + 1 parity
        XCTAssertEqual(try frag(76_800).1.count, 64 + 7)  // exactly one block
        let two = try frag(76_801).1                      // 65 fragments -> blocks of 64 and 1
        XCTAssertEqual(two.count, 64 + 7 + 1 + 1)
        XCTAssertEqual(two.last?.fragment.blockIndex, 1)
        XCTAssertEqual(two.last?.fragment.k, 1)
        XCTAssertEqual(try frag(1200, ratio: 0).1.count, 1)
    }

    func testErrors() {
        XCTAssertThrowsError(try Fragmenter.fragment(payload: Data(), frameId: 0, isKeyframe: false,
                                                     captureTimeMicros: 0, fecRatio: 0)) {
            XCTAssertEqual($0 as? FragmenterError, .emptyPayload)
        }
        let tooBig = Data(count: 255 * 64 * 1200 + 1)
        XCTAssertThrowsError(try Fragmenter.fragment(payload: tooBig, frameId: 0, isKeyframe: false,
                                                     captureTimeMicros: 0, fecRatio: 0)) {
            XCTAssertEqual($0 as? FragmenterError, .payloadTooLarge)
        }
        let maxOK = Data(count: 255 * 64 * 1200)
        XCTAssertNoThrow(try Fragmenter.fragment(payload: maxOK, frameId: 0, isKeyframe: false,
                                                 captureTimeMicros: 0, fecRatio: 0))
    }

    func testSlicedPayload() throws {
        var rng = TestRNG(seed: 9)
        let base = rng.payload(5000)
        let slice = base[100..<4000]
        let out = try Fragmenter.fragment(payload: slice, frameId: 1, isKeyframe: false,
                                          captureTimeMicros: 0, fecRatio: 0)
        var joined = Data()
        for o in out { joined.append(o.fragment.payload) }
        XCTAssertEqual(joined, Data(slice))
    }

    func testEveryFragmentSurvivesWireRoundTrip() throws {
        for n in [1, 1201, 76_801] {
            for o in try frag(n).1 {
                let decoded = try VideoFragment.decode(o.fragment.encode())
                XCTAssertEqual(decoded, o.fragment)
            }
        }
    }
}
