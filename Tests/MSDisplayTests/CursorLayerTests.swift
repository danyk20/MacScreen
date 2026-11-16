import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MSProtocol
@testable import MSDisplay

final class CursorLayerTests: XCTestCase {
    static func png(size: Int = 4) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func msg(_ id: UInt16, hot: Double = 2) -> CursorImageMessage {
        CursorImageMessage(id: id, png: Self.png(), hotX: hot, hotY: hot, widthPt: 16, heightPt: 24)
    }

    func testCacheInsertAndEvict() {
        var c = CursorImageCache(capacity: 2)
        XCTAssertTrue(c.insert(msg(1)))
        XCTAssertTrue(c.insert(msg(2)))
        XCTAssertTrue(c.insert(msg(3)))
        XCTAssertNil(c[1]); XCTAssertNotNil(c[2]); XCTAssertNotNil(c[3]); XCTAssertEqual(c.count, 2)
        XCTAssertTrue(c.insert(msg(3, hot: 5)))     // replace does not evict
        XCTAssertEqual(c[3]?.hotX, 5); XCTAssertEqual(c.count, 2)
        XCTAssertFalse(c.insert(CursorImageMessage(id: 9, png: Data([1, 2]), hotX: 0, hotY: 0, widthPt: 8, heightPt: 8)))
        XCTAssertNil(c[9])
    }

    func testGeometry() {
        var c = CursorImageCache()
        c.insert(msg(1))
        let e = c[1]!
        let r = CursorGeometry.frame(x: 0.5, y: 0.25, entry: e, in: CGSize(width: 200, height: 100))
        XCTAssertEqual(r, CGRect(x: 98, y: 23, width: 16, height: 24))
        let clamped = CursorGeometry.frame(x: 2, y: -1, entry: e, in: CGSize(width: 200, height: 100))
        XCTAssertEqual(clamped.origin, CGPoint(x: 198, y: -2))
    }

    func testSeqWrap() {
        XCTAssertTrue(CursorGeometry.isNewer(2, than: 1))
        XCTAssertFalse(CursorGeometry.isNewer(1, than: 1))
        XCTAssertFalse(CursorGeometry.isNewer(1, than: 2))
        XCTAssertTrue(CursorGeometry.isNewer(0, than: .max))
    }

    func testModel() {
        var m = CursorModel()
        let size = CGSize(width: 100, height: 100)
        XCTAssertNil(m.drawState(in: size))
        XCTAssertTrue(m.ingest(position: CursorPacket(seq: 5, x: 0.5, y: 0.5, visible: true, imageId: 1)))
        XCTAssertNil(m.drawState(in: size), "image not known yet")
        m.ingest(image: msg(1))
        XCTAssertNotNil(m.drawState(in: size))
        XCTAssertFalse(m.ingest(position: CursorPacket(seq: 4, x: 0, y: 0, visible: true, imageId: 1)), "stale")
        XCTAssertEqual(m.latest?.x, 0.5)
        XCTAssertTrue(m.ingest(position: CursorPacket(seq: 6, x: 0.1, y: 0.1, visible: false, imageId: 1)))
        XCTAssertNil(m.drawState(in: size), "hidden")
        m.reset()
        XCTAssertNil(m.latest)
    }
}
