import XCTest
import MSCore
import MSCodec
import MSProtocol
@testable import MSHost

final class SettingsFormatTests: XCTestCase {
    private func caps(w: Int = 5120, h: Int = 2880, hz: Double = 60, hevc: Bool = true) -> CapabilitiesMessage {
        CapabilitiesMessage(role: "display", deviceName: "d", osVersion: "x", panelPixelWidth: w, panelPixelHeight: h,
                            panelWidthMM: 600, panelHeightMM: 340, backingScale: 2, edrHeadroom: 1, refreshHz: hz,
                            hwDecodeH264: true, hwDecodeHEVC: hevc, hwEncodeH264: true, hwEncodeHEVC: true,
                            wideColor: false)
    }

    func testDefaultsAre4KHEVC60() {
        let f = HostSessionConfig.format(for: caps(w: 3840, h: 2160), settings: AppSettings())
        XCTAssertEqual(f, VideoFormat(codec: .hevc, width: 3840, height: 2160, fps: 60, bitDepth: 8))
        // A 5K panel is still encoded at 4K by default (G1); 5K only when the user picks native.
        let k = HostSessionConfig.format(for: caps(), settings: AppSettings())
        XCTAssertEqual(k, VideoFormat(codec: .hevc, width: 3840, height: 2160, fps: 60, bitDepth: 8))
        XCTAssertEqual(HostSessionConfig.defaultFormat(caps()), k)
        var s = AppSettings(); s.maxHeight = 0
        let n = HostSessionConfig.format(for: caps(), settings: s)
        XCTAssertEqual(n.width, 5120); XCTAssertEqual(n.height, 2880)
    }

    func testMaxHeightScalesKeepingAspect() {
        var s = AppSettings(); s.maxHeight = 1080
        let f = HostSessionConfig.format(for: caps(w: 3840, h: 2160), settings: s)
        XCTAssertEqual(f.width, 1920); XCTAssertEqual(f.height, 1080)
    }

    func testNeverExceedsPanelOrRefresh() {
        var s = AppSettings(); s.maxHeight = 2160; s.fps = 60
        let f = HostSessionConfig.format(for: caps(w: 1920, h: 1080, hz: 30), settings: s)
        XCTAssertEqual(f.height, 1080); XCTAssertEqual(f.fps, 30)
    }

    func testCodecFallbackAndH264Limit() {
        var s = AppSettings(); s.codec = "hevc"
        XCTAssertEqual(HostSessionConfig.format(for: caps(hevc: false), settings: s).codec, .h264)
        s.codec = "h264"
        s.maxHeight = 0
        let f = HostSessionConfig.format(for: caps(w: 5120, h: 2880, hevc: false), settings: s)
        XCTAssertEqual(f.codec, .h264)
        XCTAssertLessThanOrEqual(f.width, 4096); XCTAssertLessThanOrEqual(f.height, 2304)
    }

    func testConfigFromSettings() {
        var s = AppSettings(); s.bitrateCapMbps = 20; s.cursorMode = "overlay"
        let c = HostSessionConfig(settings: s)
        XCTAssertEqual(c.maxBitrate, 20_000_000); XCTAssertEqual(c.cursorMode, "overlay")
    }
}
