import XCTest
import CoreVideo
@testable import MSProbe

final class TestPatternTests: XCTestCase {
    private func planeBytes(_ pb: CVPixelBuffer, plane: Int, sampleBytes: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, plane) * sampleBytes * (plane == 1 ? 2 : 1)
        let h = CVPixelBufferGetHeightOfPlane(pb, plane)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { return [] }
        var out: [UInt8] = []
        for y in 0..<h {
            out.append(contentsOf: UnsafeBufferPointer(start: (base + y * stride).assumingMemoryBound(to: UInt8.self), count: w))
        }
        return out
    }

    func testDeterministicAndDistinct() throws {
        let p = try TestPattern(width: 640, height: 360)
        let a = try p.frame(3)
        let aLuma = planeBytes(a, plane: 0, sampleBytes: 1)
        let aChroma = planeBytes(a, plane: 1, sampleBytes: 1)
        let b = try p.frame(3)
        XCTAssertEqual(aLuma, planeBytes(b, plane: 0, sampleBytes: 1))
        XCTAssertEqual(aChroma, planeBytes(b, plane: 1, sampleBytes: 1))
        let c = try p.frame(4)
        XCTAssertNotEqual(aLuma, planeBytes(c, plane: 0, sampleBytes: 1))
        XCTAssertEqual(Set(aChroma).count, 3)
    }

    func testBufferProperties() throws {
        let p = try TestPattern(width: 640, height: 360)
        let pb = try p.frame(0)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(pb))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(CVPixelBufferGetWidth(pb), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(pb), 360)
    }

    func testOddishSize() throws {
        let p = try TestPattern(width: 1282, height: 722)
        let pb = try p.frame(5)
        XCTAssertEqual(CVPixelBufferGetWidth(pb), 1282)
        XCTAssertEqual(CVPixelBufferGetHeight(pb), 722)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(pb))
    }

    func testTenBit() throws {
        let p = try TestPattern(width: 640, height: 360, bitDepth: 10)
        let pb = try p.frame(2)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(pb))
        let l = planeBytes(pb, plane: 0, sampleBytes: 2)
        XCTAssertEqual(l, planeBytes(try p.frame(2), plane: 0, sampleBytes: 2))
        XCTAssertNotEqual(l, planeBytes(try p.frame(3), plane: 0, sampleBytes: 2))
    }
}
