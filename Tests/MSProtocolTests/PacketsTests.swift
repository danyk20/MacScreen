import XCTest
import MSCore
@testable import MSProtocol

final class PacketsTests: XCTestCase {
    private func hex(_ s: String) -> Data {
        let c = Array(s.filter { !$0.isWhitespace })
        var d = Data()
        var i = 0
        while i + 1 < c.count {
            d.append(UInt8(String(c[i...i + 1]), radix: 16) ?? 0)
            i += 2
        }
        return d
    }

    private func sliced(_ d: Data) -> Data {
        var big = Data([0xEE, 0xEE, 0xEE])
        big.append(d)
        big.append(0xFF)
        return big[3..<(3 + d.count)]
    }

    private func frag(payload: Data = Data([0xAA, 0xBB])) -> VideoFragment {
        VideoFragment(frameId: 0x01020304, isKeyframe: true, blockIndex: 2, blockCount: 3,
                      fragIndex: 0x0506, k: 7, m: 8, frameLength: 0x090A0B0C,
                      captureTimeMicros: 0x1112131415161718, payload: payload)
    }

    // MARK: Header

    func testHeaderGolden() throws {
        let h = PacketHeader(type: .videoData, counter: 0x0102030405060708)
        XCTAssertEqual(h.encode(), hex("01 00 0000 0102030405060708"))
        XCTAssertEqual(try PacketHeader.decode(h.encode()), h)
    }

    func testHeaderRoundTripAllTypesAndBounds() throws {
        for t in PacketType.allCases {
            for c in [UInt64(0), UInt64.max] {
                let h = PacketHeader(type: t, counter: c)
                XCTAssertEqual(try PacketHeader.decode(h.encode()), h)
            }
        }
    }

    func testHeaderErrors() {
        let e = PacketHeader(type: .ping, counter: 9).encode()
        for n in 0..<PacketHeader.size {
            XCTAssertThrowsError(try PacketHeader.decode(e.prefix(n))) {
                XCTAssertEqual($0 as? PacketError, .truncated)
            }
        }
        var bad = e
        bad[0] = 0
        XCTAssertThrowsError(try PacketHeader.decode(bad)) { XCTAssertEqual($0 as? PacketError, .unknownType(0)) }
        bad[0] = 10
        XCTAssertThrowsError(try PacketHeader.decode(bad)) { XCTAssertEqual($0 as? PacketError, .unknownType(10)) }
    }

    func testHeaderIgnoresReservedAndSlices() throws {
        var e = PacketHeader(type: .nack, counter: 77).encode()
        e[1] = 0xFF; e[2] = 0xAB; e[3] = 0xCD
        XCTAssertEqual(try PacketHeader.decode(sliced(e)), PacketHeader(type: .nack, counter: 77))
    }

    // MARK: VideoFragment

    func testVideoFragmentGolden() throws {
        let e = frag().encode()
        XCTAssertEqual(e, hex("01020304 01 02 03 00 0506 0007 0008 0000 090A0B0C 1112131415161718 AABB"))
        XCTAssertEqual(VideoFragment.headerSize, 28)
        XCTAssertEqual(try VideoFragment.decode(e), frag())
    }

    func testVideoFragmentRoundTripBounds() throws {
        let f = VideoFragment(frameId: .max, isKeyframe: false, blockIndex: 254, blockCount: 255,
                              fragIndex: .max, k: 64, m: 32, frameLength: .max,
                              captureTimeMicros: .max,
                              payload: Data(repeating: 0x5A, count: MSConstants.fragmentSize))
        XCTAssertEqual(try VideoFragment.decode(f.encode()), f)
        let z = VideoFragment(frameId: 0, isKeyframe: false, blockIndex: 0, blockCount: 1,
                              fragIndex: 0, k: 1, m: 0, frameLength: 0, captureTimeMicros: 0,
                              payload: Data([1]))
        XCTAssertEqual(try VideoFragment.decode(z.encode()), z)
        XCTAssertEqual(try VideoFragment.decode(sliced(f.encode())), f)
    }

    func testVideoFragmentTruncated() {
        let e = frag().encode()
        for n in 0..<(VideoFragment.headerSize) {
            XCTAssertThrowsError(try VideoFragment.decode(e.prefix(n))) {
                XCTAssertEqual($0 as? PacketError, .truncated, "prefix \(n)")
            }
        }
        XCTAssertThrowsError(try VideoFragment.decode(e.prefix(VideoFragment.headerSize))) {
            XCTAssertEqual($0 as? PacketError, .invalidField("payload"))
        }
    }

    func testVideoFragmentValidation() {
        func check(_ mutate: (inout VideoFragment) -> Void, _ field: String,
                   file: StaticString = #filePath, line: UInt = #line) {
            var f = frag()
            mutate(&f)
            XCTAssertThrowsError(try VideoFragment.decode(f.encode()), file: file, line: line) {
                XCTAssertEqual($0 as? PacketError, .invalidField(field), file: file, line: line)
            }
        }
        check({ $0.k = 0 }, "k")
        check({ $0.k = 65 }, "k")
        check({ $0.m = 33 }, "m")
        check({ $0.blockCount = 0; $0.blockIndex = 0 }, "blockCount")
        check({ $0.blockIndex = 3 }, "blockIndex")
        check({ $0.payload = Data(repeating: 1, count: 1201) }, "payload")
        check({ $0.payload = Data() }, "payload")
    }

    // MARK: Audio

    func testAudio() throws {
        let pcm = Data((0..<960).map { UInt8($0 & 0xFF) })
        for (s, t) in [(UInt32(0), UInt64(0)), (UInt32.max, UInt64.max), (5, 123456)] {
            let a = AudioPacket(seq: s, hostTimeMicros: t, pcm: pcm)
            let e = a.encode()
            XCTAssertEqual(e.count, 972)
            XCTAssertEqual(try AudioPacket.decode(e), a)
            XCTAssertEqual(try AudioPacket.decode(sliced(e)), a)
        }
        let e = AudioPacket(seq: 1, hostTimeMicros: 2, pcm: pcm).encode()
        for n in 0..<12 {
            XCTAssertThrowsError(try AudioPacket.decode(e.prefix(n))) { XCTAssertEqual($0 as? PacketError, .truncated) }
        }
        for n in [12, 500, 971] {
            XCTAssertThrowsError(try AudioPacket.decode(e.prefix(n))) { XCTAssertEqual($0 as? PacketError, .invalidField("pcm")) }
        }
        var long = e
        long.append(0)
        XCTAssertThrowsError(try AudioPacket.decode(long)) { XCTAssertEqual($0 as? PacketError, .invalidField("pcm")) }
    }

    // MARK: Cursor

    func testCursor() throws {
        let c = CursorPacket(seq: 1, x: 1.0, y: 0.5, visible: true, imageId: 0x0102)
        XCTAssertEqual(c.encode(), hex("00000001 3F800000 3F000000 01 0102"))
        XCTAssertEqual(try CursorPacket.decode(c.encode()), c)
        let b = CursorPacket(seq: .max, x: 0, y: 0, visible: false, imageId: .max)
        XCTAssertEqual(try CursorPacket.decode(sliced(b.encode())), b)
        let e = c.encode()
        for n in 0..<e.count {
            XCTAssertThrowsError(try CursorPacket.decode(e.prefix(n))) { XCTAssertEqual($0 as? PacketError, .truncated) }
        }
    }

    // MARK: Ping / Pong

    func testPingPong() throws {
        for (i, t) in [(UInt32(0), UInt64(0)), (UInt32.max, UInt64.max), (42, 1_000_000)] {
            let p = PingPacket(id: i, t0: t)
            XCTAssertEqual(try PingPacket.decode(sliced(p.encode())), p)
            let q = PongPacket(id: i, t0: t, t1: t &+ 1, t2: t &+ 2)
            XCTAssertEqual(try PongPacket.decode(sliced(q.encode())), q)
        }
        XCTAssertEqual(PingPacket(id: 1, t0: 2).encode(), hex("00000001 0000000000000002"))
        let pe = PingPacket(id: 1, t0: 2).encode()
        for n in 0..<pe.count {
            XCTAssertThrowsError(try PingPacket.decode(pe.prefix(n))) { XCTAssertEqual($0 as? PacketError, .truncated) }
        }
        let qe = PongPacket(id: 1, t0: 2, t1: 3, t2: 4).encode()
        XCTAssertEqual(qe.count, 28)
        for n in 0..<qe.count {
            XCTAssertThrowsError(try PongPacket.decode(qe.prefix(n))) { XCTAssertEqual($0 as? PacketError, .truncated) }
        }
    }

    // MARK: Feedback

    func testFeedbackGolden() throws {
        let f = FeedbackPacket(highestDecodedFrame: 1, framesDecoded: 2, framesDropped: 3,
                               fragsReceived: 4, fragsLost: 5, fragsRecovered: 6,
                               avgDecodeMsX10: 0x0102, jitterMsX10: 0x0304, requestKeyframe: true)
        let e = f.encode()
        XCTAssertEqual(e, hex("00000001 00000002 00000003 00000004 00000005 00000006 0102 0304 01"))
        XCTAssertEqual(try FeedbackPacket.decode(e), f)
        for n in 0..<e.count {
            XCTAssertThrowsError(try FeedbackPacket.decode(e.prefix(n))) { XCTAssertEqual($0 as? PacketError, .truncated) }
        }
    }

    func testFeedbackBoundsAndDoubles() throws {
        let m = FeedbackPacket(highestDecodedFrame: .max, framesDecoded: .max, framesDropped: .max,
                               fragsReceived: .max, fragsLost: .max, fragsRecovered: .max,
                               avgDecodeMsX10: .max, jitterMsX10: .max, requestKeyframe: false)
        XCTAssertEqual(try FeedbackPacket.decode(sliced(m.encode())), m)
        let z = FeedbackPacket(highestDecodedFrame: 0, framesDecoded: 0, framesDropped: 0,
                               fragsReceived: 0, fragsLost: 0, fragsRecovered: 0,
                               avgDecodeMsX10: 0, jitterMsX10: 0, requestKeyframe: false)
        XCTAssertEqual(try FeedbackPacket.decode(z.encode()), z)

        let d = FeedbackPacket(highestDecodedFrame: 0, framesDecoded: 0, framesDropped: 0,
                               fragsReceived: 0, fragsLost: 0, fragsRecovered: 0,
                               avgDecodeMs: 2.5, jitterMs: 12.34, requestKeyframe: true)
        XCTAssertEqual(d.avgDecodeMsX10, 25)
        XCTAssertEqual(d.jitterMsX10, 123)
        XCTAssertEqual(d.avgDecodeMs, 2.5, accuracy: 1e-9)
        XCTAssertEqual(d.jitterMs, 12.3, accuracy: 1e-9)
        let c = FeedbackPacket(highestDecodedFrame: 0, framesDecoded: 0, framesDropped: 0,
                               fragsReceived: 0, fragsLost: 0, fragsRecovered: 0,
                               avgDecodeMs: -5, jitterMs: 99999, requestKeyframe: false)
        XCTAssertEqual(c.avgDecodeMsX10, 0)
        XCTAssertEqual(c.jitterMsX10, 65535)
        XCTAssertEqual(c.jitterMs, 6553.5, accuracy: 1e-9)
    }

    // MARK: Nack

    func testNack() throws {
        for n in [0, 1, 255] {
            let idx = (0..<n).map { UInt16(truncatingIfNeeded: $0 &* 257) }
            let p = NackPacket(frameId: .max, blockIndex: 7, fragIndices: idx)
            let e = p.encode()
            XCTAssertEqual(e.count, 6 + 2 * n)
            XCTAssertEqual(try NackPacket.decode(e), p)
            XCTAssertEqual(try NackPacket.decode(sliced(e)), p)
        }
        XCTAssertEqual(NackPacket(frameId: 1, blockIndex: 2, fragIndices: [3, 0xFFFF]).encode(),
                       hex("00000001 02 02 0003 FFFF"))
    }

    func testNackOverflowAndTruncation() throws {
        let p = NackPacket(frameId: 1, blockIndex: 0, fragIndices: (0..<300).map { UInt16($0) })
        let e = p.encode()
        XCTAssertEqual(e.count, 6 + 510)
        XCTAssertEqual(try NackPacket.decode(e).fragIndices.count, 255)

        let full = NackPacket(frameId: 1, blockIndex: 0, fragIndices: [1, 2, 3]).encode()
        for n in 0..<full.count {
            XCTAssertThrowsError(try NackPacket.decode(full.prefix(n))) { XCTAssertEqual($0 as? PacketError, .truncated) }
        }
        var lying = hex("00000001 00 05 0001 0002")
        XCTAssertThrowsError(try NackPacket.decode(lying)) { XCTAssertEqual($0 as? PacketError, .truncated) }
        lying[5] = 255
        XCTAssertThrowsError(try NackPacket.decode(lying)) { XCTAssertEqual($0 as? PacketError, .truncated) }
    }

    // MARK: LinkProbe

    func testLinkProbe() throws {
        for (t, s) in [(UInt32(0), UInt32(0)), (UInt32.max, UInt32.max), (3, 9)] {
            let p = LinkProbePacket(trainId: t, seq: s)
            let e = p.encode()
            XCTAssertEqual(e.count, MSConstants.fragmentSize)
            XCTAssertEqual(e.count, 1200)
            XCTAssertEqual(e.dropFirst(8), Data(count: 1192))
            XCTAssertEqual(try LinkProbePacket.decode(e), p)
            XCTAssertEqual(try LinkProbePacket.decode(sliced(e)), p)
        }
        let e = LinkProbePacket(trainId: 1, seq: 2).encode()
        XCTAssertEqual(e.prefix(8), hex("00000001 00000002"))
        for n in 0..<8 {
            XCTAssertThrowsError(try LinkProbePacket.decode(e.prefix(n))) { XCTAssertEqual($0 as? PacketError, .truncated) }
        }
        XCTAssertEqual(try LinkProbePacket.decode(e.prefix(8)), LinkProbePacket(trainId: 1, seq: 2))
    }
}
