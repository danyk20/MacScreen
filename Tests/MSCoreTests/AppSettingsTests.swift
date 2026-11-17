import XCTest
@testable import MSCore

final class AppSettingsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ms.test.\(UUID().uuidString)")!
    }

    func testDefaults() {
        let s = AppSettings.load(from: freshDefaults())
        XCTAssertEqual(s, AppSettings())
        XCTAssertEqual(s.fps, 60); XCTAssertEqual(s.codec, "hevc"); XCTAssertEqual(s.maxHeight, 2160)
        XCTAssertFalse(s.hdr); XCTAssertEqual(s.cursorMode, "embedded")
    }

    func testRoundTrip() {
        let d = freshDefaults()
        var s = AppSettings()
        s.maxHeight = 1080; s.fps = 30; s.codec = "h264"; s.bitrateCapMbps = 40
        s.cursorMode = "overlay"; s.statsOverlay = true; s.launchAtLogin = true
        s.save(to: d)
        XCTAssertEqual(AppSettings.load(from: d), s)
    }

    func testSanitizesInvalidValues() {
        var s = AppSettings()
        s.fps = 17; s.codec = "vp9"; s.cursorMode = "x"; s.hdr = true; s.bitrateCapMbps = -5
        let c = s.sanitized()
        XCTAssertEqual(c.fps, 60); XCTAssertEqual(c.codec, "hevc"); XCTAssertEqual(c.cursorMode, "embedded")
        XCTAssertFalse(c.hdr); XCTAssertEqual(c.bitrateCapMbps, 0)
    }
}
