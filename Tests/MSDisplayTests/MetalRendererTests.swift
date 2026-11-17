import XCTest
import AppKit
import Metal
import QuartzCore
import CoreVideo
import MSCore
import MSProbe
@testable import MSDisplay

final class MetalRendererTests: XCTestCase {
    // MARK: helpers

    private func makeBuffer(width: Int, height: Int, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &pb), kCVReturnSuccess)
        return try XCTUnwrap(pb)
    }

    private func ycbcr(_ r: Double, _ g: Double, _ b: Double) -> (UInt8, UInt8, UInt8) {
        let yp = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let y = 16 + 219 * yp
        let cb = 128 + 224 * (b - yp) / 1.8556
        let cr = 128 + 224 * (r - yp) / 1.5748
        func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        return (q(y), q(cb), q(cr))
    }

    /// Fills an 8-bit NV12 buffer; `pick(x, y)` returns (Y, Cb, Cr) for luma coordinates.
    private func fill8(_ pb: CVPixelBuffer, _ pick: (Int, Int) -> (UInt8, UInt8, UInt8)) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { row[x] = pick(x, y).0 }
            }
        }
        if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            for y in 0..<(h / 2) {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<(w / 2) {
                    let p = pick(x * 2, y * 2)
                    row[2 * x] = p.1
                    row[2 * x + 1] = p.2
                }
            }
        }
    }

    private func solid(_ r: Double, _ g: Double, _ b: Double, size: Int = 256) throws -> CVPixelBuffer {
        let pb = try makeBuffer(width: size, height: size)
        let c = ycbcr(r, g, b)
        fill8(pb) { _, _ in c }
        return pb
    }

    /// Returns (B, G, R, A) at the point.
    private func pixel(_ t: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        t.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return px
    }

    private func makeRenderer() throws -> MetalRenderer {
        do { return try MetalRenderer() } catch RendererError.noDevice {
            throw XCTSkip("No Metal device available")
        }
    }

    // MARK: tests

    func testSolidColours() throws {
        let r = try makeRenderer()
        let cases: [(String, Double, Double, Double)] = [
            ("white", 1, 1, 1), ("black", 0, 0, 0), ("grey", 0.5, 0.5, 0.5),
            ("red", 1, 0, 0), ("green", 0, 1, 0), ("blue", 0, 0, 1), ("yellow", 1, 1, 0),
        ]
        for (name, cr, cg, cb) in cases {
            let tex = try r.renderOffscreen(try solid(cr, cg, cb), width: 256, height: 256)
            let p = pixel(tex, 128, 128)
            let exp = [cr, cg, cb].map { Int(($0 * 255).rounded()) }
            XCTAssertEqual(Int(p[2]), exp[0], accuracy: 2, "\(name) R")
            XCTAssertEqual(Int(p[1]), exp[1], accuracy: 2, "\(name) G")
            XCTAssertEqual(Int(p[0]), exp[2], accuracy: 2, "\(name) B")
            XCTAssertEqual(p[3], 255)
        }
    }

    func testGeometryNoMirrorNoFlip() throws {
        let r = try makeRenderer()
        let black: (UInt8, UInt8, UInt8) = (16, 128, 128), white: (UInt8, UInt8, UInt8) = (235, 128, 128)
        let lr = try makeBuffer(width: 256, height: 256)
        fill8(lr) { x, _ in x < 128 ? black : white }
        var t = try r.renderOffscreen(lr, width: 256, height: 256)
        XCTAssertLessThan(pixel(t, 64, 128)[0], 10)
        XCTAssertGreaterThan(pixel(t, 192, 128)[0], 245)
        let tb = try makeBuffer(width: 256, height: 256)
        fill8(tb) { _, y in y < 128 ? black : white }
        t = try r.renderOffscreen(tb, width: 256, height: 256)
        XCTAssertLessThan(pixel(t, 128, 64)[0], 10)
        XCTAssertGreaterThan(pixel(t, 128, 192)[0], 245)
    }

    func testScaling() throws {
        let r = try makeRenderer()
        let pattern = try TestPattern(width: 640, height: 360)
        let frame = try pattern.frame(0)
        for (w, h) in [(1280, 720), (320, 180)] {
            let t = try r.renderOffscreen(frame, width: w, height: h)
            var seen = Set<[UInt8]>()
            for i in 0..<16 { seen.insert(pixel(t, (w - 1) * i / 15, (h - 1) * (i * 7 % 16) / 15)) }
            XCTAssertGreaterThan(seen.count, 1, "uniform output at \(w)x\(h)")
        }
    }

    func testTenBitGrey() throws {
        let r = try makeRenderer()
        let pb = try makeBuffer(width: 64, height: 64, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        CVPixelBufferLockBaseAddress(pb, [])
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { continue }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            let rows = CVPixelBufferGetHeightOfPlane(pb, plane)
            let cols = CVPixelBufferGetWidthOfPlane(pb, plane) * (plane == 0 ? 1 : 2)
            for y in 0..<rows {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<cols { row[x] = UInt16(plane == 0 ? 502 : 512) << 6 }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let t = try r.renderOffscreen(pb, width: 64, height: 64)
        let p = pixel(t, 32, 32)
        for i in 0..<3 { XCTAssertTrue((126...130).contains(Int(p[i])), "channel \(i) = \(p[i])") }
    }

    func testUnsupportedFormat() throws {
        let r = try makeRenderer()
        let pb = try makeBuffer(width: 64, height: 64, format: kCVPixelFormatType_32BGRA)
        XCTAssertThrowsError(try r.renderOffscreen(pb, width: 64, height: 64)) { e in
            guard case RendererError.unsupportedPixelFormat = e else { return XCTFail("wrong error \(e)") }
        }
    }

    func testAsyncPath() throws {
        let r = try makeRenderer()
        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        // Host the layer in an offscreen window so it can vend drawables.
        let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 360),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        v.wantsLayer = true
        v.layer?.addSublayer(layer)
        win.contentView = v
        r.attach(layer: layer, drawableSize: CGSize(width: 640, height: 360))

        let presented = expectation(description: "presented")
        presented.assertForOverFulfill = false
        r.onPresented = { _, _ in presented.fulfill() }

        let pattern = try TestPattern(width: 640, height: 360)
        let frame = try pattern.frame(0)
        for _ in 0..<120 {
            r.submit(frame, captureTimeMicros: MonoClock.nowMicros())
            Thread.sleep(forTimeInterval: 1.0 / 60.0)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let c = r.counters
            if c.framesDrawn + c.framesSkipped + c.drawFailures == c.framesSubmitted { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let c = r.counters
        XCTAssertEqual(c.framesSubmitted, 120)
        XCTAssertEqual(c.framesDrawn + c.framesSkipped + c.drawFailures, c.framesSubmitted)
        if c.framesDrawn == 0 {
            throw XCTSkip("Layer could not vend drawables off-screen (drawFailures=\(c.drawFailures))")
        }
        XCTAssertEqual(c.drawFailures, 0)
        wait(for: [presented], timeout: 2)
        win.close()
    }

    func testDisplayWindow() throws {
        try XCTSkipUnless(Thread.isMainThread)
        _ = NSApplication.shared
        let w = DisplayWindow(windowed: true)
        XCTAssertGreaterThan(w.drawablePixelSize.width, 0)
        XCTAssertGreaterThan(w.drawablePixelSize.height, 0)
        w.show()
        XCTAssertTrue(w.isVisible)
        w.showMessage("Waiting for host")
        w.showMessage(nil)
        w.hide()
        XCTAssertFalse(w.isVisible)
    }
}

/// Regression: the full-screen Display window sits above `.modalPanel`, which hid the pairing
/// "Allow?" alert behind a black screen, so pairing never completed.
final class DisplayWindowDialogTests: XCTestCase {
    func testDialogRunsBelowModalPanelAndRestoresLevel() {
        _ = NSApplication.shared
        let w = DisplayWindow(windowed: false)
        let fullScreen = w.level
        XCTAssertGreaterThan(fullScreen.rawValue, NSWindow.Level.modalPanel.rawValue)
        let inside = w.runningDialog { w.level }
        XCTAssertLessThan(inside.rawValue, NSWindow.Level.modalPanel.rawValue)
        XCTAssertEqual(w.level, fullScreen)
    }
}
