import XCTest
import CoreGraphics
import MSProtocol
@testable import MSDisplay

final class CursorHostileInputTests: XCTestCase {
    private func msg(png: Data, w: Double = 16, h: Double = 16, hot: Double = 1) -> CursorImageMessage {
        CursorImageMessage(id: 1, png: png, hotX: hot, hotY: hot, widthPt: w, heightPt: h)
    }

    func testOversizedCompressedPNGIsRejectedWithoutDecoding() {
        var c = CursorImageCache()
        let big = CursorLayerTests.png() + Data(repeating: 0, count: CursorImageCache.maxPNGBytes)
        XCTAssertFalse(c.insert(msg(png: big)))
        XCTAssertFalse(c.insert(msg(png: Data(repeating: 0x89, count: 8 * 1024 * 1024))))
        XCTAssertEqual(c.count, 0)
    }

    func testHugePixelDimensionsAreRejected() {
        var c = CursorImageCache()
        // A solid PNG compresses to a few KB but would decode to ~16 MB.
        let bomb = CursorLayerTests.png(size: 2048)
        XCTAssertLessThan(bomb.count, CursorImageCache.maxPNGBytes)
        XCTAssertFalse(c.insert(msg(png: bomb)))
        XCTAssertTrue(c.insert(msg(png: CursorLayerTests.png(size: 64))))
    }

    func testNonFiniteAndAbsurdGeometryIsRejected() {
        var c = CursorImageCache()
        let png = CursorLayerTests.png()
        for v in [Double.nan, .infinity, -.infinity, 0, -1, 1e9] {
            XCTAssertFalse(c.insert(msg(png: png, w: v)), "width \(v)")
            XCTAssertFalse(c.insert(msg(png: png, h: v)), "height \(v)")
        }
        XCTAssertFalse(c.insert(msg(png: png, hot: .nan)))
        XCTAssertFalse(c.insert(msg(png: png, hot: .infinity)))
        XCTAssertEqual(c.count, 0)
    }

    func testRandomBytesNeverCrashAndNeverInsert() {
        var c = CursorImageCache()
        var rng = SplitMix(state: 99)
        for _ in 0..<500 {
            var d = Data()
            for _ in 0..<Int.random(in: 0...300, using: &rng) { d.append(UInt8.random(in: 0...255, using: &rng)) }
            XCTAssertFalse(c.insert(msg(png: d)))
        }
        // Truncated and bit-flipped valid PNGs: never crash (insert may succeed for a harmless flip).
        let good = CursorLayerTests.png()
        for n in 0..<good.count { _ = c.insert(msg(png: good.prefix(n))) }
        for i in 0..<good.count { var m = good; m[i] ^= 0xFF; _ = c.insert(msg(png: m)) }
    }

    func testModelIgnoresBadCursorPacketValues() {
        // Cursor packet fields are raw network floats: geometry helper must tolerate NaN and infinities.
        let png = CursorLayerTests.png()
        var c = CursorImageCache()
        XCTAssertTrue(c.insert(msg(png: png)))
        let e = c[1]!
        for v in [Float.nan, .infinity, -.infinity, 1e30, -1e30] {
            _ = CursorGeometry.frame(x: v, y: v, entry: e, in: CGSize(width: 100, height: 100))
        }
    }
}

/// Tiny deterministic generator wrapper (SplitMix64 over an inout state).
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
