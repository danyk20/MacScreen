import CoreVideo
import Foundation
import Network
import os
import MSCodec
import MSCore
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

    public init() {}

    /// Config from stored settings; the format choice respects the Display's capabilities.
    public init(settings: AppSettings) {
        cursorMode = settings.cursorMode
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
        // Resolution: panel size, optionally reduced to maxHeight keeping aspect; even dimensions.
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
        VideoFormat(codec: c.hwDecodeHEVC ? .hevc : .h264, width: c.panelPixelWidth,
                    height: c.panelPixelHeight, fps: 60, bitDepth: 8)
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
    private var cursorTracker: CursorTracker?
    private var recoveryTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private let pingClock = PingClock()     // media queue only
    private let history = PacketHistory()
    private var ended = false
    private var peerByeReason: String?

    // Shared between capture, encode, media and control queues.
    private let streamLock = NSLock()
    private var lastBuffer: CVPixelBuffer?
    private var lastCaptureArrival: UInt64 = 0
    private var lastSentFrameId: UInt32 = 0
    private var highestDecoded: UInt32 = 0
    private var lastProgress: UInt64 = 0
    private var lastForcedKeyframe: UInt64 = 0
    private var keyframePendingSince: UInt64?
    private var streamActive = false
    private var frameCounter: UInt32 = 0     // encode queue only
    public var framesSent: UInt64 { streamLock.lock(); defer { streamLock.unlock() }; return framesSentValue }
    private var framesSentValue: UInt64 = 0
    private var bytesSentValue: UInt64 = 0
    /// Encoded payload bytes handed to the media channel (before FEC and encryption).
    public var bytesSent: UInt64 { streamLock.lock(); defer { streamLock.unlock() }; return bytesSentValue }
    private var framesDropped: UInt64 = 0

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

    public func stop() {
        queue.async { [self] in finish(.stopped) }
    }

    // MARK: Control

    private func setState(_ s: HostSessionState) {
        stateLock.lock()
        let changed = stateValue != s
        stateValue = s
        stateLock.unlock()
        if changed { onStateChange?(s) }
    }

    private func handleSecured(_ r: HandshakeResult) {
        handshake = r
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
        case .sessionAccept(let a):
            guard state == .negotiating, sessionRequested, media == nil else { return }
            startStreaming(udpPort: a.udpPort)
        default:
            break
        }
    }

    private func sendSessionRequestIfReady() {
        guard state == .negotiating, !sessionRequested, let caps = displayCaps else { return }
        sessionRequested = true
        let f = config.chooseFormat(caps)
        format = f
        let wire = WireVideoFormat(codec: f.codec.rawValue, width: f.width, height: f.height,
                                   fps: f.fps, bitDepth: f.bitDepth)
        channel?.send(.sessionRequest(SessionRequestMessage(format: wire, hiDPI: config.hiDPI,
                                                            cursorMode: config.cursorMode, audio: false,
                                                            fecRatio: config.fecRatio)))
    }

    // MARK: Streaming

    private func startStreaming(udpPort: UInt16) {
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
        streamLock.lock(); currentFec = rc.fecRatio; streamLock.unlock()
        let bitrate = rc.initialBitrate
        do {
            encoder = try VideoEncoder(format: f, bitrate: bitrate) { [weak self] frame in
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
        m.onFailed = { reason in Self.log.debug("media: \(reason, privacy: .public)") }
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
    }

    /// Source thread.
    private func handleCapture(_ pb: CVPixelBuffer, captureTimeMicros: UInt64) {
        guard let enc = encoder else { return }
        streamLock.lock()
        guard streamActive else { streamLock.unlock(); return }
        lastBuffer = pb
        lastCaptureArrival = MonoClock.nowMicros()
        if enc.pendingFrames > 1 {
            framesDropped += 1
            streamLock.unlock()
            return
        }
        if fpsDivisor > 1 {
            captureTick &+= 1
            if captureTick % fpsDivisor != 0 { streamLock.unlock(); return }
        }
        keyframePendingSince = nil
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
            m.sendBatch(frags.map { ($0.type, $0.fragment.encode()) }, paceOverMicros: 4000)
        } catch {
            Self.log.error("fragment failed: \(String(describing: error), privacy: .public)")
            return
        }
        streamLock.lock()
        if lastSentFrameId <= highestDecoded { lastProgress = MonoClock.nowMicros() }
        lastSentFrameId = id
        framesSentValue += 1
        bytesSentValue += payloadBytes
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
        if fb.requestKeyframe, now &- lastForcedKeyframe >= UInt64(MSConstants.keyframeMinIntervalMs) * 1000 {
            lastForcedKeyframe = now
            keyframePendingSince = now
            force = true
        }
        streamLock.unlock()
        if force { encoder?.requestKeyframe() }
        if let out = rate?.ingest(fb, nowMicros: now) { applyRate(out) }
    }

    /// Media queue. Applies bitrate and FEC live; a 30 fps switch is announced on the control channel.
    private func applyRate(_ out: RateController.Output) {
        encoder?.setBitrate(out.bitrate)
        streamLock.lock()
        currentFec = out.fecRatio
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

    /// Control queue, every 10 ms: idle-screen recovery.
    private func recoveryTick() {
        guard !ended, let enc = encoder else { return }
        let now = MonoClock.nowMicros()
        var resend: CVPixelBuffer?
        var force = false
        streamLock.lock()
        if keyframePendingSince == nil, lastSentFrameId > highestDecoded,
           now &- lastProgress >= 200_000,
           now &- lastForcedKeyframe >= UInt64(MSConstants.keyframeMinIntervalMs) * 1000 {
            lastForcedKeyframe = now
            keyframePendingSince = now
            force = true
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
        if state == .awaitingPairingApproval, let r = handshake {
            // Pairing was never confirmed by the Display: forget the key we stored on a matching code.
            try? store.removePeer(identityKey: r.peerIdentityKey)
        }
        cursorTracker?.stop(); cursorTracker = nil
        recoveryTimer?.cancel(); recoveryTimer = nil
        pingTimer?.cancel(); pingTimer = nil
        streamLock.lock()
        streamActive = false
        lastBuffer = nil
        streamLock.unlock()
        media?.close(); media = nil
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
