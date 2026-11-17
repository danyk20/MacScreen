import XCTest
import Network
import CoreVideo
import CryptoKit
import MSCore
import MSProtocol
import MSTransport
import MSDisplay

private final class Locked<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
}

private final class RecordingSink: DisplaySink {
    let codes = Locked<[String]>([])
    let asked = Locked(0)
    let started = Locked(0)
    let cursorImages = Locked(0)
    let hostStates = Locked(0)
    /// When set, `askAllow` parks its completion here instead of answering.
    let hold = Locked(false)
    let pending = Locked<((Bool) -> Void)?>(nil)
    let answer = Locked(true)

    func present(_ pixelBuffer: CVPixelBuffer, captureTimeMicros: UInt64) {}
    func showPairingCode(_ code: String, hostName: String) { codes.mutate { $0.append(code) } }
    func hidePairingCode() {}
    func askAllow(hostName: String, completion: @escaping (Bool) -> Void) {
        asked.mutate { $0 += 1 }
        if hold.get() { pending.mutate { $0 = completion } } else { completion(answer.get()) }
    }
    func sessionStarted(hostName: String) { started.mutate { $0 += 1 } }
    func sessionEnded() {}
    func cursorImage(_ image: CursorImageMessage) { cursorImages.mutate { $0 += 1 } }
    func hostState(_ state: HostStateMessage) { hostStates.mutate { $0 += 1 } }
}

/// A raw Host: real handshake, then whatever messages the test wants to send.
private final class RawHost {
    let id: Identity
    let conn: NWConnection
    private let rx = Locked(Data())
    private var framer = ControlFramer()
    private var sealer: ControlSealer!
    private var opener: ControlOpener!
    var result: HandshakeResult!
    let closed = Locked(false)

    init(port: UInt16, identity: Identity? = nil) throws {
        id = identity ?? Identity(deviceId: UUID().uuidString, deviceName: "Raw Host", signingKey: Curve25519.Signing.PrivateKey())
        conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: ControlChannel.tcpParameters())
        let ready = DispatchSemaphore(value: 0)
        conn.stateUpdateHandler = { [closed] s in
            switch s {
            case .ready: ready.signal()
            case .failed, .cancelled: closed.mutate { $0 = true }
            default: break
            }
        }
        conn.start(queue: DispatchQueue(label: "test.rawhost"))
        guard ready.wait(timeout: .now() + 5) == .success else { throw XCTSkip("cannot connect") }
        pump()
    }

    deinit { conn.cancel() }

    private func pump() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
            guard let self = self else { return }
            if let d = d { self.rx.mutate { $0.append(d) } }
            if done || err != nil { self.closed.mutate { $0 = true } }
            if err == nil && !done { self.pump() }
        }
    }

    private func rawFrame(timeout: TimeInterval) -> (typeCode: UInt8, body: Data)? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let chunk = rx.get()
            if !chunk.isEmpty { rx.mutate { $0.removeAll() }; framer.append(chunk) }
            if let f = try? framer.next() { return f }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    func handshake(knownByHost: Bool = false) throws {
        let hh = HostHandshake(identity: id, isKnownPeer: { _ in knownByHost })
        func put(_ m: ControlMessage) throws {
            conn.send(content: ControlFramer.frame(typeCode: m.typeCode, body: try m.encodeBody()),
                      completion: .contentProcessed { _ in })
        }
        try put(.hello(hh.makeHello()))
        let a = try XCTUnwrap(rawFrame(timeout: 5))
        guard case .helloReply(let reply) = try ControlMessage.decode(typeCode: a.typeCode, body: a.body) else {
            throw XCTSkip("no helloReply")
        }
        try put(.reveal(try hh.handleHelloReply(reply)))
        let b = try XCTUnwrap(rawFrame(timeout: 5))
        guard case .revealReply(let rr) = try ControlMessage.decode(typeCode: b.typeCode, body: b.body) else {
            throw XCTSkip("no revealReply")
        }
        result = try hh.handleRevealReply(rr)
        sealer = ControlSealer(key: result.keys.ctlH2D)
        opener = ControlOpener(key: result.keys.ctlD2H)
    }

    func send(_ m: ControlMessage) throws {
        let sealed = try sealer.seal(try m.encodeBody())
        conn.send(content: ControlFramer.frame(typeCode: m.typeCode, body: sealed), completion: .contentProcessed { _ in })
    }

    /// Next non-keepalive message from the Display.
    func receive(timeout: TimeInterval = 5) throws -> ControlMessage? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            guard let f = rawFrame(timeout: max(0.05, end.timeIntervalSinceNow)) else { return nil }
            let m = try ControlMessage.decode(typeCode: f.typeCode, body: try opener.open(f.body))
            if m != .keepalive { return m }
        }
        return nil
    }

    func waitClosed(timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !closed.get() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        return closed.get()
    }
}

final class DisplayPrePairingTests: XCTestCase {
    private var dirs: [URL] = []
    private var sessions: [DisplaySession] = []

    override func tearDown() {
        for s in sessions { s.stop() }
        sessions = []
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func store() throws -> IdentityStore {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ms-pp-\(UUID().uuidString)")
        dirs.append(d)
        return try IdentityStore(directory: d, defaultDeviceName: "Display")
    }

    private func start(_ store: IdentityStore, _ sink: RecordingSink, limits: DisplayLimits = DisplayLimits(),
                       clock: (() -> Double)? = nil) throws -> UInt16 {
        let caps = CapabilitiesMessage(role: "display", deviceName: "D", osVersion: "t", panelPixelWidth: 1280,
                                       panelPixelHeight: 720, panelWidthMM: 600, panelHeightMM: 340, backingScale: 2,
                                       edrHeadroom: 1, refreshHz: 60, hwDecodeH264: true, hwDecodeHEVC: true,
                                       hwEncodeH264: true, hwEncodeHEVC: true, wideColor: false)
        let d = clock.map { DisplaySession(identityStore: store, capabilities: caps, sink: sink, limits: limits, clock: $0) }
            ?? DisplaySession(identityStore: store, capabilities: caps, sink: sink, limits: limits)
        try d.start()
        sessions.append(d)
        let end = Date().addingTimeInterval(10)
        while d.port == nil && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        return try XCTUnwrap(d.port)
    }

    private func wait(_ what: String, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !cond() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(cond(), "timed out: \(what)")
    }

    private func expectNotPairedBye(_ h: RawHost, file: StaticString = #filePath, line: UInt = #line) throws {
        let m = try h.receive()
        XCTAssertEqual(m, .bye(ByeMessage(reason: "not-paired")), file: file, line: line)
        XCTAssertTrue(h.waitClosed(), file: file, line: line)
    }

    /// Before pairing only pairRequest/pairConfirm (and bye) are acceptable: everything else ends the link
    /// with `not-paired`, reaches no sink, and stores nothing.
    func testEveryNonPairingMessageBeforePairingIsRefused() throws {
        let png = Data(repeating: 1, count: 6 * 1024 * 1024)  // oversized cursor image
        let fmt = WireVideoFormat(codec: 2, width: 3840, height: 2160, fps: 60, bitDepth: 10)
        let messages: [ControlMessage] = [
            .sessionRequest(SessionRequestMessage(format: fmt, hiDPI: true, cursorMode: "overlay", audio: true, fecRatio: 0.1)),
            .cursorImage(CursorImageMessage(id: 1, png: png, hotX: 0, hotY: 0, widthPt: 1, heightPt: 1)),
            .hostState(HostStateMessage(displayAsleep: true, mirroring: true)),
            .probeBlob(Data(repeating: 9, count: 1_000_000)),
            .linkProbeStart(LinkProbeStartMessage(trainId: 1, rateBps: Int.max, durationMs: Int.max, packetCount: Int.max)),
            .linkProbeStart(LinkProbeStartMessage(trainId: 0, rateBps: 0, durationMs: 0, packetCount: 0)),
            .reconfigure(ReconfigureMessage(format: fmt)),
            .capabilities(CapabilitiesMessage(role: "host", deviceName: "x", osVersion: "x", panelPixelWidth: 0,
                panelPixelHeight: 0, panelWidthMM: 0, panelHeightMM: 0, backingScale: 0, edrHeadroom: 0, refreshHz: 0,
                hwDecodeH264: false, hwDecodeHEVC: false, hwEncodeH264: false, hwEncodeHEVC: false, wideColor: false)),
            .pairResult(PairResultMessage(accepted: true)),
            .sessionAccept(SessionAcceptMessage(udpPort: 1)),
            .probeResult(ProbeResultMessage(json: Data())),
        ]
        let st = try store()
        let sink = RecordingSink()
        let port = try start(st, sink)
        for m in messages {
            let h = try RawHost(port: port)
            try h.handshake()
            XCTAssertFalse(h.result.peerWasKnown)
            try h.send(m)
            try expectNotPairedBye(h)
        }
        XCTAssertEqual(sink.started.get(), 0)
        XCTAssertEqual(sink.cursorImages.get(), 0)
        XCTAssertEqual(sink.hostStates.get(), 0)
        XCTAssertEqual(sink.asked.get(), 0)
        XCTAssertTrue(st.peers.isEmpty)
    }

    func testPairConfirmWithoutPairRequestIsIgnoredAndCodeMatches() throws {
        let st = try store()
        let sink = RecordingSink()
        let h = try RawHost(port: try start(st, sink))
        try h.handshake()
        try h.send(.pairConfirm(PairConfirmMessage()))   // no pairRequest yet: ignored, link stays up
        try h.send(.pairRequest(PairRequestMessage()))
        wait("code shown") { !sink.codes.get().isEmpty }
        XCTAssertEqual(sink.codes.get(), [h.result.pairingCode])
        XCTAssertEqual(sink.asked.get(), 0, "an unsolicited pairConfirm must not raise the Allow dialog")
        XCTAssertFalse(h.closed.get())
        XCTAssertTrue(st.peers.isEmpty)
    }

    func testHostKeyIsNotStoredUntilUserAllows() throws {
        let st = try store()
        let sink = RecordingSink()
        sink.hold.mutate { $0 = true }
        let h = try RawHost(port: try start(st, sink))
        try h.handshake()
        try h.send(.pairRequest(PairRequestMessage()))
        wait("code") { !sink.codes.get().isEmpty }
        try h.send(.pairConfirm(PairConfirmMessage()))
        wait("allow dialog") { sink.asked.get() == 1 }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(st.peers.isEmpty, "stored before the user answered")
        XCTAssertFalse(st.isKnown(identityKey: h.id.publicKey))
        // While the dialog is open the Host still cannot start streaming.
        let fmt = WireVideoFormat(codec: 1, width: 640, height: 360, fps: 30, bitDepth: 8)
        try h.send(.sessionRequest(SessionRequestMessage(format: fmt, hiDPI: false, cursorMode: "embedded", audio: false, fecRatio: 0)))
        try expectNotPairedBye(h)
        XCTAssertTrue(st.peers.isEmpty)
        XCTAssertEqual(sink.started.get(), 0)
    }

    func testDenyStoresNothingAndAllowStoresAfterAnswer() throws {
        // Deny.
        let st = try store()
        let sink = RecordingSink()
        sink.answer.mutate { $0 = false }
        let h = try RawHost(port: try start(st, sink))
        try h.handshake()
        try h.send(.pairRequest(PairRequestMessage()))
        try h.send(.pairConfirm(PairConfirmMessage()))
        XCTAssertEqual(try h.receive(), .pairResult(PairResultMessage(accepted: false)))
        XCTAssertTrue(st.peers.isEmpty)
        XCTAssertEqual(sink.started.get(), 0)

        // Allow.
        let st2 = try store()
        let sink2 = RecordingSink()
        let h2 = try RawHost(port: try start(st2, sink2))
        try h2.handshake()
        try h2.send(.pairRequest(PairRequestMessage()))
        try h2.send(.pairConfirm(PairConfirmMessage()))
        XCTAssertEqual(try h2.receive(), .pairResult(PairResultMessage(accepted: true)))
        XCTAssertEqual(st2.peers.map { $0.identityKey }, [h2.id.publicKey])
        wait("started") { sink2.started.get() == 1 }
        if case .capabilities? = try h2.receive() {} else { XCTFail("expected capabilities after pairing") }
    }

    func testByeBeforePairingIsAcceptedQuietly() throws {
        let st = try store()
        let sink = RecordingSink()
        let h = try RawHost(port: try start(st, sink))
        try h.handshake()
        try h.send(.bye(ByeMessage(reason: "done")))
        XCTAssertTrue(h.waitClosed())
        XCTAssertTrue(st.peers.isEmpty)
        XCTAssertEqual(sink.started.get(), 0)
    }

    func testPairedHostBadFormatAndRepeatedRequestsDoNotCrash() throws {
        let st = try store()
        let sink = RecordingSink()
        let port = try start(st, sink)
        // Pre-pair the raw host: the Display already knows its key.
        let h = try RawHost(port: port)
        try st.addPeer(Peer(deviceId: h.id.deviceId, deviceName: "Raw Host", identityKey: h.id.publicKey, pairedAt: Date()))
        try h.handshake(knownByHost: true)
        XCTAssertTrue(h.result.peerWasKnown)
        if case .capabilities? = try h.receive() {} else { XCTFail("expected capabilities") }
        // Unknown codec: bye bad-format.
        let bad = WireVideoFormat(codec: 77, width: Int.max, height: Int.min, fps: -1, bitDepth: 0)
        try h.send(.sessionRequest(SessionRequestMessage(format: bad, hiDPI: true, cursorMode: "\u{0}", audio: true, fecRatio: 1e300)))
        XCTAssertEqual(try h.receive(), .bye(ByeMessage(reason: "bad-format")))
        XCTAssertTrue(h.waitClosed())
    }

    // MARK: Connection abuse limits

    func testIdleUnauthenticatedConnectionsAreDroppedAndDoNotBlockPairedHost() throws {
        var lim = DisplayLimits(); lim.handshakeTimeoutS = 0.5
        let st = try store()
        let sink = RecordingSink()
        let port = try start(st, sink, limits: lim)
        let idle = try RawHost(port: port)          // never speaks
        let a = try RawHost(port: port)
        try st.addPeer(Peer(deviceId: a.id.deviceId, deviceName: "A", identityKey: a.id.publicKey, pairedAt: Date()))
        try a.handshake(knownByHost: true)           // not blocked by the idle connection
        if case .capabilities? = try a.receive() {} else { XCTFail("expected capabilities") }
        XCTAssertTrue(idle.waitClosed(timeout: 2), "idle connection must be dropped after the handshake timeout")
        // A is authenticated and keeps its slot; an unauthenticated idle peer does not bump it.
        let idle2 = try RawHost(port: port)
        XCTAssertTrue(idle2.waitClosed(timeout: 2))
        XCTAssertFalse(a.closed.get())
        // A second authenticated host is told busy.
        let c = try RawHost(port: port)
        try c.handshake()
        XCTAssertEqual(try c.receive(), .bye(ByeMessage(reason: "busy")))
        XCTAssertFalse(a.closed.get())
    }

    func testUnsecuredLinkCap() throws {
        var lim = DisplayLimits(); lim.maxUnsecuredLinks = 2; lim.handshakeTimeoutS = 30
        let port = try start(try store(), RecordingSink(), limits: lim)
        let hosts = try (0..<5).map { _ in try RawHost(port: port) }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(hosts.filter { $0.closed.get() }.count, 3, "connections beyond the cap are closed at once")
    }

    func testPerIPRateLimitBlocksAndRecoversWithClock() throws {
        var lim = DisplayLimits(); lim.exemptLoopback = false; lim.rateMaxConnections = 3
        lim.rateWindowS = 10; lim.rateBlockS = 30; lim.handshakeTimeoutS = 30
        let now = Locked(100.0)
        let port = try start(try store(), RecordingSink(), limits: lim, clock: { now.get() })
        let first = try (0..<2).map { _ in try RawHost(port: port) }   // 2 allowed, 3rd trips the limit
        let third = try RawHost(port: port)
        XCTAssertTrue(third.waitClosed(timeout: 2))
        XCTAssertFalse(first.contains { $0.closed.get() })
        now.mutate { $0 += 20 }
        let blocked = try RawHost(port: port)
        XCTAssertTrue(blocked.waitClosed(timeout: 2), "still blocked 20 s later")
        now.mutate { $0 += 20 }
        let ok = try RawHost(port: port)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(ok.closed.get(), "allowed again after the block expired")
    }

    func testRateLimiterUnit() {
        var t = 0.0
        var l = ConnectionRateLimiter(maxConnections: 10, window: 10, blockFor: 30, clock: { t })
        for _ in 0..<9 { XCTAssertTrue(l.allow("a")); t += 0.1 }
        XCTAssertFalse(l.allow("a"))
        XCTAssertTrue(l.allow("b"))
        t += 29; XCTAssertFalse(l.allow("a"))
        t += 2; XCTAssertTrue(l.allow("a"))
    }

    // MARK: Pairing dialog abuse

    func testRepeatedPairingMessagesRaiseOneAllowDialog() throws {
        let st = try store()
        let sink = RecordingSink()
        sink.hold.mutate { $0 = true }
        let h = try RawHost(port: try start(st, sink))
        try h.handshake()
        try h.send(.pairRequest(PairRequestMessage()))
        wait("code") { sink.codes.get().count == 1 }
        try h.send(.pairConfirm(PairConfirmMessage()))
        wait("dialog") { sink.asked.get() == 1 }
        for _ in 0..<5 {
            try h.send(.pairRequest(PairRequestMessage()))
            try h.send(.pairConfirm(PairConfirmMessage()))
        }
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(sink.asked.get(), 1)
        XCTAssertEqual(sink.codes.get().count, 1)
        XCTAssertFalse(h.closed.get())
    }

    func testDeniedKeyIsRefusedFor60sThenAllowed() throws {
        let st = try store()
        let sink = RecordingSink()
        sink.answer.mutate { $0 = false }
        let now = Locked(1000.0)
        let port = try start(st, sink, clock: { now.get() })
        let h = try RawHost(port: port)
        try h.handshake()
        try h.send(.pairRequest(PairRequestMessage()))
        try h.send(.pairConfirm(PairConfirmMessage()))
        XCTAssertEqual(try h.receive(), .pairResult(PairResultMessage(accepted: false)))
        XCTAssertTrue(h.waitClosed())
        XCTAssertEqual(sink.asked.get(), 1)

        // Same identity key again: refused, no code, no dialog.
        now.mutate { $0 += 30 }
        let h2 = try RawHost(port: port, identity: h.id)
        try h2.handshake()
        try h2.send(.pairRequest(PairRequestMessage()))
        XCTAssertEqual(try h2.receive(), .bye(ByeMessage(reason: "pairing-denied")))
        XCTAssertEqual(sink.codes.get().count, 1)
        XCTAssertEqual(sink.asked.get(), 1)

        // A different key is unaffected.
        let other = try RawHost(port: port)
        try other.handshake()
        try other.send(.pairRequest(PairRequestMessage()))
        wait("other code") { sink.codes.get().count == 2 }
        other.conn.cancel()
        XCTAssertTrue(other.waitClosed())

        // After the cooldown the key may try again.
        now.mutate { $0 += 31 }
        let h3 = try RawHost(port: port, identity: h.id)
        try h3.handshake()
        try h3.send(.pairRequest(PairRequestMessage()))
        wait("code after cooldown") { sink.codes.get().count == 3 }
    }
}
