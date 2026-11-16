import XCTest
import CoreVideo
import CoreMedia
import CoreGraphics
@testable import MSCodec

final class ColourPlanTests: XCTestCase {
    func testSRGBPlan() {
        let p = ColourPlan(panelIsP3: false)
        XCTAssertEqual(p, .srgb)
        XCTAssertEqual(p.captureColourSpaceName as String, CGColorSpace.sRGB as String)
        XCTAssertEqual(p.layerColourSpaceName as String, CGColorSpace.sRGB as String)
        XCTAssertEqual(p.vuiPrimaries as String, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        XCTAssertEqual(p.vuiTransfer as String, kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        XCTAssertEqual(p.redPrimary, CGPoint(x: 0.64, y: 0.33))
        XCTAssertEqual(p.greenPrimary, CGPoint(x: 0.30, y: 0.60))
        XCTAssertEqual(p.bluePrimary, CGPoint(x: 0.15, y: 0.06))
    }

    func testP3Plan() {
        let p = ColourPlan(panelIsP3: true)
        XCTAssertEqual(p, .displayP3)
        XCTAssertEqual(p.captureColourSpaceName as String, CGColorSpace.displayP3 as String)
        XCTAssertEqual(p.layerColourSpaceName as String, CGColorSpace.displayP3 as String)
        XCTAssertEqual(p.vuiPrimaries as String, kCMFormatDescriptionColorPrimaries_P3_D65 as String)
        XCTAssertEqual(p.vuiTransfer as String, kCMFormatDescriptionTransferFunction_sRGB as String)
        XCTAssertEqual(p.vuiMatrix as String, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        XCTAssertEqual(p.redPrimary, CGPoint(x: 0.680, y: 0.320))
        XCTAssertEqual(p.greenPrimary, CGPoint(x: 0.265, y: 0.690))
        XCTAssertEqual(p.bluePrimary, CGPoint(x: 0.150, y: 0.060))
        XCTAssertEqual(p.whitePoint, CGPoint(x: 0.3127, y: 0.3290))
    }

    // MARK: codec roundtrip

    private final class Box<T> {
        private let lock = NSLock()
        private var items: [T] = []
        func add(_ t: T) { lock.lock(); items.append(t); lock.unlock() }
        var snapshot: [T] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// Flat NV12 frame with fixed Y/Cb/Cr, tagged with the plan's colour attachments.
    private func makeTagged(_ w: Int, _ h: Int, y: UInt8, cb: UInt8, cr: UInt8, plan: ColourPlan) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        XCTAssertEqual(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           attrs as CFDictionary, &pb), kCVReturnSuccess)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let ys = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let yb = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!
        for r in 0..<h { memset(yb.advanced(by: r * ys), Int32(y), w) }
        let cs = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        let cbase = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!.assumingMemoryBound(to: UInt8.self)
        for r in 0..<(h / 2) {
            for x in 0..<(w / 2) { cbase[r * cs + 2 * x] = cb; cbase[r * cs + 2 * x + 1] = cr }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, plan.vuiPrimaries, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, plan.vuiTransfer, .shouldPropagate)
        CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, plan.vuiMatrix, .shouldPropagate)
        return buf
    }

    private func roundTrip(_ codec: Codec) throws {
        let (w, h) = (640, 360)
        let plan = ColourPlan.displayP3
        let fmt = VideoFormat(codec: codec, width: w, height: h, fps: 60, bitDepth: 8)
        let count = 8
        let encExp = expectation(description: "encode")
        encExp.expectedFulfillmentCount = count
        let encoded = Box<EncodedFrame>()
        let enc = try VideoEncoder(format: fmt, bitrate: 8_000_000, colour: plan) { f in
            encoded.add(f); encExp.fulfill()
        }
        defer { enc.invalidate() }
        for i in 0..<count {
            enc.encode(makeTagged(w, h, y: 110, cb: 90, cr: 170, plan: plan),
                       captureTimeMicros: UInt64(1_000_000 + i * 16_667))
        }
        wait(for: [encExp], timeout: 10)

        let decExp = expectation(description: "decode")
        decExp.expectedFulfillmentCount = count
        let out = Box<CVPixelBuffer>()
        let dec = VideoDecoder(codec: codec) { pb, _, _ in out.add(pb); decExp.fulfill() }
        defer { dec.invalidate() }
        for f in encoded.snapshot { try dec.decode(f) }
        wait(for: [decExp], timeout: 10)

        let pb = try XCTUnwrap(out.snapshot.last)
        func att(_ k: CFString) -> String? { CVBufferCopyAttachment(pb, k, nil) as? String }
        XCTAssertEqual(att(kCVImageBufferColorPrimariesKey), plan.vuiPrimaries as String)
        XCTAssertEqual(att(kCVImageBufferTransferFunctionKey), plan.vuiTransfer as String)
        XCTAssertEqual(att(kCVImageBufferYCbCrMatrixKey), plan.vuiMatrix as String)

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        for (x, yy) in [(10, 10), (320, 180), (600, 340)] {
            XCTAssertEqual(Double(yp[yy * ys + x]), 110, accuracy: 3)
            XCTAssertEqual(Double(cp[(yy / 2) * cs + 2 * (x / 2)]), 90, accuracy: 3)
            XCTAssertEqual(Double(cp[(yy / 2) * cs + 2 * (x / 2) + 1]), 170, accuracy: 3)
        }
    }

    func testP3RoundTripHEVC() throws { try roundTrip(.hevc) }
    func testP3RoundTripH264() throws { try roundTrip(.h264) }
}
