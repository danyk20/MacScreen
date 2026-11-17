import XCTest
import MSCore
import MSCodec
import MSProtocol
import MSProbe
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

    // Provisional decision P1.
    private func outcome(throughput: Int, date: Date = Date()) -> ProbeOutcome {
        let link = LinkResult(trains: [LinkTrainResult(rateBps: 10_000_000, sent: 100, received: 100, jitterMs: 1),
                                       LinkTrainResult(rateBps: 40_000_000, sent: 100, received: 100, jitterMs: 1,
                                                       deliveryBps: throughput)])
        let o = ProbeOutcome(displayId: "d", displayName: "d", interface: .wifi, panelWidth: 5120, panelHeight: 2880,
                             date: date, link: link, outcomes: [],
                             recommendation: ProfileRecommender.recommend(outcomes: [], link: link, interface: .wifi))
        var out = HostSessionConfig.linkOnlyOutcome(o, hevc: true)
        out.networkId = "gw-a"
        return out
    }

    func testLinkAwareDefaultAndUserOverride() {
        let o = outcome(throughput: 25_000_000)
        var cfg = HostSessionConfig(settings: AppSettings())
        cfg.applyLink(o, settings: AppSettings())
        XCTAssertEqual(cfg.chooseFormat(caps()), VideoFormat(codec: .hevc, width: 3200, height: 1800, fps: 60, bitDepth: 8))
        XCTAssertEqual(cfg.linkThroughputBps, 25_000_000)
        XCTAssertEqual(cfg.fecRatio, MSConstants.fecRatioWiFi)
        // The user picked 1080p: their format wins, the link cap still applies.
        var s = AppSettings(); s.maxHeight = 1080
        var u = HostSessionConfig(settings: s)
        u.applyLink(o, settings: s)
        XCTAssertEqual(u.chooseFormat(caps()).height, 1080)
        XCTAssertEqual(u.linkThroughputBps, 25_000_000)
        // A user bitrate cap disables the link cap.
        s = AppSettings(); s.bitrateCapMbps = 20
        var b = HostSessionConfig(settings: s)
        b.applyLink(o, settings: s)
        XCTAssertNil(b.linkThroughputBps)
        XCTAssertEqual(b.maxBitrate, 20_000_000)
    }

    func testLinkCacheFreshness() {
        XCTAssertTrue(HostSessionConfig.isFresh(outcome(throughput: 18_000_000), networkId: "gw-a"))
        XCTAssertFalse(HostSessionConfig.isFresh(outcome(throughput: 18_000_000), networkId: "gw-b"))
        XCTAssertFalse(HostSessionConfig.isFresh(outcome(throughput: 18_000_000), networkId: nil))
        XCTAssertFalse(HostSessionConfig.isFresh(outcome(throughput: 18_000_000, date: Date().addingTimeInterval(-8 * 86400)),
                                                 networkId: "gw-a"))
        let run = HostSessionConfig.linkCheckRun()
        XCTAssertEqual(run.candidates?.count, 0)
        XCTAssertTrue(run.stopWhenSaturated)
    }

    func testMeasurementAlwaysWinsCacheOnlyFallback() {
        let cached = outcome(throughput: 40_000_000)      // gw-a, 4K-capable
        let fresh = outcome(throughput: 18_000_000)
        // A measurement exists: it is used even though a fresh cache entry exists.
        var r = HostSessionConfig.resolveLink(measured: fresh, cached: cached, networkId: "gw-a")
        XCTAssertFalse(r.fallback)
        XCTAssertEqual(r.outcome?.link.usableThroughputBps, 18_000_000)
        // Measurement failed: the cache of the same network, scaled down, marked as fallback.
        r = HostSessionConfig.resolveLink(measured: nil, cached: cached, networkId: "gw-a")
        XCTAssertTrue(r.fallback)
        XCTAssertEqual(r.outcome?.link.usableThroughputBps, 30_000_000)
        XCTAssertEqual(r.outcome?.recommendation.candidate?.format.width, 3200)
        // Another network, or no cache: G1 defaults.
        r = HostSessionConfig.resolveLink(measured: nil, cached: cached, networkId: "gw-b")
        XCTAssertNil(r.outcome)
        XCTAssertNil(HostSessionConfig.resolveLink(measured: nil, cached: nil, networkId: "gw-a").outcome)
        // The link check uses short ascending trains with early stop.
        let run = HostSessionConfig.linkCheckRun()
        XCTAssertEqual(run.trainDurationMs, 250)
        XCTAssertEqual(run.trainRatesBps.first, 10_000_000)
    }
}
