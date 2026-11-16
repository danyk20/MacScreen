import XCTest
import MSProtocol
@testable import MSHost

private final class FakeSampler: CursorSampling {
    var loc: CGPoint? = CGPoint(x: 100, y: 50)
    var visible = true
    var shape: CursorShape? = CursorShape(png: Data([1]), hotX: 1, hotY: 2, widthPt: 16, heightPt: 16)
    var bounds: CGRect? = CGRect(x: 1000, y: 0, width: 200, height: 100)
    func location() -> CGPoint? { loc }
    func isCursorVisible() -> Bool { visible }
    func currentShape() -> CursorShape? { shape }
    func displayBounds() -> CGRect? { bounds }
}

final class CursorTrackerTests: XCTestCase {
    func testNormalize() {
        let b = CGRect(x: 1000, y: 100, width: 200, height: 100)
        var m = CursorMapping.normalize(CGPoint(x: 1100, y: 150), in: b)
        XCTAssertEqual(m.x, 0.5); XCTAssertEqual(m.y, 0.5); XCTAssertTrue(m.inside)
        m = CursorMapping.normalize(CGPoint(x: 1000, y: 100), in: b)
        XCTAssertEqual(m.x, 0); XCTAssertTrue(m.inside)
        m = CursorMapping.normalize(CGPoint(x: 1200, y: 150), in: b)   // right edge is outside
        XCTAssertFalse(m.inside); XCTAssertEqual(m.x, 1)
        m = CursorMapping.normalize(CGPoint(x: 0, y: 500), in: b)
        XCTAssertFalse(m.inside); XCTAssertEqual(m.x, 0); XCTAssertEqual(m.y, 1)
        XCTAssertFalse(CursorMapping.normalize(.zero, in: .zero).inside)
    }

    func testRegistry() {
        var r = CursorImageRegistry()
        let a = CursorShape(png: Data([1]), hotX: 0, hotY: 0, widthPt: 8, heightPt: 8)
        var b = a; b.hotX = 3
        var c = a; c.png = Data([2])
        let ia = r.id(for: a), ib = r.id(for: b), ic = r.id(for: c)
        XCTAssertTrue(ia.isNew); XCTAssertTrue(ib.isNew); XCTAssertTrue(ic.isNew)
        XCTAssertEqual(Set([ia.id, ib.id, ic.id]).count, 3)
        let again = r.id(for: a)
        XCTAssertFalse(again.isNew); XCTAssertEqual(again.id, ia.id)
    }

    private func makeTracker(_ s: FakeSampler, _ pos: @escaping (CursorPacket) -> Void,
                             _ img: @escaping (CursorImageMessage) -> Void) -> CursorTracker {
        CursorTracker(sampler: s, queue: DispatchQueue(label: "t"), sendPosition: pos, sendImage: img)
    }

    func testSendsOnChangeAndRepeats() {
        let s = FakeSampler()
        var pos: [CursorPacket] = [], imgs: [CursorImageMessage] = []
        let t = makeTracker(s, { pos.append($0) }, { imgs.append($0) })
        t.tick(nowMicros: 0)
        XCTAssertEqual(pos.count, 1); XCTAssertEqual(imgs.count, 1)
        XCTAssertEqual(pos[0].x, 0.0); XCTAssertEqual(pos[0].y, 0.5)   // x 100 is left of display
        XCTAssertFalse(pos[0].visible)
        s.loc = CGPoint(x: 1100, y: 50)
        t.tick(nowMicros: 8_000)
        XCTAssertEqual(pos.count, 2); XCTAssertEqual(pos[1].x, 0.5); XCTAssertTrue(pos[1].visible)
        XCTAssertEqual(pos[1].seq, pos[0].seq &+ 1)
        t.tick(nowMicros: 16_000)                       // unchanged: nothing
        XCTAssertEqual(pos.count, 2)
        t.tick(nowMicros: 8_000 + 250_000)              // repeat
        XCTAssertEqual(pos.count, 3)
        XCTAssertEqual(pos[2].imageId, imgs[0].id)
        XCTAssertEqual(imgs.count, 1, "same shape: image sent once")
    }

    func testShapeChangeSendsImageAndUpdatesId() {
        let s = FakeSampler()
        var pos: [CursorPacket] = [], imgs: [CursorImageMessage] = []
        let t = makeTracker(s, { pos.append($0) }, { imgs.append($0) })
        t.tick(nowMicros: 0)
        s.shape = CursorShape(png: Data([9]), hotX: 4, hotY: 4, widthPt: 20, heightPt: 20)
        for i in 1...6 { t.tick(nowMicros: UInt64(i) * 8_000) }   // shape polled every 6th tick
        XCTAssertEqual(imgs.count, 2)
        XCTAssertNotEqual(imgs[0].id, imgs[1].id)
        XCTAssertEqual(pos.last?.imageId, imgs[1].id)
        XCTAssertEqual(imgs[1].hotX, 4)
    }

    func testHiddenCursorAndNoDisplay() {
        let s = FakeSampler()
        s.loc = CGPoint(x: 1100, y: 50)
        var pos: [CursorPacket] = []
        let t = makeTracker(s, { pos.append($0) }, { _ in })
        s.visible = false
        t.tick(nowMicros: 0)
        XCTAssertEqual(pos.count, 1); XCTAssertFalse(pos[0].visible)
        s.bounds = nil
        t.tick(nowMicros: 1_000_000)
        XCTAssertEqual(pos.count, 1, "no virtual display: nothing sent")
    }
}
