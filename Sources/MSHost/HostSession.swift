import CoreVideo
import Foundation
import Network
import os
import MSCodec
import MSCore
import MSProbe
import MSProtocol
import MSTransport

public enum HostSessionState: Equatable {
    case idle
    case connecting
    case awaitingPairingCode
    case awaitingPairingApproval
    case negotiating
    case streaming
    case ended(HostSessionEnd)
}

public enum HostSessionEnd: Equatable {
    case stopped
    case peerBye(String)
    case pairingCodeMismatch
    case pairingDenied
    case failure(String)
    case closed(ControlCloseReason)
}

public struct HostSessionConfig {
    public var fecRatio: Double = MSConstants.fecRatioWiFi
    public var hiDPI = true
    /// "embedded" (cursor in the video) or "overlay" (separate cursor packets, T3.1).
    public var cursorMode = "embedded"
    /// Test hook: replaces the system cursor sampler in overlay mode.
    public var makeCursorSampler: ((CursorAwareSource) -> CursorSampling)?
    public var chooseFormat: (CapabilitiesMessage) -> VideoFormat = HostSessionConfig.defaultFormat
    /// Upper bound for the profile bitrate in bit/s (AppSettings bitrate cap); nil = automatic.
    public var maxBitrate: Int?
    /// Usable link throughput measured by the automatic link check (P1); the bitrate ceiling and start
    /// become 0.6 x this, never above the profile bitrate. nil = no measurement.
    public var linkThroughputBps: Int?
    /// Setup test: when set, the session runs the probe (PLAN 6.10) instead of streaming, then ends.
    public var probe: ProbeRunConfig?
    /// Requests audio (PLAN 6.9) and captures it once streaming. Off by default.
    public var audioEnabled = false
    /// Test hook: replaces the AUHAL input on the "MacScreen Display" device.
    public var makeAudioSource: (() -> AudioInputSource)?
    /// Capture watchdog input: main display awake and session unlocked (test hook).
    public var screenAvailable: () -> Bool = { ScreenState.captureAvailable }

    public init() {}

    /// Config from stored settings; the format choice respects the Display's capabilities.
    public init(settings: AppSettings) {
        cursorMode = settings.cursorMode
        if let f = settings.fecRatio { fecRatio = f }
        if settings.bitrateCapMbps > 0 { maxBitrate = settings.bitrateCapMbps * 1_000_000 }
        chooseFormat = { HostSessionConfig.format(for: $0, settings: settings) }
    }

    /// Closest supported format to the settings, never above what the Display advertises.
    public static func format(for c: CapabilitiesMessage, settings: AppSettings) -> VideoFormat {
        // Codec: preferred if both ends support it in hardware, else the other, else the default rule.
        let hevcOK = c.hwDecodeHEVC && c.hwEncodeHEVC
        let h264OK = c.hwDecodeH264 && c.hwEncodeH264
        var codec: Codec = settings.codec == "h264" ? .h264 : .hevc
        if codec == .hevc && !hevcOK { codec = .h264 } else if codec == .h264 && !h264OK && hevcOK { codec = .hevc }
        // Resolution: the panel size reduced to maxHeight keeping aspect; even dimensions. maxHeight 0 = the
        // panel size itself (e.g. 5K, manual choice only); the default is 2160 (G1 decision).
        var w = max(2, c.panelPixelWidth), h = max(2, c.panelPixelHeight)
        if settings.maxHeight > 0 && settings.maxHeight < h {
            w = Int((Double(w) * Double(settings.maxHeight) / Double(h)).rounded())
            h = settings.maxHeight
        }
        // No H.264 above 4096x2304.
        if codec == .h264 && (w > 4096 || h > 2304) {
            let k = min(4096.0 / Double(w), 2304.0 / Double(h))
            w = Int(Double(w) * k); h = Int(Double(h) * k)
        }
        w = max(2, w & ~1); h = max(2, h & ~1)
        // Frame rate: largest option not above the preference or the Display refresh rate.
        let limit = min(settings.fps, Int(c.refreshHz.rounded()))
        let fps = AppSettings.fpsOptions.filter { $0 <= limit }.max() ?? AppSettings.fpsOptions[0]
        return VideoFormat(codec: codec, width: w, height: h, fps: fps, bitDepth: 8)
    }

    public static func defaultFormat(_ c: CapabilitiesMessage) -> VideoFormat {
        format(for: c, settings: AppSettings())
    }
}

/// Host side of one connection: handshake, pairing, negotiation, streaming (PLAN.md section 8, T2.10).
/// Single use: create a new `HostSession` per connection. Callbacks fire on internal queues.
public final class HostSession {
    private static let log = Log.logger("host")

    private let store: IdentityStore
    private let hostCaps: CapabilitiesMessage
    private let config: HostSessionConfig
    private let makeSource: (PeerInfo) -> FrameSource

    private let queue = DispatchQueue(label: "ms.control.host", qos: .userInitiated)
    private let mediaQueue = DispatchQueue(label: "ms.media.host", qos: .userInteractive)
    private let encodeQueue = DispatchQueue(label: "ms.encode.out", qos: .userInteractive)

    public var onStateChange: ((HostSessionState) -> Void)?
    /// The Display shows a code; call `submitPairingCode` with what the user typed.
    public var onPairingCodeRequired: (() -> Void)?
    /// The captured display was recreated by the capture watchdog (new display id).
    public var onCapturedDisplayChanged: ((CGDirectDisplayID) -> Void)?

    private let stateLock = NSLock()
    private var stateValue = HostSessionState.idle
    public var state: HostSessionState { stateLock.lock(); defer { stateLock.unlock() }; return stateValue }

    // Control-queue state.
    private var channel: ControlChannel?
    private var handshake: HandshakeResult?
    private var displayCaps: CapabilitiesMessage?
    private var format: VideoFormat?
    private var sessionRequested = false
    private var source: FrameSource?
    private var media: MediaClient?
    private var encoder: VideoEncoder?
    private var rate: RateController?     // media queue after start
    private var fpsDivisor = 1             // guarded by streamLock; 2 after reconfigure to 30 fps
    private var captureTick = 0            // source thread only
    private var currentFec = 0.0           // guarded by streamLock
    private var currentBitrate = 0         // guarded by streamLock (pacing)
    private var cursorTracker: CursorTracker?
    private var audioCapture: AudioCapture?
    private var recoveryTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var watchdog = CaptureWatchdog()       // control queue
    private var watchdogActionInFlight = false     // control queue
    private var captureHealthy = false             // guarded by streamLock
    private var lastHeartbeat: UInt64 = 0          // control queue
    private var pingTimer: DispatchSourceTimer?
    private let pingClock = PingClock()     // media queue only
    private let history = PacketHistory()
    private var ended = false
    private var peerByeReason: String?
    private var probeDriver: ProbeHostDriver?
    private var interfaceType: LinkInterface = .other
    private let probeMediaLock = NSLock()
    private var probeMedia: MediaClient?

    // Shared between capture, encode, media and control queues.
    private let streamLock = NSLock()
    private var lastBuffer: CVPixelBuffer?
    private var lastCaptureArrival: UInt64 = 0
    private var lastEncodeOut: UInt64 = 0   // encode queue (under streamLock)
    private var lastSentFrameId: UInt32 = 0
    private var highestDecoded: UInt32 = 0
    private var lastProgress: UInt64 = 0
    private var lastForcedKeyframe: UInt64 = 0
    /// Last keyframe handed to the media channel (frame id, send time); guarded by streamLock.
    private var lastKeyframeSent: (id: UInt32, at: UInt64)?
    private var hostRttMs: Double = 0            // guarded by streamLock; copy of pingClock.rttMs
    private var keyframePendingSince: UInt64?
    private var streamActive = false
    private var frameCounter: UInt32 = 0     // encode queue only
    public var framesSent: UInt64 { streamLock.lock(); defer { streamLock.unlock() }; return framesSentValue }
    private var framesSentValue: UInt64 = 0
    private var bytesSentValue: UInt64 = 0
    /// Encoded payload bytes handed to the media channel (before FEC and encryption).
    public var bytesSent: UInt64 { streamLock.lock(); defer { streamLock.unlock() }; return bytesSentValue }
    private var framesDropped: UInt64 = 0
    // Periodic stats (category host-stats), guarded by streamLock.
    private var st = HostStatsWindow()
    private var encodeStart: [UInt64: UInt64] = [:]
    private var statsTimer: DispatchSourceTimer?
    private var lastMediaCounters = MediaCounters()
    private var lastCapCounters: (UInt64, UInt64, UInt64) = (0, 0, 0)
    private static let statsLog = Log.logger("host-stats")

    public init(identityStore: IdentityStore, capabilities: CapabilitiesMessage,
                config: HostSessionConfig = HostSessionConfig(),
                makeSource: @escaping (PeerInfo) -> FrameSource) {
        self.store = identityStore
        self.hostCaps = capabilities
        self.config = config
        self.makeSource = makeSource
    }

    // MARK: Public API

    public func connect(to endpoint: NWEndpoint) {
        queue.async { [self] in
            guard state == .idle else { return }
            setState(.connecting)
            let q = queue
            Task { [weak self] in
                let planner = ConnectPlanner()
                let won = await planner.run(shouldContinue: { [weak self] in self?.isConnectingNow ?? false }) { a in
                    await ConnectPlanner.connectNW(to: endpoint, queue: q, attempt: a)
                }
                self?.queue.async { [weak self] in
                    guard let self = self else { won?.result.cancel(); return }
                    guard self.state == .connecting, !self.ended else { won?.result.cancel(); return }
                    guard let conn = won?.result else {
                        self.finish(.closed(.network("could not connect")))
                        return
                    }
                    self.startChannel(conn)
                }
            }
        }
    }

    private var isConnectingNow: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stateValue == .connecting
    }

    private func startChannel(_ conn: NWConnection) {
        if let path = conn.currentPath {
            if path.usesInterfaceType(.wiredEthernet) { interfaceType = .wired }
            else if path.usesInterfaceType(.wifi) { interfaceType = .wifi }
            else if path.usesInterfaceType(.loopback) { interfaceType = .wired }
        }
        let store = self.store
        let ch = ControlChannel(connection: conn, role: .host, identity: store.identity,
                                isKnownPeer: { store.isKnown(identityKey: $0) }, queue: queue)
        ch.onSecured = { [weak self] r in self?.handleSecured(r) }
        ch.onMessage = { [weak self] m in self?.handleMessage(m) }
        ch.onPeerBye = { [weak self] reason in self?.peerByeReason = reason }
        ch.onClosed = { [weak self] reason in
            guard let self = self else { return }
            if let b = self.peerByeReason { self.finish(.peerBye(b)) } else { self.finish(.closed(reason)) }
        }
        channel = ch
        ch.start()
    }

    public func submitPairingCode(_ code: String) {
        queue.async { [self] in
            guard state == .awaitingPairingCode, let r = handshake, let ch = channel else { return }
            guard constantTimeEqual(code.trimmingCharacters(in: .whitespaces), r.pairingCode) else {
                ch.send(.bye(ByeMessage(reason: "pairing-failed")))
                finish(.pairingCodeMismatch)
                return
            }
            do {
                try store.addPeer(Peer(deviceId: r.peerDeviceId, deviceName: r.peerDeviceName,
                                       identityKey: r.peerIdentityKey, pairedAt: Date()))
            } catch {
                finish(.failure("identity store: \(error)"))
                return
            }
            ch.send(.pairConfirm(PairConfirmMessage()))
            setState(.awaitingPairingApproval)
        }
    }

    /// Tells the Display about Host state changes (`hostState` control message). Safe from any thread.
    public func sendHostState(displayAsleep: Bool, mirroring: Bool) {
        queue.async { [self] in
            guard !ended else { return }
            channel?.send(.hostState(HostStateMessage(displayAsleep: displayAsleep, mirroring: mirroring)))
        }
    }

    /// The virtual display being captured, once it exists.
    public var capturedDisplayID: CGDirectDisplayID? {
        queue.sync { (source as? CursorAwareSource)?.capturedDisplayID }
    }

    public func stop() {
        queue.async { [self] in finish(.stopped) }
    }

    /// Stops the audio capture for the rest of this session (used when the user turns the sound off mid-session).
    public func stopAudio() {
        queue.async { [self] in
            audioCapture?.stop()
            audioCapture = nil
        }
    }

    // MARK: Control

    private func setState(_ s: HostSessionState) {
        stateLock.lock()
        let changed = stateValue != s
        stateValue = s
        stateLock.unlock()
        if changed {
            Self.log.notice("state -> \(String(describing: s), privacy: .public)")
            onStateChange?(s)
        }
    }

    private func handleSecured(_ r: HandshakeResult) {
        handshake = r
        Self.log.notice("secured with \(r.peerDeviceName, privacy: .public): peerWasKnown=\(r.peerWasKnown) peerKnowsUs=\(String(describing: r.peerKnowsUs), privacy: .public)")
        if r.peerWasKnown && r.peerKnowsUs == true {
            beginNegotiation()
        } else {
            channel?.send(.pairRequest(PairRequestMessage()))
            setState(.awaitingPairingCode)
            onPairingCodeRequired?()
        }
    }

    private func beginNegotiation() {
        setState(.negotiating)
        channel?.send(.capabilities(hostCaps))
        sendSessionRequestIfReady()
    }

    private func handleMessage(_ m: ControlMessage) {
        switch m {
        case .pairResult(let p):
            guard state == .awaitingPairingApproval, let r = handshake else { return }
            if p.accepted {
                beginNegotiation()
            } else {
                try? store.removePeer(identityKey: r.peerIdentityKey)
                finish(.pairingDenied)
            }
        case .capabilities(let c):
            guard c.role == "display" else { return }
            displayCaps = c
            sendSessionRequestIfReady()
        case .sessionAccept, .probeResult, .linkProbeResult:
            if config.probe != nil { probeDriver?.receive(m); return }
            if case .sessionAccept(let a) = m, state == .negotiating, sessionRequested, media == nil {
                startStreaming(udpPort: a.udpPort)
            }
        default:
            break
        }
    }

    private func sendSessionRequestIfReady() {
        guard state == .negotiating, !sessionRequested, let caps = displayCaps else { return }
        sessionRequested = true
        if let p = config.probe { startProbe(p, displayCaps: caps); return }
        let f = config.chooseFormat(caps)
        format = f
        let wire = WireVideoFormat(codec: f.codec.rawValue, width: f.width, height: f.height,
                                   fps: f.fps, bitDepth: f.bitDepth)
        Self.log.notice("sessionRequest \(String(describing: f), privacy: .public) hiDPI=\(self.config.hiDPI) cursor=\(self.config.cursorMode, privacy: .public)")
        channel?.send(.sessionRequest(SessionRequestMessage(format: wire, hiDPI: config.hiDPI,
                                                            cursorMode: config.cursorMode, audio: config.audioEnabled,
                                                            fecRatio: config.fecRatio)))
    }

    // MARK: Setup test

    private func startProbe(_ p: ProbeRunConfig, displayCaps caps: CapabilitiesMessage) {
        guard let r = handshake, let ch = channel, let host = ch.remoteHost else {
            finish(.failure("missing session state"))
            return
        }
        let env = ProbeHostDriver.Environment(
            sendControl: { [weak self] m in self?.channel?.send(m) },
            openMedia: { [weak self] port in
                self?.queue.async {
                    guard let self = self, !self.ended else { return }
                    let m = MediaClient(host: host, port: port, sealKey: r.keys.medH2D, openKey: r.keys.medD2H,
                                        queue: self.mediaQueue)
                    m.onReady = { [weak self] in self?.probeDriver?.mediaReady() }
                    m.onFailed = { reason in Self.log.debug("probe media: \(reason, privacy: .public)") }
                    self.probeMediaLock.lock(); self.probeMedia = m; self.probeMediaLock.unlock()
                    m.start()
                }
            },
            sendMedia: { [weak self] items, pace in
                guard let self = self else { return }
                self.probeMediaLock.lock(); let m = self.probeMedia; self.probeMediaLock.unlock()
                m?.sendBatch(items, paceOverMicros: pace)
            })
        let driver = ProbeHostDriver(environment: env)
        probeDriver = driver
        let hostCaps = self.hostCaps
        let iface = interfaceType
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = driver.run(config: p, hostCaps: hostCaps, displayCaps: caps,
                                    displayId: r.peerDeviceId, interface: iface)
            p.onFinished?(result)
            self?.queue.async { self?.finish(.stopped) }
        }
    }

    // MARK: Streaming

    private func startStreaming(udpPort: UInt16) {
        Self.log.notice("sessionAccept udpPort=\(udpPort)")
        guard let r = handshake, let ch = channel, let f = format, let caps = displayCaps,
              let host = ch.remoteHost else {
            finish(.failure("missing session state"))
            return
        }
        let bitsPerPixel = f.codec == .hevc ? MSConstants.bitsPerPixelHEVC : MSConstants.bitsPerPixelH264
        var profileBitrate = max(MSConstants.minBitrate, Int(Double(f.width * f.height * f.fps) * bitsPerPixel))
        if let cap = config.maxBitrate { profileBitrate = max(MSConstants.minBitrate, min(profileBitrate, cap)) }
        let linkCap = config.linkThroughputBps.map { LinkAwareProfile.bitrateCap(throughputBps: $0) }
        let rc = RateController(profileBitrate: profileBitrate, linkFecRatio: config.fecRatio, throughputCapBps: linkCap)
        Self.log.notice("rate start=\(rc.initialBitrate) profile=\(profileBitrate) linkCap=\(linkCap ?? -1)")
        rate = rc
        streamLock.lock(); currentFec = rc.fecRatio; currentBitrate = rc.initialBitrate; streamLock.unlock()
        let bitrate = rc.initialBitrate
        do {
            encoder = try VideoEncoder(format: f, bitrate: bitrate,
                                   colour: ColourPlan(panelIsP3: caps.wideColor)) { [weak self] frame in
                self?.encodeQueue.async { self?.sendFrame(frame) }
            }
        } catch {
            finish(.failure("encoder: \(error)"))
            return
        }
        let m = MediaClient(host: host, port: udpPort, sealKey: r.keys.medH2D, openKey: r.keys.medD2H,
                            queue: mediaQueue)
        m.onPacket = { [weak self] type, payload in self?.handleMedia(type, payload) }
        m.onReady = { [weak self] in
            guard let self = self else { return }
            self.queue.async { self.startSource(format: f, caps: caps, peer: r) }
        }
        m.onFailed = { reason in Self.log.error("media: \(reason, privacy: .public)") }
        media = m
        m.start()
    }

    private var sourceStarted = false

    private func startSource(format f: VideoFormat, caps: CapabilitiesMessage, peer r: HandshakeResult) {
        guard !ended, !sourceStarted else { return }
        sourceStarted = true
        let now = MonoClock.nowMicros()
        streamLock.lock()
        lastProgress = now
        streamActive = true
        streamLock.unlock()

        startTimers()
        let src = makeSource(PeerInfo(deviceId: r.peerDeviceId, deviceName: r.peerDeviceName))
        source = src
        if config.cursorMode == "overlay", let cs = src as? CursorAwareSource {
            cs.showsCursor = false
            startCursorTracker(for: cs)
        }
        if config.audioEnabled { startAudio() }
        let hiDPI = config.hiDPI
        Task { [weak self] in
            do {
                try await src.start(format: f, hiDPI: hiDPI, display: caps) { [weak self] pb, t in
                    self?.handleCapture(pb, captureTimeMicros: t)
                }
                self?.queue.async { [weak self] in
                    guard let self = self, !self.ended else { return }
                    self.setState(.streaming)
                    self.startWatchdog()
                }
            } catch {
                self?.queue.async { self?.finish(.failure("source: \(error)")) }
            }
        }
    }

    /// A missing driver or denied permission only costs the sound, never the session.
    private func startAudio() {
        let src = config.makeAudioSource?() ?? AUHALInputSource()
        let cap = AudioCapture(source: src) { [weak self] p in self?.media?.send(.audio, p.encode()) }
        do {
            try cap.start()
            audioCapture = cap
        } catch {
            Self.log.error("audio capture: \(String(describing: error), privacy: .public)")
        }
    }

    private func startCursorTracker(for cs: CursorAwareSource) {
        let sampler = config.makeCursorSampler?(cs)
            ?? SystemCursorSampler(displayID: { [weak cs] in cs?.capturedDisplayID })
        let t = CursorTracker(sampler: sampler, queue: queue,
                              sendPosition: { [weak self] p in self?.media?.send(.cursor, p.encode()) },
                              sendImage: { [weak self] m in self?.channel?.send(.cursorImage(m)) })
        cursorTracker = t
        t.start()
    }

    private func startTimers() {
        let rt = DispatchSource.makeTimerSource(queue: queue)
        rt.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        rt.setEventHandler { [weak self] in self?.recoveryTick() }
        recoveryTimer = rt
        rt.resume()

        let pt = DispatchSource.makeTimerSource(queue: mediaQueue)
        pt.schedule(deadline: .now(), repeating: .milliseconds(MSConstants.pingIntervalMs))
        pt.setEventHandler { [weak self] in
            guard let self = self, let m = self.media else { return }
            m.send(.ping, self.pingClock.makePing(nowMicros: MonoClock.nowMicros()).encode())
        }
        pingTimer = pt
        pt.resume()

        let stt = DispatchSource.makeTimerSource(queue: mediaQueue)
        stt.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        stt.setEventHandler { [weak self] in self?.logStats() }
        statsTimer = stt
        stt.resume()
    }

    // MARK: Capture watchdog

    private func startWatchdog() {
        guard source is RecoverableCaptureSource, watchdogTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdogTimer = t
        t.resume()
    }

    /// Control queue, every 500 ms.
    private func watchdogTick() {
        guard !ended, !watchdogActionInFlight, let src = source as? RecoverableCaptureSource,
              let count = src.captureProgressCount else { return }
        let now = Double(MonoClock.nowMicros()) / 1e6
        let wasWaiting = watchdog.isWaitingForScreen
        let running = src.isCaptureRunning
        let action = watchdog.tick(now: now, frameCount: count, streamRunning: running,
                                   screenAvailable: config.screenAvailable())
        streamLock.lock(); captureHealthy = watchdog.isHealthy; streamLock.unlock()
        if watchdog.isWaitingForScreen && !wasWaiting {
            Self.log.notice("capture watchdog: screen asleep or locked, waiting")
        }
        switch action {
        case .none:
            return
        case .endSession:
            Self.log.error("capture watchdog: no frames after restart and display recreate, ending session")
            finish(.failure("capture stalled: no frames from ScreenCaptureKit"))
            return
        case .restartCapture, .recreateDisplay:
            break
        }
        let recreate = action == .recreateDisplay
        Self.log.notice("capture watchdog: no frames (stream \(running ? "running" : "stopped", privacy: .public)), \(recreate ? "recreating virtual display" : "restarting capture", privacy: .public)")
        watchdogActionInFlight = true
        Task { [weak self] in
            var failure: String?
            do {
                if recreate { try await src.recreateDisplay() } else { try await src.restartCapture() }
            } catch {
                failure = String(describing: error)
            }
            let id = (src as? CursorAwareSource)?.capturedDisplayID
            self?.queue.async { [weak self] in
                guard let self = self else { return }
                self.watchdogActionInFlight = false
                if let f = failure {
                    Self.log.error("capture watchdog: \(recreate ? "recreate" : "restart", privacy: .public) failed: \(f, privacy: .public)")
                } else {
                    Self.log.notice("capture watchdog: \(recreate ? "recreate" : "restart", privacy: .public) done")
                }
                guard !self.ended else { return }
                self.streamLock.lock(); self.keyframePendingSince = nil; self.streamLock.unlock()
                self.encoder?.requestKeyframe()
                if recreate, failure == nil, let id = id { self.onCapturedDisplayChanged?(id) }
            }
        }
    }

    /// Media queue, every 2 s: one `host-stats` line with per-stage frame counts for the window.
    private func logStats() {
        streamLock.lock()
        let w = st
        st = HostStatsWindow()
        let div = fpsDivisor
        let fec = currentFec
        streamLock.unlock()
        let mc = media?.counters ?? MediaCounters()
        let pkts = mc.packetsSent &- lastMediaCounters.packetsSent
        let wire = mc.bytesSent &- lastMediaCounters.bytesSent
        lastMediaCounters = mc
        var sck = "n/a"
        if #available(macOS 12.3, *), let c = (source as? DisplayCaptureSource)?.captureCounters {
            let p = lastCapCounters
            sck = "\(c.framesDelivered &- p.0)/\(c.framesIdle &- p.1)/\(c.framesOther &- p.2)"
            lastCapCounters = (c.framesDelivered, c.framesIdle, c.framesOther)
        }
        let e = w.encodeMs.sorted()
        func pct(_ q: Double) -> Double { e.isEmpty ? 0 : e[min(e.count - 1, Int(q * Double(e.count)))] }
        let br = rate?.bitrate ?? 0
        let line = String(format: "2s sck(cpl/idle/oth)=%@ cap=%llu busyDrop=%llu divSkip=%llu enc in/out=%llu/%llu kf=%llu encMs p50/p95=%.1f/%.1f sent=%llu payloadKB=%llu maxFrameKB=%llu pkts=%llu wireMbps=%.1f nacks=%llu rtx=%llu kfReq disp/recov=%llu/%llu bitrate=%.1fM fec=%.2f div=%d",
                          sck, w.captured, w.droppedBusy, w.skippedDivisor, w.encodeIn, w.encodeOut, w.keyframesOut,
                          pct(0.5), pct(0.95), w.framesSent, w.bytes / 1024, w.maxFrameBytes / 1024, pkts,
                          Double(wire) * 8 / 2 / 1e6, w.nacks, w.retransmits, w.keyframeReqDisplay,
                          w.keyframeReqRecovery, Double(br) / 1e6, fec, div)
        func p(_ a: [Double], _ q: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(q * Double(s.count)))] }
        let extra = String(format: " capIv p50/p95=%.1f/%.1f outIv p50/p95=%.1f/%.1f inflightAvg=%.2f",
                           p(w.capIvMs, 0.5), p(w.capIvMs, 0.95), p(w.outIvMs, 0.5), p(w.outIvMs, 0.95),
                           w.encodeIn == 0 ? 0 : Double(w.inflightSum) / Double(w.encodeIn))
        Self.statsLog.notice("\(line + extra, privacy: .public)")
    }

    /// Source thread.
    private func handleCapture(_ pb: CVPixelBuffer, captureTimeMicros: UInt64) {
        guard let enc = encoder else { return }
        streamLock.lock()
        guard streamActive else { streamLock.unlock(); return }
        lastBuffer = pb
        let arrival = MonoClock.nowMicros()
        if lastCaptureArrival > 0 { st.capIvMs.append(Double(arrival &- lastCaptureArrival) / 1000) }
        lastCaptureArrival = arrival
        st.captured += 1
        // Up to 2 frames in flight: at 4K the HW encoder's latency (22-37 ms measured) exceeds one
        // 16.7 ms frame interval while its throughput keeps up; `> 1` dropped 10-27 frames per 2 s.
        if enc.pendingFrames > 2 {
            framesDropped += 1
            st.droppedBusy += 1
            streamLock.unlock()
            return
        }
        if fpsDivisor > 1 {
            captureTick &+= 1
            if captureTick % fpsDivisor != 0 { st.skippedDivisor += 1; streamLock.unlock(); return }
        }
        keyframePendingSince = nil
        st.encodeIn += 1
        st.inflightSum += UInt64(enc.pendingFrames)
        encodeStart[captureTimeMicros] = lastCaptureArrival
        if encodeStart.count > 32 { encodeStart.removeAll(keepingCapacity: true) }
        streamLock.unlock()
        Signpost.event("capture", id: captureTimeMicros)
        Signpost.begin("encode", id: captureTimeMicros)
        enc.encode(pb, captureTimeMicros: captureTimeMicros)
    }

    /// Encode queue.
    private func sendFrame(_ f: EncodedFrame) {
        Signpost.end("encode", id: f.captureTimeMicros)
        Signpost.begin("packetize_send", id: f.captureTimeMicros)
        defer { Signpost.end("packetize_send", id: f.captureTimeMicros) }
        streamLock.lock()
        let active = streamActive
        let fec = currentFec
        let bitrateNow = currentBitrate
        st.encodeOut += 1
        let outNow = MonoClock.nowMicros()
        if lastEncodeOut > 0 { st.outIvMs.append(Double(outNow &- lastEncodeOut) / 1000) }
        lastEncodeOut = outNow
        if f.isKeyframe { st.keyframesOut += 1 }
        if let t0 = encodeStart.removeValue(forKey: f.captureTimeMicros) {
            st.encodeMs.append(Double(MonoClock.nowMicros() &- t0) / 1000)
        }
        streamLock.unlock()
        guard active, let m = media else { return }
        frameCounter &+= 1
        if frameCounter == 0 { frameCounter = 1 }
        let id = frameCounter
        var payloadBytes: UInt64 = 0
        do {
            let payload = FramePayload.encode(f)
            payloadBytes = UInt64(payload.count)
            let frags = try Fragmenter.fragment(payload: payload, frameId: id,
                                                isKeyframe: f.isKeyframe,
                                                captureTimeMicros: f.captureTimeMicros,
                                                fecRatio: RateController.frameFecRatio(fec, isKeyframe: f.isKeyframe))
            history.record(frameId: id, fragments: frags, nowMicros: MonoClock.nowMicros())
            let datagrams = frags.map { ($0.type, $0.fragment.encode()) }
            let wireBits = Double(datagrams.reduce(0) { $0 + $1.1.count }) * 8
            let paceBps = max(Double(MSConstants.pacingRateBps), 2.5 * Double(bitrateNow))
            let paceMicros = max(4000, UInt64(wireBits / paceBps * 1e6))
            m.sendBatch(datagrams, paceOverMicros: paceMicros)
        } catch {
            Self.log.error("fragment failed: \(String(describing: error), privacy: .public)")
            return
        }
        streamLock.lock()
        if lastSentFrameId <= highestDecoded { lastProgress = MonoClock.nowMicros() }
        lastSentFrameId = id
        if f.isKeyframe { lastKeyframeSent = (id, MonoClock.nowMicros()) }
        framesSentValue += 1
        bytesSentValue += payloadBytes
        st.framesSent += 1
        st.bytes += payloadBytes
        st.maxFrameBytes = max(st.maxFrameBytes, payloadBytes)
        streamLock.unlock()
    }

    /// Media queue.
    private func handleMedia(_ type: PacketType, _ payload: Data) {
        switch type {
        case .pong:
            if let p = try? PongPacket.decode(payload) {
                pingClock.handlePong(p, nowMicros: MonoClock.nowMicros())
            }
        case .ping:
            if let p = try? PingPacket.decode(payload) {
                let t1 = MonoClock.nowMicros()
                media?.send(.pong, pingClock.handlePing(p, receivedAtMicros: t1,
                                                        sendingAtMicros: MonoClock.nowMicros()).encode())
            }
        case .feedback:
            if let fb = try? FeedbackPacket.decode(payload) { handleFeedback(fb) }
        case .nack:
            if let n = try? NackPacket.decode(payload) {
                let items = history.retransmissions(for: n, nowMicros: MonoClock.nowMicros())
                streamLock.lock(); st.nacks += 1; st.retransmits += UInt64(items.count); streamLock.unlock()
                if !items.isEmpty { media?.sendBatch(items, paceOverMicros: 0) }
            }
        default:
            break
        }
    }

    private func handleFeedback(_ fb: FeedbackPacket) {
        let now = MonoClock.nowMicros()
        streamLock.lock()
        if fb.highestDecodedFrame > highestDecoded || fb.highestDecodedFrame >= lastSentFrameId {
            lastProgress = now
        }
        highestDecoded = max(highestDecoded, fb.highestDecodedFrame)
        var force = false
        hostRttMs = pingClock.rttMs ?? 0
        if fb.requestKeyframe, now &- lastForcedKeyframe >= UInt64(MSConstants.keyframeMinIntervalMs) * 1000,
           !keyframeInFlight(now: now) {
            lastForcedKeyframe = now
            keyframePendingSince = now
            force = true
            st.keyframeReqDisplay += 1
        }
        streamLock.unlock()
        if force { encoder?.requestKeyframe() }
        if let out = rate?.ingest(fb, nowMicros: now, rttMs: pingClock.rttMs) { applyRate(out) }
    }

    /// Media queue. Applies bitrate and FEC live; a 30 fps switch is announced on the control channel.
    private func applyRate(_ out: RateController.Output) {
        Self.statsLog.notice("rate bitrate=\(out.bitrate) fec=\(out.fecRatio) switchTo30fps=\(out.switchTo30fps)")
        encoder?.setBitrate(out.bitrate)
        streamLock.lock()
        currentFec = out.fecRatio
        currentBitrate = out.bitrate
        if out.switchTo30fps { fpsDivisor = 2 }
        streamLock.unlock()
        if out.switchTo30fps {
            queue.async { [self] in
                guard !ended, var f = format, let ch = channel else { return }
                f.fps = 30
                format = f
                ch.send(.reconfigure(ReconfigureMessage(format: WireVideoFormat(
                    codec: f.codec.rawValue, width: f.width, height: f.height, fps: f.fps, bitDepth: f.bitDepth))))
            }
        }
    }

    /// streamLock held. A keyframe sent recently and not yet decoded is still on its way: on Wi-Fi a
    /// ~500 KB keyframe takes ~300 ms at 15 Mbit/s, and re-requests during that time (every 100 ms from the
    /// Display, plus idle recovery) produced 5-7 keyframes per 2 s, saturating the link.
    private func keyframeInFlight(now: UInt64) -> Bool {
        guard let k = lastKeyframeSent, k.id > highestDecoded else { return false }
        let window = UInt64((2 * hostRttMs + Double(MSConstants.keyframeInFlightMs)) * 1000)
        return now &- k.at < window
    }

    /// Control queue, every 10 ms: idle-screen recovery.
    private func recoveryTick() {
        guard !ended, let enc = encoder else { return }
        let now = MonoClock.nowMicros()
        var resend: CVPixelBuffer?
        var force = false
        streamLock.lock()
        if keyframePendingSince == nil, lastSentFrameId > highestDecoded,
           now &- lastProgress >= UInt64(MSConstants.hostRecoveryStallMs) * 1000,
           now &- lastForcedKeyframe >= UInt64(MSConstants.keyframeMinIntervalMs) * 1000,
           !keyframeInFlight(now: now) {
            lastForcedKeyframe = now
            keyframePendingSince = now
            force = true
            st.keyframeReqRecovery += 1
        }
        if let at = keyframePendingSince, now &- at >= 50_000, lastCaptureArrival < at, let b = lastBuffer {
            resend = b
            keyframePendingSince = nil
        }
        // Heartbeat: a static screen yields only idle SCK frames, so nothing reaches the Display, which then
        // could not tell "nothing changed" from "capture died". While capture is healthy, re-send the last
        // picture once a second (a tiny P-frame); a dead capture sends nothing and the Display shows it.
        if resend == nil, captureHealthy, let b = lastBuffer,
           now &- lastCaptureArrival >= 1_000_000, now &- lastHeartbeat >= 1_000_000,
           enc.pendingFrames == 0 {
            resend = b
            lastHeartbeat = now
        }
        streamLock.unlock()
        if force { enc.requestKeyframe() }
        if let b = resend { enc.encode(b, captureTimeMicros: now) }
    }

    // MARK: Teardown

    private func finish(_ reason: HostSessionEnd) {
        guard !ended else { return }
        ended = true
        Self.log.notice("session end in \(String(describing: self.state), privacy: .public): \(String(describing: reason), privacy: .public)")
        if state == .awaitingPairingApproval, let r = handshake {
            // Pairing was never confirmed by the Display: forget the key we stored on a matching code.
            try? store.removePeer(identityKey: r.peerIdentityKey)
        }
        cursorTracker?.stop(); cursorTracker = nil
        audioCapture?.stop(); audioCapture = nil
        recoveryTimer?.cancel(); recoveryTimer = nil
        watchdogTimer?.cancel(); watchdogTimer = nil
        pingTimer?.cancel(); pingTimer = nil
        statsTimer?.cancel(); statsTimer = nil
        streamLock.lock()
        streamActive = false
        lastBuffer = nil
        streamLock.unlock()
        media?.close(); media = nil
        probeDriver?.cancel(); probeDriver = nil
        probeMediaLock.lock(); probeMedia?.close(); probeMedia = nil; probeMediaLock.unlock()
        history.removeAll()
        let src = source
        source = nil
        let enc = encoder
        encoder = nil
        Task {
            if let s = src { await s.stop() }
            enc?.invalidate()
        }
        channel?.close()
        channel = nil
        setState(.ended(reason))
    }
}

extension HostSession: @unchecked Sendable {}

/// Per-window counters for the `host-stats` log line.
struct HostStatsWindow {
    var captured: UInt64 = 0
    var droppedBusy: UInt64 = 0
    var skippedDivisor: UInt64 = 0
    var encodeIn: UInt64 = 0
    var encodeOut: UInt64 = 0
    var keyframesOut: UInt64 = 0
    var encodeMs: [Double] = []
    var capIvMs: [Double] = []
    var outIvMs: [Double] = []
    var inflightSum: UInt64 = 0
    var framesSent: UInt64 = 0
    var bytes: UInt64 = 0
    var maxFrameBytes: UInt64 = 0
    var nacks: UInt64 = 0
    var retransmits: UInt64 = 0
    var keyframeReqDisplay: UInt64 = 0
    var keyframeReqRecovery: UInt64 = 0
}

// MARK: Automatic link-aware profile (Provisional decision P1, PLAN 6.10)

public extension HostSessionConfig {
    /// A cached link measurement older than this is measured again.
    static let linkProbeMaxAge: TimeInterval = 7 * 24 * 3600

    /// Share of a cached throughput used when the live link check failed (conservative fallback).
    static let fallbackThroughputShare = 0.75

    /// Every connection measures the link (P1, user requirement): the cache is only a fallback when the
    /// measurement fails, and only for the same network. Returns the outcome to apply (nil = G1 defaults)
    /// and whether it is the fallback.
    static func resolveLink(measured: ProbeOutcome?, cached: ProbeOutcome?, networkId: String?,
                            now: Date = Date()) -> (outcome: ProbeOutcome?, fallback: Bool) {
        if let m = measured, m.link.usableThroughputBps > 0 { return (m, false) }
        guard var c = cached, isFresh(c, networkId: networkId, now: now) else { return (nil, false) }
        c.link.trains = c.link.trains.map {
            var t = $0
            t.rateBps = Int(Double(t.rateBps) * fallbackThroughputShare)
            t.deliveryBps = t.deliveryBps.map { Int(Double($0) * fallbackThroughputShare) }
            return t
        }
        c.recommendation = LinkAwareProfile.recommend(panelWidth: c.panelWidth, panelHeight: c.panelHeight,
                                                      hevc: c.recommendation.candidate?.format.codec != .h264,
                                                      link: c.link, interface: c.interface)
        return (c, true)
    }

    /// `networkId`: the current default gateway; a result from another (or unknown) network is stale.
    static func isFresh(_ o: ProbeOutcome, networkId: String?, now: Date = Date()) -> Bool {
        now.timeIntervalSince(o.date) < linkProbeMaxAge && o.link.usableThroughputBps > 0
            && o.networkId != nil && o.networkId == networkId
    }

    /// True when the user changed the format settings away from the defaults; their choice then wins.
    static func userOverridesFormat(_ s: AppSettings) -> Bool {
        let d = AppSettings()
        return s.maxHeight != d.maxHeight || s.fps != d.fps || s.codec != d.codec
    }

    /// Applies a link measurement: the recommended step replaces the default format (unless the user chose
    /// one), the bitrate ceiling and start become 0.6 x throughput (unless the user set a bitrate cap), and
    /// the measured FEC default is used unless one is stored in the settings.
    mutating func applyLink(_ o: ProbeOutcome, settings: AppSettings) {
        let r = o.recommendation
        if let c = r.candidate, !Self.userOverridesFormat(settings) {
            var s = settings
            s.maxHeight = c.format.height >= o.panelHeight ? 0 : c.format.height
            s.fps = c.format.fps
            s.codec = c.format.codec == .h264 ? "h264" : "hevc"
            chooseFormat = { HostSessionConfig.format(for: $0, settings: s) }
            if settings.fecRatio == nil { fecRatio = r.fecRatio }
        }
        let t = o.link.usableThroughputBps
        if t > 0, settings.bitrateCapMbps == 0 { linkThroughputBps = t }
    }

    /// Setup-test config for the automatic link check: short link trains only (0.25 s each, ascending),
    /// stopping at the first train with loss or a stretched arrival (queueing). Target <= 3 s.
    static func linkCheckRun() -> ProbeRunConfig {
        var p = ProbeRunConfig()
        p.candidates = []
        p.trainRatesBps = [10, 20, 40, 80, 160].map { $0 * 1_000_000 }
        p.trainDurationMs = 250
        p.stopWhenSaturated = true
        return p
    }

    /// Replaces the (empty) recommendation of a link-only probe with the link-aware ladder step.
    static func linkOnlyOutcome(_ o: ProbeOutcome, hevc: Bool) -> ProbeOutcome {
        var out = o
        out.recommendation = LinkAwareProfile.recommend(panelWidth: o.panelWidth, panelHeight: o.panelHeight,
                                                        hevc: hevc, link: o.link, interface: o.interface)
        return out
    }
}
