import XCTest
@testable import MSCore

final class ByteCodingTests: XCTestCase {
    func testKnownBytes() {
        var w = ByteWriter(capacity: 16)
        w.u32(0x01020304)
        XCTAssertEqual(Array(w.data), [1, 2, 3, 4])
        var w2 = ByteWriter()
        w2.u16(0xABCD)
        w2.u64(0x0102030405060708)
        XCTAssertEqual(Array(w2.data), [0xAB, 0xCD, 1, 2, 3, 4, 5, 6, 7, 8])
        var w3 = ByteWriter()
        w3.f32(1.0)
        XCTAssertEqual(Array(w3.data), [0x3F, 0x80, 0, 0])
    }

    func testRoundTripAllTypes() throws {
        var w = ByteWriter()
        w.u8(0); w.u8(255)
        w.u16(0); w.u16(.max)
        w.u32(0); w.u32(.max); w.u32(0x80000000)
        w.u64(0); w.u64(.max); w.u64(0x8000000000000000)
        w.f32(3.5); w.f32(-0.25); w.f32(.infinity)
        w.bytes(Data([9, 8, 7]))
        w.zeros(3)
        w.zeros(0)
        XCTAssertEqual(w.count, 2 + 4 + 12 + 24 + 12 + 3 + 3)
        var r = ByteReader(w.data)
        XCTAssertEqual(try r.u8(), 0); XCTAssertEqual(try r.u8(), 255)
        XCTAssertEqual(try r.u16(), 0); XCTAssertEqual(try r.u16(), .max)
        XCTAssertEqual(try r.u32(), 0); XCTAssertEqual(try r.u32(), .max); XCTAssertEqual(try r.u32(), 0x80000000)
        XCTAssertEqual(try r.u64(), 0); XCTAssertEqual(try r.u64(), .max); XCTAssertEqual(try r.u64(), 0x8000000000000000)
        XCTAssertEqual(try r.f32(), 3.5); XCTAssertEqual(try r.f32(), -0.25); XCTAssertEqual(try r.f32(), .infinity)
        XCTAssertEqual(try r.bytes(3), Data([9, 8, 7]))
        XCTAssertEqual(try r.bytes(3), Data([0, 0, 0]))
        XCTAssertEqual(r.remaining, 0)
        XCTAssertEqual(r.rest(), Data())
    }

    func testF32NaNBitPattern() throws {
        let nan = Float(bitPattern: 0x7FC12345)
        var w = ByteWriter()
        w.f32(nan)
        XCTAssertEqual(Array(w.data), [0x7F, 0xC1, 0x23, 0x45])
        var r = ByteReader(w.data)
        let back = try r.f32()
        XCTAssertTrue(back.isNaN)
        XCTAssertEqual(back.bitPattern, 0x7FC12345)
    }

    func testUnderflowEveryMethod() {
        let e = Data([1])
        var r = ByteReader(e)
        XCTAssertThrowsError(try r.u16()) { XCTAssertEqual($0 as? ByteReaderError, .underflow(needed: 2, remaining: 1)) }
        XCTAssertThrowsError(try r.u32()) { XCTAssertEqual($0 as? ByteReaderError, .underflow(needed: 4, remaining: 1)) }
        XCTAssertThrowsError(try r.u64()) { XCTAssertEqual($0 as? ByteReaderError, .underflow(needed: 8, remaining: 1)) }
        XCTAssertThrowsError(try r.f32())
        XCTAssertThrowsError(try r.bytes(2))
        XCTAssertThrowsError(try r.skip(2))
        XCTAssertThrowsError(try r.bytes(-1)) { XCTAssertEqual($0 as? ByteReaderError, .underflow(needed: -1, remaining: 1)) }
        XCTAssertThrowsError(try r.skip(-1))
        XCTAssertEqual(r.remaining, 1)
        XCTAssertEqual(try r.u8(), 1)
        XCTAssertThrowsError(try r.u8()) { XCTAssertEqual($0 as? ByteReaderError, .underflow(needed: 1, remaining: 0)) }
    }

    func testSliceWithNonZeroStartIndex() throws {
        let base = Data([0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        let slice = base[2...]
        XCTAssertEqual(slice.startIndex, 2)
        var r = ByteReader(slice)
        XCTAssertEqual(r.remaining, 6)
        XCTAssertEqual(try r.u32(), 0x01020304)
        try r.skip(1)
        XCTAssertEqual(try r.u8(), 6)
        XCTAssertEqual(r.remaining, 0)
        var r2 = ByteReader(slice)
        XCTAssertEqual(try r2.u16(), 0x0102)
        XCTAssertEqual(r2.rest(), Data([3, 4, 5, 6]))
        var r3 = ByteReader(slice)
        XCTAssertEqual(try r3.bytes(2), Data([1, 2]))
        XCTAssertEqual(try r3.u64OrNil(), nil)
    }
}

private extension ByteReader {
    mutating func u64OrNil() throws -> UInt64? { try? u64() }
}
