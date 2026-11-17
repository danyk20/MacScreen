import CoreVideo
import Foundation
import Network
import os
import MSCodec
import MSCore
import MSProbe
import MSProtocol
import MSTransport

/// Display side: advertises, accepts one Host at a time, pairs, receives and decodes video
/// (PLAN.md section 8, T2.10).
public final class DisplaySession {
    private static let log = Log.logger("display")

    fileprivate let store: IdentityStore
    fileprivate let capabilities: CapabilitiesMessage
    fileprivate let sink: DisplaySink
    fileprivate let queue = DispatchQueue(label: "ms.control.display", qos: .userInitiated)
    private var advertiser: DisplayAdvertiser?
    fileprivate var current: Link?
    /// Capture->present latency and per-frame stage times (all connections of this session object).
    public let latency = LatencyRecorder()
    private var busyLinks: [ObjectIdentifier: ControlChannel] = [:]

    public init(identityStore: IdentityStore, capabilities: CapabilitiesMessage, sink: DisplaySink) {
        self.store = identityStore
        self.capabilities = capabilities
        self.sink = sink
    }

    /// TCP port of the control listener once ready.
    public var port: UInt16? { advertiser?.port }

    public func start() throws {
        let id = store.identity
        let adv = DisplayAdvertiser(deviceId: id.deviceId, deviceName: id.deviceName, queue: queue)
        adv.onConnection = { [weak self] conn in self?.handleConnection(conn) }
        advertiser = adv
        try adv.start()
    }

    public func stop() {
        advertiser?.stop()
        advertiser = nil
        queue.async { [self] in
            current?.teardown()
            for (_, c) in busyLinks { c.close() }
            busyLinks.removeAll()
        }
    }

    // MARK: Connections

    private func makeChannel(_ conn: NWConnection) -> ControlChannel {
        let store = self.store
        return ControlChannel(connection: conn, role: .display, identity: store.identity,
                              isKnownPeer: { store.isKnown(identityKey: $0) }, queue: queue)
    }

    private func handleConnection(_ conn: NWConnection) {
        if current != nil {
            let ch = makeChannel(conn)
            let key = ObjectIdentifier(ch)
            busyLinks[key] = ch
            ch.onSecured = { [weak ch] _ in
                ch?.send(.bye(ByeMessage(reason: "busy")))
                ch?.close()
            }
            ch.onClosed = { [weak self] _ in self?.busyLinks[key] = nil }
            ch.start()
            return
        }
        let link = Link(owner: self, channel: makeChannel(conn))
        current = link
        link.start()
    }

    fileprivate func linkEnded(_ l: Link) {
        if current === l { current = nil }
    }

    // MARK: One Host connection

    fileprivate final class Link {
        weak var owner: DisplaySession?
        let ctlQueue: DispatchQueue
        let store: IdentityStore
        let capabilities: CapabilitiesMessage
        let sink: DisplaySink
        let latency: LatencyRecorder
        let channel: ControlChannel
        let mediaQueue = DispatchQueue(label: "ms.media.display", qos: .userInteractive)
        let decodeQueue = DispatchQueue(label: "ms.decode", qos: .userInteractive)

        var probe: ProbeResponder!
        var result: HandshakeResult?
        var paired = false
        var pairRequested = false
        var ended = false
        var announced = false
        var media: MediaServer?
        var decoder: VideoDecoder?
        var decodeTimer: DispatchSourceTimer?
        var feedbackTimer: DispatchSourceTimer?
        var pingTimer: DispatchSourceTimer?
        let pingClock = PingClock()                 // media queue only
        let reassembler = Reassembler()             // decode queue only
        private let rttLock = NSLock()
        private var rttValue: Double?
        /// Smoothed RTT from `PingClock`; written on the media queue, read on the decode queue.
        var rttMs: Double? { rttLock.lock(); defer { rttLock.unlock() }; return rttValue }
        var wantsKeyframe = true                    // decode queue only
        var highestDecoded: UInt32 = 0              // decode queue only
        var framesDropped: UInt32 = 0               // decode queue only
        // display-stats window (decode queue only).
        var feedbackCount = 0
        var nacksSent: UInt64 = 0
        var kfRequestFeedbacks: UInt64 = 0
        var decoderRejects: UInt64 = 0
        var lastStat: (mc: MediaCounters, rc: Reassembler.Counters, decoded: UInt64, dropped: UInt32)?
        var closed = false                          // decode queue only
        var firstFragAt: [UInt32: UInt64] = [:]     // decode queue only: frameId -> first fragment arrival
        var jitter = InterarrivalJitter()           // decode queue only: RFC 3550, per frame (P1)

        private let statLock = NSLock()
        private var framesDecoded: UInt32 = 0
        private var decodeMsMean: Double = 0

        init(owner: DisplaySession, channel: ControlChannel) {
            self.owner = owner
            self.channel = channel
            self.ctlQueue = owner.queue
            self.store = owner.store
            self.capabilities = owner.capabilities
            self.sink = owner.sink
            self.latency = owner.latency
        }

        func start() {
            probe = ProbeResponder(
                sendControl: { [weak self] m in self?.channel.send(m) },
                openMedia: { [weak self] in self?.ctlQueue.async { self?.openMediaForProbe() } })
            channel.onSecured = { [weak self] r in self?.secured(r) }
            channel.onMessage = { [weak self] m in self?.message(m) }
            channel.onClosed = { [weak self] reason in
                Display_log("control closed: \(reason)")
                self?.teardown()
            }
            channel.start()
        }

        func secured(_ r: HandshakeResult) {
            result = r
            paired = r.peerWasKnown
            Display_log("secured with \(r.peerDeviceName): known=\(r.peerWasKnown)")
            if paired { becamePaired() }
        }

        func becamePaired() {
            guard let r = result else { return }
            announced = true
            sink.sessionStarted(hostName: r.peerDeviceName)
            channel.send(.capabilities(capabilities))
        }

        func message(_ m: ControlMessage) {
            guard let r = result else { return }
            switch m {
            case .pairRequest:
                pairRequested = true
                Display_log("pairRequest from \(r.peerDeviceName): showing code")
                sink.showPairingCode(r.pairingCode, hostName: r.peerDeviceName)
            case .pairConfirm:
                guard pairRequested else { return }
                pairRequested = false
                sink.hidePairingCode()
                Display_log("pairConfirm from \(r.peerDeviceName): asking to allow")
                sink.askAllow(hostName: r.peerDeviceName) { [weak self] accepted in
                    self?.ctlQueue.async { self?.pairingDecided(accepted) }
                }
            default:
                guard paired else {
                    Display_log("message \(m.typeCode) before pairing")
                    channel.send(.bye(ByeMessage(reason: "not-paired")))
                    teardown()
                    return
                }
                if probe.handle(m) { return }
                if case .sessionRequest(let req) = m { startStreaming(req) }
                else if case .cursorImage(let ci) = m { sink.cursorImage(ci) }
                else if case .hostState(let hs) = m { sink.hostState(hs) }
            }
        }

        func pairingDecided(_ accepted: Bool) {
            Display_log("pairing decided: accepted=\(accepted) linkEnded=\(ended)")
            guard !ended, let r = result else { return }
            if accepted {
                do {
                    try store.addPeer(Peer(deviceId: r.peerDeviceId, deviceName: r.peerDeviceName,
                                           identityKey: r.peerIdentityKey, pairedAt: Date()))
                } catch {
                    Display_log("identity store: \(error)", error: true)
                }
                paired = true
            }
            channel.send(.pairResult(PairResultMessage(accepted: accepted)))
            if accepted {
                becamePaired()
            } else {
                // Let the denial reach the Host before the socket is cancelled.
                ctlQueue.asyncAfter(deadline: .now() + .milliseconds(300)) { [self] in teardown() }
            }
        }

        // MARK: Streaming

        func startStreaming(_ req: SessionRequestMessage) {
            guard media == nil, let r = result else { return }
            Display_log("sessionRequest \(req.format.codec) \(req.format.width)x\(req.format.height)@\(req.format.fps) hiDPI=\(req.hiDPI) cursor=\(req.cursorMode)")
            guard let codec = Codec(rawValue: req.format.codec) else {
                channel.send(.bye(ByeMessage(reason: "bad-format")))
                teardown()
                return
            }
            let dec = VideoDecoder(codec: codec) { [weak self] pb, t, ms in
                guard let self = self else { return }
                self.statLock.lock()
                self.framesDecoded &+= 1
                self.decodeMsMean += (ms - self.decodeMsMean) / 8
                self.statLock.unlock()
                let now = MonoClock.nowMicros()
                Signpost.end("decode", id: t)
                self.latency.decodeDone(captureMicros: t, atMicros: now)
                self.sink.present(pb, captureTimeMicros: t)
            }
            decoder = dec
            let server = MediaServer(sealKey: r.keys.medD2H, openKey: r.keys.medH2D, queue: mediaQueue)
            server.onPacket = { [weak self] type, payload in self?.mediaPacket(type, payload) }
            server.onListening = { [weak self] port in
                guard let self = self else { return }
                self.ctlQueue.async {
                    guard !self.ended else { return }
                    Display_log("media listening on \(port), sending sessionAccept")
                    self.channel.send(.sessionAccept(SessionAcceptMessage(udpPort: port)))
                }
            }
            media = server
            do { try server.start() } catch {
                Display_log("media server failed: \(error)", error: true)
                channel.send(.bye(ByeMessage(reason: "media-failed")))
                teardown()
                return
            }
            startTimers()
        }

        /// Setup test: listen for UDP without a decoder, so the Host can send link probe trains.
        func openMediaForProbe() {
            guard !ended, let r = result else { return }
            if let m = media {
                if let p = m.port { channel.send(.sessionAccept(SessionAcceptMessage(udpPort: p))) }
                return
            }
            let server = MediaServer(sealKey: r.keys.medD2H, openKey: r.keys.medH2D, queue: mediaQueue)
            server.onPacket = { [weak self] type, payload in self?.mediaPacket(type, payload) }
            server.onListening = { [weak self] port in
                guard let self = self else { return }
                self.ctlQueue.async {
                    guard !self.ended else { return }
                    self.channel.send(.sessionAccept(SessionAcceptMessage(udpPort: port)))
                }
            }
            media = server
            do { try server.start() } catch {
                channel.send(.bye(ByeMessage(reason: "media-failed")))
                teardown()
            }
        }

        func startTimers() {
            let dt = DispatchSource.makeTimerSource(queue: decodeQueue)
            dt.schedule(deadline: .now(), repeating: .milliseconds(5))
            dt.setEventHandler { [weak self] in
                guard let self = self, !self.closed else { return }
                self.process(self.reassembler.tick(nowMicros: MonoClock.nowMicros(), rttMs: self.rttMs))
            }
            decodeTimer = dt
            dt.resume()

            let ft = DispatchSource.makeTimerSource(queue: decodeQueue)
            ft.schedule(deadline: .now() + .milliseconds(MSConstants.feedbackIntervalMs),
                        repeating: .milliseconds(MSConstants.feedbackIntervalMs))
            ft.setEventHandler { [weak self] in
                guard let self = self, !self.closed else { return }
                self.sendFeedback()
            }
            feedbackTimer = ft
            ft.resume()

            let pt = DispatchSource.makeTimerSource(queue: mediaQueue)
            pt.schedule(deadline: .now(), repeating: .milliseconds(MSConstants.pingIntervalMs))
            pt.setEventHandler { [weak self] in
                guard let self = self, let m = self.media else { return }
                m.send(.ping, self.pingClock.makePing(nowMicros: MonoClock.nowMicros()).encode())
            }
            pingTimer = pt
            pt.resume()
        }

        /// Media queue.
        func mediaPacket(_ type: PacketType, _ payload: Data) {
            switch type {
            case .videoData, .videoParity:
                let arrived = MonoClock.nowMicros()
                Signpost.begin("receive", id: UInt64(payload.count) &+ arrived)
                defer { Signpost.end("receive", id: UInt64(payload.count) &+ arrived) }
                guard let frag = try? VideoFragment.decode(payload) else { return }
                decodeQueue.async { [weak self] in
                    guard let self = self, !self.closed else { return }
                    if self.firstFragAt[frag.frameId] == nil {
                        self.firstFragAt[frag.frameId] = arrived
                        self.jitter.add(key: frag.frameId, sentMicros: frag.captureTimeMicros, arrivedMicros: arrived)
                        Signpost.begin("reassemble", id: UInt64(frag.frameId))
                        if self.firstFragAt.count > 64 {
                            for k in self.firstFragAt.keys.sorted().prefix(self.firstFragAt.count - 64) {
                                self.firstFragAt[k] = nil
                            }
                        }
                    }
                    self.process(self.reassembler.ingest(type: type, fragment: frag,
                                                         nowMicros: MonoClock.nowMicros(), rttMs: self.rttMs))
                }
            case .linkProbe:
                probe.handleLinkPacket(payload)
            case .audio:
                if let p = try? AudioPacket.decode(payload) { sink.audioPacket(p) }
            case .cursor:
                if let p = try? CursorPacket.decode(payload) { sink.cursorPosition(p) }
            case .ping:
                if let p = try? PingPacket.decode(payload) {
                    let t1 = MonoClock.nowMicros()
                    media?.send(.pong, pingClock.handlePing(p, receivedAtMicros: t1,
                                                            sendingAtMicros: MonoClock.nowMicros()).encode())
                }
            case .pong:
                if let p = try? PongPacket.decode(payload) {
                    pingClock.handlePong(p, nowMicros: MonoClock.nowMicros())
                    latency.setClockOffset(pingClock.offsetMicros)
                    if let off = pingClock.offsetMicros { sink.hostClockOffset(off) }
                    let r = pingClock.rttMs
                    rttLock.lock(); rttValue = r; rttLock.unlock()
                }
            default:
                break
            }
        }

        /// Decode queue.
        func process(_ events: [Reassembler.Event]) {
            for e in events {
                switch e {
                case .frame(let id, let payload, let isKey, let captureT):
                    let complete = MonoClock.nowMicros()
                    Signpost.end("reassemble", id: UInt64(id))
                    latency.frameComplete(frameId: id, captureMicros: captureT,
                                          firstFragMicros: firstFragAt.removeValue(forKey: id) ?? complete,
                                          completeMicros: complete)
                    do {
                        let f = try FramePayload.decode(payload, isKeyframe: isKey, captureTimeMicros: captureT)
                        Signpost.begin("decode", id: captureT)
                        latency.decodeStarted(captureMicros: captureT, atMicros: MonoClock.nowMicros())
                        try decoder?.decode(f)
                        highestDecoded = id
                        if isKey { wantsKeyframe = false }
                    } catch {
                        Display_log("decoder rejected frame \(id): \(error)")
                        framesDropped &+= 1
                        decoderRejects &+= 1
                        wantsKeyframe = true
                        process(reassembler.forceKeyframeResync(nowMicros: MonoClock.nowMicros()))
                    }
                case .requestKeyframe:
                    wantsKeyframe = true
                    sendFeedback()
                case .frameLost:
                    framesDropped &+= 1
                case .nack(let n):
                    nacksSent &+= 1
                    media?.send(.nack, n.encode())
                }
            }
        }

        func sendFeedback() {
            let c = reassembler.counters
            // Loss comes from the media packet counter gaps (pre-FEC, all H->D packets), not from
            // Reassembler.fragsLostEstimate, which over-counts when FEC is on.
            let mc = media?.counters ?? MediaCounters()
            statLock.lock()
            let decoded = framesDecoded
            let ms = decodeMsMean
            statLock.unlock()
            let fb = FeedbackPacket(highestDecodedFrame: highestDecoded, framesDecoded: decoded,
                                    framesDropped: framesDropped,
                                    fragsReceived: UInt32(truncatingIfNeeded: mc.packetsReceived),
                                    fragsLost: UInt32(truncatingIfNeeded: mc.packetsLost),
                                    fragsRecovered: UInt32(truncatingIfNeeded: c.fragsRecovered),
                                    avgDecodeMs: ms, jitterMs: jitter.jitterMs,
                                    requestKeyframe: wantsKeyframe || reassembler.awaitingKeyframe)
            media?.send(.feedback, fb.encode())
            if fb.requestKeyframe { kfRequestFeedbacks &+= 1 }
            feedbackCount += 1
            if feedbackCount % (2000 / MSConstants.feedbackIntervalMs) == 0 {
                logStats(mc: mc, rc: c, decoded: UInt64(decoded))
            }
        }

        /// Decode queue, every 2 s: one `display-stats` line with per-stage counts for the window.
        func logStats(mc: MediaCounters, rc: Reassembler.Counters, decoded: UInt64) {
            let p = lastStat ?? (MediaCounters(), Reassembler.Counters(), 0, 0)
            lastStat = (mc, rc, decoded, framesDropped)
            let line = "2s pkts rx=\(mc.packetsReceived &- p.mc.packetsReceived) lost=\(mc.packetsLost &- p.mc.packetsLost) "
                + "rxMbps=\(String(format: "%.1f", Double(mc.bytesReceived &- p.mc.bytesReceived) * 8 / 2 / 1e6)) "
                + "fecRecovered=\(rc.fragsRecovered &- p.rc.fragsRecovered) dup=\(rc.fragsDuplicate &- p.rc.fragsDuplicate) "
                + "frames complete=\(rc.framesDelivered &- p.rc.framesDelivered) lost=\(rc.framesLost &- p.rc.framesLost) "
                + "decoded=\(decoded &- p.decoded) dropped=\(framesDropped &- p.dropped) rejects=\(decoderRejects) "
                + "nacks=\(nacksSent) kfReqFb=\(kfRequestFeedbacks) rtt=\(String(format: "%.0f", rttMs ?? -1)) "
                + "jitter=\(String(format: "%.1f", jitter.jitterMs))"
            Log.logger("display-stats").notice("\(line, privacy: .public)")
        }

        // MARK: Teardown (control queue)

        func teardown() {
            guard !ended else { return }
            ended = true
            Display_log("link teardown (announced=\(announced))")
            probe?.stop()
            decodeTimer?.cancel(); decodeTimer = nil
            feedbackTimer?.cancel(); feedbackTimer = nil
            pingTimer?.cancel(); pingTimer = nil
            media?.close(); media = nil
            let dec = decoder
            decoder = nil
            decodeQueue.async { [self] in
                closed = true
                dec?.invalidate()
            }
            channel.close()
            sink.hidePairingCode()
            if announced { sink.sessionEnded() }
            owner?.linkEnded(self)
        }
    }
}

private func Display_log(_ s: String, error: Bool = false) {
    if error { Log.logger("display").error("\(s, privacy: .public)") }
    else { Log.logger("display").notice("\(s, privacy: .public)") }
}
