import AppKit
import CoreVideo
import MSCore
import XCTest
@testable import MSHost

@available(macOS 12.3, *)
final class ScreenCapturerTests: XCTestCase {
    private struct Frame { var w: Int; var h: Int; var fmt: OSType; var surface: Bool; var t: UInt64; var deliveredAt: UInt64 }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Frame] = []
        func add(_ f: Frame) { lock.lock(); frames.append(f); lock.unlock() }
        func take() -> [Frame] { lock.lock(); defer { lock.unlock() }; let r = frames; frames = []; return r }
        var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    }

    private func requirePermission() throws {
        if !ScreenCapturePermission.isGranted {
            throw XCTSkip("Screen Recording permission not granted to the test host")
        }
    }

    private func makeCapturer(_ box: Box, w: Int = 1280, h: Int = 720) -> ScreenCapturer {
        ScreenCapturer(config: .init(displayID: CGMainDisplayID(), pixelWidth: w, pixelHeight: h,
                                     fps: 60, showsCursor: false)) { pb, t in
            box.add(Frame(w: CVPixelBufferGetWidth(pb), h: CVPixelBufferGetHeight(pb),
                          fmt: CVPixelBufferGetPixelFormatType(pb),
                          surface: CVPixelBufferGetIOSurface(pb) != nil,
                          t: t, deliveredAt: MonoClock.nowMicros()))
        }
    }

    /// Opens a floating window whose colour changes every 16 ms and spins the run loop.
    @MainActor private func spinWithActivity(_ seconds: TimeInterval) -> NSWindow {
        _ = NSApplication.shared
        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 200),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.orderFrontRegardless()
        var hue: CGFloat = 0
        let timer = Timer(timeInterval: 0.016, repeats: true) { _ in
            hue = hue + 0.07 > 1 ? 0 : hue + 0.07
            win.backgroundColor = NSColor(calibratedHue: hue, saturation: 1, brightness: 1, alpha: 1)
            win.displayIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        timer.invalidate()
        return win
    }

    @MainActor func testCapturesFramesFromMainDisplay() async throws {
        try requirePermission()
        let box = Box()
        let cap = makeCapturer(box)
        try await cap.start()
        XCTAssertTrue(cap.isRunning)
        let win = spinWithActivity(2.0)
        defer { win.close() }
        await cap.stop()
        XCTAssertFalse(cap.isRunning)

        let frames = box.take()
        print("ScreenCapturerTests: delivered \(frames.count) frames in ~2 s; counters=\(cap.counters)")
        XCTAssertGreaterThanOrEqual(frames.count, 30)
        // Upper bound: 60 fps + 10 % over a ~2 s window (plus start/stop slack of 0.25 s).
        XCTAssertLessThanOrEqual(Double(frames.count), 66.0 * 2.25)
        var prev: UInt64 = 0
        for f in frames {
            XCTAssertEqual(f.w, 1280); XCTAssertEqual(f.h, 720)
            XCTAssertEqual(f.fmt, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            XCTAssertTrue(f.surface)
            XCTAssertGreaterThan(f.t, prev)
            prev = f.t
            let diff = f.deliveredAt >= f.t ? f.deliveredAt - f.t : f.t - f.deliveredAt
            XCTAssertLessThan(diff, 200_000)
        }
        XCTAssertEqual(cap.counters.framesDelivered, UInt64(frames.count))
    }

    @MainActor func testUpdateChangesBufferSize() async throws {
        try requirePermission()
        let box = Box()
        let cap = makeCapturer(box)
        try await cap.start()
        let win = spinWithActivity(0.5)
        defer { win.close() }
        _ = box.take()
        let c = ScreenCapturer.Config(displayID: CGMainDisplayID(), pixelWidth: 640, pixelHeight: 360,
                                      fps: 60, showsCursor: false)
        try await cap.update(c)
        _ = spinWithActivity(0.5)       // let in-flight old-size frames drain
        _ = box.take()
        _ = spinWithActivity(1.0)
        let frames = box.take()
        await cap.stop()
        print("ScreenCapturerTests: after update \(frames.count) frames")
        XCTAssertGreaterThan(frames.count, 5)
        for f in frames { XCTAssertEqual(f.w, 640); XCTAssertEqual(f.h, 360) }
    }

    @MainActor func testStopTwiceAndRestart() async throws {
        try requirePermission()
        let box = Box()
        let cap = makeCapturer(box)
        try await cap.start()
        let win = spinWithActivity(0.5)
        defer { win.close() }
        await cap.stop()
        await cap.stop()
        XCTAssertFalse(cap.isRunning)
        _ = box.take()
        try await cap.start()
        XCTAssertTrue(cap.isRunning)
        _ = spinWithActivity(0.7)
        await cap.stop()
        XCTAssertGreaterThan(box.take().count, 0)
        let c = cap.counters
        XCTAssertEqual(c.framesDelivered > 0, true)
    }

    func testDisplayNotFound() async throws {
        try requirePermission()
        let cap = ScreenCapturer(config: .init(displayID: 0xDEADBEEF, pixelWidth: 640, pixelHeight: 360,
                                               fps: 60, showsCursor: false)) { _, _ in }
        do {
            try await cap.start()
            XCTFail("expected displayNotFound")
        } catch ScreenCapturer.CaptureError.displayNotFound(let id) {
            XCTAssertEqual(id, 0xDEADBEEF)
        }
        XCTAssertFalse(cap.isRunning)
    }

    func testSettingsURLNonNil() {
        XCTAssertNotNil(ScreenCapturePermission.settingsURL)
    }
}
