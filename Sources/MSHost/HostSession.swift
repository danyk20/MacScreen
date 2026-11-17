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
    /// Setup test: when set, the session runs the probe (PLAN 6.10) instead of streaming, then ends.
    public var probe: ProbeRunConfig?
    /// Requests audio (PLAN 6.9) and captures it once streaming. Off by default.
    public var audioEnabled = false
    /// Test hook: replaces the AUHAL input on the "MacScreen Display" device.
    public var makeAudioSource: (() -> AudioInputSource)?

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
            guard code.trimmingCharacters(in: .whitespaces) == r.pairingCode else {
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
        let rc = RateController(profileBitrate: profileBitrate, linkFecRatio: config.fecRatio)
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
        Self.statsLog.notice("\(line, privacy: .public)")
    }

    /// Source thread.
    private func handleCapture(_ pb: CVPixelBuffer, captureTimeMicros: UInt64) {
        guard let enc = encoder else { return }
        streamLock.lock()
        guard streamActive else { streamLock.unlock(); return }
        lastBuffer = pb
        lastCaptureArrival = MonoClock.nowMicros()
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
                                                fecRatio: fec)
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
    var framesSent: UInt64 = 0
    var bytes: UInt64 = 0
    var maxFrameBytes: UInt64 = 0
    var nacks: UInt64 = 0
    var retransmits: UInt64 = 0
    var keyframeReqDisplay: UInt64 = 0
    var keyframeReqRecovery: UInt64 = 0
}
