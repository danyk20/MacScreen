import XCTest
import Network
import CoreVideo
import MSCore
import MSCodec
import MSProtocol
import MSProbe
import MSHost
import MSDisplay

private final class Box<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}

private final class ProbeTestSink: DisplaySink {
    var onCode: ((String) -> Void)?
    let frames = Box(0)
    func present(_ pixelBuffer: CVPixelBuffer, captureTimeMicros: UInt64) { frames.set(frames.get() + 1) }
    func showPairingCode(_ code: String, hostName: String) { onCode?(code) }
    func hidePairingCode() {}
    func askAllow(hostName: String, completion: @escaping (Bool) -> Void) { completion(true) }
    func sessionStarted(hostName: String) {}
    func sessionEnded() {}
}

private final class NeverSource: FrameSource {
    struct Unused: Error {}
    func start(format: VideoFormat, hiDPI: Bool, display: CapabilitiesMessage,
               onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) async throws { throw Unused() }
    func stop() async {}
}

final class ProbeLoopbackTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func makeStore(_ name: String) throws -> IdentityStore {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ms-probe-\(UUID().uuidString)")
        dirs.append(d)
        return try IdentityStore(directory: d, defaultDeviceName: name)
    }

    private func caps(role: String) -> CapabilitiesMessage {
        CapabilitiesMessage(role: role, deviceName: role, osVersion: "test", panelPixelWidth: 1280,
                            panelPixelHeight: 720, panelWidthMM: 600, panelHeightMM: 340, backingScale: 2,
                            edrHeadroom: 1, refreshHz: 60, hwDecodeH264: true, hwDecodeHEVC: true,
                            hwEncodeH264: true, hwEncodeHEVC: true, wideColor: false)
    }

    func testProbeOverLocalhost() throws {
        let sink = ProbeTestSink()
        let display = DisplaySession(identityStore: try makeStore("Display"), capabilities: caps(role: "display"), sink: sink)
        try display.start()
        defer { display.stop() }
        let end = Date().addingTimeInterval(10)
        while display.port == nil && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        let port = try XCTUnwrap(display.port)

        func fmt(_ c: Codec, _ w: Int, _ h: Int, fps: Int) -> Candidate {
            Candidate(format: VideoFormat(codec: c, width: w, height: h, fps: fps, bitDepth: 8), hiDPI: true,
                      bitrate: 2_000_000)
        }
        var run = ProbeRunConfig()
        run.candidates = [fmt(.hevc, 640, 360, fps: 30), fmt(.h264, 640, 360, fps: 30)]
        run.encodeFrames = 30
        run.trainRatesBps = [10_000_000, 20_000_000]
        run.trainDurationMs = 200
        let progress = Box<[Double]>([])
        run.onProgress = { p in progress.set(progress.get() + [p.fraction]) }
        let finished = Box<Result<ProbeOutcome, ProbeFailure>?>(nil)
        run.onFinished = { finished.set($0) }

        var cfg = HostSessionConfig()
        cfg.probe = run
        let h = HostSession(identityStore: try makeStore("Host"), capabilities: caps(role: "host"),
                            config: cfg, makeSource: { _ in NeverSource() })
        sink.onCode = { h.submitPairingCode($0) }
        h.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))

        let deadline = Date().addingTimeInterval(60)
        while finished.get() == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let result = try XCTUnwrap(finished.get(), "probe did not finish")
        let outcome = try result.get()

        XCTAssertEqual(outcome.link.trains.count, 2)
        XCTAssertGreaterThan(outcome.link.usableThroughputBps, 0, "loopback must carry 10 Mbit/s")
        XCTAssertEqual(outcome.link.trains[0].sent, LinkProbe.packetCount(rateBps: 10_000_000, durationMs: 200))
        XCTAssertFalse(outcome.outcomes.isEmpty)
        let first = outcome.outcomes[0]
        XCTAssertNotNil(first.encode)
        XCTAssertNotNil(first.decode, "the Display must answer the probeBlob")
        XCTAssertEqual(first.decode?.frames, 30)
        XCTAssertEqual(first.decode?.outputWidth, 640)
        XCTAssertNotNil(outcome.recommendation.candidate, "rejections: \(outcome.recommendation.rejections)")
        XCTAssertEqual(outcome.recommendation.candidate, run.candidates?.first)
        XCTAssertEqual(outcome.displayName, "display")
        XCTAssertEqual(sink.frames.get(), 0, "the probe must not stream video")
        XCTAssertTrue(progress.get().contains { $0 >= 1 })
        XCTAssertEqual(progress.get(), progress.get().sorted())

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ms-probe-it-\(UUID().uuidString)"))
        ProbeCache.store(outcome, in: defaults)
        XCTAssertNotNil(ProbeCache.load(displayId: outcome.displayId, interface: outcome.interface, from: defaults))

        let ended = Date().addingTimeInterval(10)
        while h.state != .ended(.stopped) && Date() < ended { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(h.state, .ended(.stopped))
    }
}
