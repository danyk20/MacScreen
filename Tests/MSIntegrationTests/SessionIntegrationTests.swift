import XCTest
import Network
import CoreVideo
import MSCore
import MSCodec
import MSProtocol
import MSProbe
import MSHost
import MSDisplay

private final class Locked<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
}

private final class PullingOutput: AudioOutput {
    private let lock = NSLock()
    private var render: AudioRenderCallback?
    func start(render: @escaping AudioRenderCallback) throws { lock.lock(); self.render = render; lock.unlock() }
    func stop() { lock.lock(); render = nil; lock.unlock() }
    func pull(_ frames: Int) -> [Int16]? {
        lock.lock(); defer { lock.unlock() }
        guard let r = render else { return nil }
        var out = [Int16](repeating: 0, count: frames * 2)
        out.withUnsafeMutableBufferPointer { r($0.baseAddress!, frames) }
        return out
    }
}

/// Counting-pattern audio source (no CoreAudio, no microphone).
private final class SyntheticAudioSource: AudioInputSource {
    private let queue = DispatchQueue(label: "test.audio.source")
    private var timer: DispatchSourceTimer?
    func start(onSamples: @escaping (UnsafeRawBufferPointer) -> Void) throws {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(5))
        let chunk = [Int16](repeating: 100, count: 240 * 2)
        t.setEventHandler { chunk.withUnsafeBytes { onSamples($0) } }
        timer = t
        t.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
}

/// Synthetic frames at a fixed rate; needs no Screen Recording permission.
private class TestPatternSource: FrameSource {
    private let queue = DispatchQueue(label: "test.pattern.source")
    private var timer: DispatchSourceTimer?
    let started = Locked(0)

    func start(format: VideoFormat, hiDPI: Bool, display: CapabilitiesMessage,
               onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) async throws {
        let pattern = try TestPattern(width: format.width, height: format.height)
        started.mutate { $0 += 1 }
        let t = DispatchSource.makeTimerSource(queue: queue)
        var i = 0
        t.schedule(deadline: .now(), repeating: .milliseconds(1000 / max(format.fps, 1)))
        t.setEventHandler {
            if let pb = try? pattern.frame(i) { onFrame(pb, MonoClock.nowMicros()) }
            i += 1
        }
        timer = t
        t.resume()
    }

    func stop() async {
        timer?.cancel()
        timer = nil
    }
}

/// Pattern source that also supports overlay cursor mode.
private final class CursorTestSource: TestPatternSource, CursorAwareSource {
    var showsCursor = true
    var capturedDisplayID: CGDirectDisplayID? { 1 }
}

private final class FakeCursorSampler: CursorSampling {
    private let n = Locked(0)
    func location() -> CGPoint? { n.mutate { $0 += 1 }; return CGPoint(x: 10 + Double(n.get() % 50), y: 20) }
    func isCursorVisible() -> Bool { true }
    func currentShape() -> CursorShape? {
        CursorShape(png: Data([7, 7, 7]), hotX: 1, hotY: 1, widthPt: 8, heightPt: 8)
    }
    func displayBounds() -> CGRect? { CGRect(x: 0, y: 0, width: 100, height: 100) }
}

private final class TestSink: DisplaySink {
    let cursorPackets = Locked<[CursorPacket]>([])
    let cursorImages = Locked<[CursorImageMessage]>([])
    let audio = Locked<[AudioPacket]>([])
    var player: AudioPlayer?
    func audioPacket(_ p: AudioPacket) { audio.mutate { $0.append(p) }; player?.enqueue(p) }

    func cursorPosition(_ p: CursorPacket) { cursorPackets.mutate { $0.append(p) } }
    func cursorImage(_ i: CursorImageMessage) { cursorImages.mutate { $0.append(i) } }

    let frames = Locked(0)
    let sizes = Locked<[Int]>([])
    let code = Locked<String?>(nil)
    let codesShown = Locked(0)
    let started = Locked(0)
    let ended = Locked(0)
    var allow = true
    /// Simulates the renderer's presented callback.
    var latency: LatencyRecorder?
    var onCode: ((String) -> Void)?

    func present(_ pb: CVPixelBuffer, captureTimeMicros: UInt64) {
        frames.mutate { $0 += 1 }
        latency?.presented(captureMicros: captureTimeMicros, atMicros: MonoClock.nowMicros())
        if frames.get() == 1 { sizes.mutate { $0 = [CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)] } }
    }
    func showPairingCode(_ c: String, hostName: String) {
        code.mutate { $0 = c }
        codesShown.mutate { $0 += 1 }
        onCode?(c)
    }
    func hidePairingCode() {}
    func askAllow(hostName: String, completion: @escaping (Bool) -> Void) { completion(allow) }
    func sessionStarted(hostName: String) { started.mutate { $0 += 1 } }
    func sessionEnded() { ended.mutate { $0 += 1 } }
}

final class SessionIntegrationTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func makeStore(_ name: String) throws -> IdentityStore {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ms-it-\(UUID().uuidString)")
        dirs.append(d)
        return try IdentityStore(directory: d, defaultDeviceName: name)
    }

    private func caps(role: String, name: String) -> CapabilitiesMessage {
        CapabilitiesMessage(role: role, deviceName: name, osVersion: "test", panelPixelWidth: 1280,
                            panelPixelHeight: 720, panelWidthMM: 600, panelHeightMM: 340, backingScale: 2,
                            edrHeadroom: 1, refreshHz: 60, hwDecodeH264: true, hwDecodeHEVC: true,
                            hwEncodeH264: true, hwEncodeHEVC: true, wideColor: false)
    }

    private func hostConfig() -> HostSessionConfig {
        var c = HostSessionConfig()
        c.chooseFormat = { VideoFormat(codec: .h264, width: $0.panelPixelWidth, height: $0.panelPixelHeight,
                                       fps: 30, bitDepth: 8) }
        return c
    }

    private func wait(_ what: String, timeout: TimeInterval = 15, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private func startDisplay(_ store: IdentityStore, sink: TestSink) throws -> (DisplaySession, NWEndpoint) {
        let d = DisplaySession(identityStore: store, capabilities: caps(role: "display", name: "D"), sink: sink)
        try d.start()
        let end = Date().addingTimeInterval(10)
        while d.port == nil && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        let port = try XCTUnwrap(d.port, "display listener not ready")
        return (d, .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
    }

    private func host(_ store: IdentityStore, _ src: FrameSource) -> HostSession {
        HostSession(identityStore: store, capabilities: caps(role: "host", name: "H"),
                    config: hostConfig(), makeSource: { _ in src })
    }

    func testLatencyCSVFromLoopback() throws {
        let hostStore = try makeStore("Host")
        let sink = TestSink()
        let (display, endpoint) = try startDisplay(try makeStore("Display"), sink: sink)
        sink.latency = display.latency
        defer { display.stop() }
        let h = host(hostStore, TestPatternSource())
        sink.onCode = { h.submitPairingCode($0) }
        h.connect(to: endpoint)
        wait("frames") { sink.frames.get() >= 40 }
        h.stop()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ms-latency-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try display.latency.writeCSV(to: url)
        let lines = try String(contentsOf: url).split(separator: "\n").map(String.init)
        XCTAssertGreaterThan(lines.count, 20, "csv should have a row per presented frame")
        XCTAssertEqual(lines[0], LatencyRecorder.csvHeader)
        let cols = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(cols.count, LatencyRecorder.csvHeader.split(separator: ",").count)
        let snap = display.latency.snapshot
        XCTAssertGreaterThan(snap.count, 20)
        // Loopback on one clock: roughly encode + decode time, well under a second.
        XCTAssertGreaterThan(snap.p50, -50)
        XCTAssertLessThan(snap.p50, 1000)
        XCTAssertGreaterThanOrEqual(snap.p95, snap.p50)
    }

    func testOverlayCursorPacketsArrive() throws {
        let hostStore = try makeStore("Host")
        let displayStore = try makeStore("Display")
        let sink = TestSink()
        let (display, endpoint) = try startDisplay(displayStore, sink: sink)
        defer { display.stop() }
        let src = CursorTestSource()
        var cfg = hostConfig()
        cfg.cursorMode = "overlay"
        cfg.makeCursorSampler = { _ in FakeCursorSampler() }
        let h = HostSession(identityStore: hostStore, capabilities: caps(role: "host", name: "H"),
                            config: cfg, makeSource: { _ in src })
        sink.onCode = { h.submitPairingCode($0) }
        h.connect(to: endpoint)
        wait("cursor packets") { sink.cursorPackets.get().count >= 10 && !sink.cursorImages.get().isEmpty }
        XCTAssertFalse(src.showsCursor, "overlay mode hides the embedded cursor")
        let imgs = sink.cursorImages.get()
        XCTAssertEqual(imgs.count, 1)
        let p = sink.cursorPackets.get()
        XCTAssertTrue(p.allSatisfy { $0.visible && $0.imageId == imgs[0].id })
        XCTAssertTrue(p[0].x >= 0.1 && p[0].x < 0.6)
        h.stop()
        wait("end") { sink.ended.get() == 1 }
    }

    func testAudioPacketsArriveWithSequenceAndSize() throws {
        let hostStore = try makeStore("Host")
        let sink = TestSink()
        let (display, endpoint) = try startDisplay(try makeStore("Display"), sink: sink)
        defer { display.stop() }
        var cfg = hostConfig()
        cfg.audioEnabled = true
        cfg.makeAudioSource = { SyntheticAudioSource() }
        let h = HostSession(identityStore: hostStore, capabilities: caps(role: "host", name: "H"),
                            config: cfg, makeSource: { _ in TestPatternSource() })
        sink.onCode = { h.submitPairingCode($0) }
        h.connect(to: endpoint)
        wait("audio packets") { sink.audio.get().count >= 30 }
        h.stop()
        wait("end") { sink.ended.get() == 1 }
        let p = sink.audio.get()
        XCTAssertTrue(p.allSatisfy { $0.pcm.count == 960 })
        // Loopback UDP does not reorder; sequence must be strictly increasing and (nearly) gapless.
        let seqs = p.map { $0.seq }
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(Set(seqs).count, seqs.count)
        XCTAssertEqual(seqs.first, 0)
        XCTAssertLessThanOrEqual(Int(seqs.last!) - seqs.count + 1, 3)
    }

    func testAudioReachesPlayerWithContinuousSamples() throws {
        let hostStore = try makeStore("Host")
        let sink = TestSink()
        let out = PullingOutput()
        let player = AudioPlayer(output: out, targetMs: 40)
        sink.player = player
        try player.start()
        defer { player.stop() }
        let (display, endpoint) = try startDisplay(try makeStore("Display"), sink: sink)
        defer { display.stop() }
        var cfg = hostConfig()
        cfg.audioEnabled = true
        cfg.makeAudioSource = { SyntheticAudioSource() }
        let h = HostSession(identityStore: hostStore, capabilities: caps(role: "host", name: "H"),
                            config: cfg, makeSource: { _ in TestPatternSource() })
        sink.onCode = { h.submitPairingCode($0) }
        h.connect(to: endpoint)
        wait("audio packets") { sink.audio.get().count >= 60 }
        // Pull 10 ms blocks at real rate; after the first non-silent block the stream must not contain gaps.
        var started = false
        var gaps = 0, played = 0
        for _ in 0..<40 {
            guard let b = out.pull(480) else { break }
            let nonZero = b.filter { $0 != 0 }.count
            if !started { started = nonZero > 0 }
            if started { played += nonZero; if nonZero != b.count { gaps += 1 } }
            Thread.sleep(forTimeInterval: 0.01)
        }
        h.stop()
        wait("end") { sink.ended.get() == 1 }
        XCTAssertTrue(started)
        XCTAssertGreaterThan(played, 0)
        XCTAssertLessThanOrEqual(gaps, 1, "non-silent blocks must be continuous")
    }

    func testAudioOffSendsNoAudio() throws {
        let hostStore = try makeStore("Host")
        let sink = TestSink()
        let (display, endpoint) = try startDisplay(try makeStore("Display"), sink: sink)
        defer { display.stop() }
        var cfg = hostConfig()
        cfg.makeAudioSource = { SyntheticAudioSource() }
        let h = HostSession(identityStore: hostStore, capabilities: caps(role: "host", name: "H"),
                            config: cfg, makeSource: { _ in TestPatternSource() })
        sink.onCode = { h.submitPairingCode($0) }
        h.connect(to: endpoint)
        wait("frames") { sink.frames.get() >= 10 }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(sink.audio.get().isEmpty)
        h.stop()
    }

    func testEmbeddedModeSendsNoCursor() throws {
        let hostStore = try makeStore("Host")
        let sink = TestSink()
        let (display, endpoint) = try startDisplay(try makeStore("Display"), sink: sink)
        defer { display.stop() }
        let src = CursorTestSource()
        var cfg = hostConfig()
        cfg.makeCursorSampler = { _ in FakeCursorSampler() }
        let h = HostSession(identityStore: hostStore, capabilities: caps(role: "host", name: "H"),
                            config: cfg, makeSource: { _ in src })
        sink.onCode = { h.submitPairingCode($0) }
        h.connect(to: endpoint)
        wait("frames") { sink.frames.get() >= 20 }
        XCTAssertTrue(src.showsCursor)
        XCTAssertTrue(sink.cursorPackets.get().isEmpty)
        h.stop()
    }

    func testPairThenReconnectStreamsFrames() throws {
        let hostStore = try makeStore("Host")
        let displayStore = try makeStore("Display")
        let sink = TestSink()
        let (display, endpoint) = try startDisplay(displayStore, sink: sink)
        defer { display.stop() }

        // First connection: pairing, code entered programmatically.
        let src1 = TestPatternSource()
        let h1 = host(hostStore, src1)
        sink.onCode = { code in h1.submitPairingCode(code) }
        h1.onPairingCodeRequired = {}
        h1.connect(to: endpoint)
        wait("streaming with pairing") { h1.state == .streaming && sink.frames.get() >= 30 }
        XCTAssertEqual(sink.codesShown.get(), 1)
        XCTAssertEqual(sink.sizes.get(), [1280, 720])
        XCTAssertEqual(hostStore.peers.count, 1)
        XCTAssertEqual(displayStore.peers.count, 1)
        XCTAssertGreaterThanOrEqual(h1.framesSent, 25)
        h1.stop()
        wait("display session end") { sink.ended.get() == 1 }

        // Second connection: both know each other, no code.
        let before = sink.frames.get()
        let h2 = host(hostStore, TestPatternSource())
        h2.connect(to: endpoint)
        wait("streaming without pairing") { h2.state == .streaming && sink.frames.get() >= before + 30 }
        XCTAssertEqual(sink.codesShown.get(), 1, "known peers must not pair again")
        h2.stop()
        wait("second end") { sink.ended.get() == 2 }
    }

    func testNewHostSessionAfterStopAcceptedWithoutPairing() throws {
        let hostStore = try makeStore("Host")
        let sink = TestSink()
        let (display, endpoint) = try startDisplay(try makeStore("Display"), sink: sink)
        defer { display.stop() }
        let h1 = host(hostStore, TestPatternSource())
        sink.onCode = { h1.submitPairingCode($0) }
        h1.connect(to: endpoint)
        wait("first streaming") { h1.state == .streaming && sink.frames.get() >= 10 }
        h1.stop()
        wait("display idle") { sink.ended.get() == 1 }
        let before = sink.frames.get()
        let h2 = host(hostStore, TestPatternSource())
        h2.connect(to: endpoint)
        wait("second streaming") { h2.state == .streaming && sink.frames.get() >= before + 10 }
        XCTAssertEqual(sink.codesShown.get(), 1)
        XCTAssertEqual(sink.started.get(), 2)
        h2.stop()
        wait("second end") { sink.ended.get() == 2 }
    }

    func testWrongCodeAborts() throws {
        let sink = TestSink()
        let (display, endpoint) = try startDisplay(try makeStore("Display"), sink: sink)
        defer { display.stop() }
        let hostStore = try makeStore("Host")
        let h = host(hostStore, TestPatternSource())
        sink.onCode = { code in h.submitPairingCode(code == "123456" ? "654321" : "123456") }
        h.connect(to: endpoint)
        wait("mismatch end") { h.state == .ended(.pairingCodeMismatch) }
        XCTAssertTrue(hostStore.peers.isEmpty)
        XCTAssertEqual(sink.frames.get(), 0)
    }

    func testDeniedPairing() throws {
        let sink = TestSink()
        sink.allow = false
        let (display, endpoint) = try startDisplay(try makeStore("Display"), sink: sink)
        defer { display.stop() }
        let hostStore = try makeStore("Host")
        let h = host(hostStore, TestPatternSource())
        sink.onCode = { h.submitPairingCode($0) }
        h.connect(to: endpoint)
        wait("denied end") { h.state == .ended(.pairingDenied) }
        XCTAssertTrue(hostStore.peers.isEmpty)
    }

    func testSecondHostGetsBusy() throws {
        let hostStore = try makeStore("Host")
        let sink = TestSink()
        let (display, endpoint) = try startDisplay(try makeStore("Display"), sink: sink)
        defer { display.stop() }
        let h1 = host(hostStore, TestPatternSource())
        sink.onCode = { h1.submitPairingCode($0) }
        h1.connect(to: endpoint)
        wait("first streaming") { h1.state == .streaming }

        let h2 = host(try makeStore("Host2"), TestPatternSource())
        h2.connect(to: endpoint)
        wait("busy") { h2.state == .ended(.peerBye("busy")) }
        XCTAssertEqual(h1.state, .streaming)
        h1.stop()
    }
}
