import XCTest
import Network
import CryptoKit
import MSCore
import MSProtocol
@testable import MSTransport

private final class Box<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
}

/// Loopback TCP listener on an ephemeral port, no Bonjour.
private final class Loopback {
    let listener: NWListener
    let port: NWEndpoint.Port
    let queue = DispatchQueue(label: "test.listener")

    init(onConnection: @escaping (NWConnection) -> Void) throws {
        listener = try NWListener(using: ControlChannel.tcpParameters(), on: .any)
        listener.newConnectionHandler = onConnection
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { sem.signal() } }
        listener.start(queue: queue)
        guard sem.wait(timeout: .now() + 5) == .success, let p = listener.port else {
            throw XCTSkip("listener did not become ready")
        }
        port = p
    }

    func connect() -> NWConnection {
        NWConnection(to: .hostPort(host: "127.0.0.1", port: port), using: ControlChannel.tcpParameters())
    }

    deinit { listener.cancel() }
}

private func makeIdentity(_ name: String) -> Identity {
    Identity(deviceId: UUID().uuidString, deviceName: name, signingKey: Curve25519.Signing.PrivateKey())
}

/// A host channel and a display channel connected over loopback.
private final class Pair {
    let ctlQueue = DispatchQueue(label: "ms.control.test")
    let hostId = makeIdentity("Host")
    let displayId = makeIdentity("Display")
    var loop: Loopback!
    var host: ControlChannel!
    var display: ControlChannel!

    let hostSecured = Box<HandshakeResult?>(nil)
    let displaySecured = Box<HandshakeResult?>(nil)
    let hostClosed = Box<[ControlCloseReason]>([])
    let displayClosed = Box<[ControlCloseReason]>([])
    let hostMsgs = Box<[ControlMessage]>([])
    let displayMsgs = Box<[ControlMessage]>([])

    var onHostSecured: (() -> Void)?
    var onDisplaySecured: (() -> Void)?
    var onHostClosed: (() -> Void)?
    var onDisplayClosed: (() -> Void)?
    var onHostMsg: (() -> Void)?
    var onDisplayMsg: (() -> Void)?

    func start() throws {
        loop = try Loopback { [weak self] conn in
            guard let self = self else { conn.cancel(); return }
            let d = ControlChannel(connection: conn, role: .display, identity: displayId,
                                   isKnownPeer: { _ in false }, queue: ctlQueue)
            d.onSecured = { [weak self] r in self?.displaySecured.mutate { $0 = r }; self?.onDisplaySecured?() }
            d.onMessage = { [weak self] m in self?.displayMsgs.mutate { $0.append(m) }; self?.onDisplayMsg?() }
            d.onClosed = { [weak self] r in self?.displayClosed.mutate { $0.append(r) }; self?.onDisplayClosed?() }
            display = d
            d.start()
        }
        let h = ControlChannel(connection: loop.connect(), role: .host, identity: hostId,
                               isKnownPeer: { _ in false }, queue: ctlQueue)
        h.onSecured = { [weak self] r in self?.hostSecured.mutate { $0 = r }; self?.onHostSecured?() }
        h.onMessage = { [weak self] m in self?.hostMsgs.mutate { $0.append(m) }; self?.onHostMsg?() }
        h.onClosed = { [weak self] r in self?.hostClosed.mutate { $0.append(r) }; self?.onHostClosed?() }
        host = h
        h.start()
    }

    func tearDown() {
        host?.close()
        display?.close()
    }
}

final class ControlChannelTests: XCTestCase {
    private func securedPair() throws -> Pair {
        let p = Pair()
        let e1 = expectation(description: "host secured")
        let e2 = expectation(description: "display secured")
        p.onHostSecured = { e1.fulfill() }
        p.onDisplaySecured = { e2.fulfill() }
        try p.start()
        wait(for: [e1, e2], timeout: 5)
        return p
    }

    func testHandshakeSecuresBothSides() throws {
        let p = try securedPair()
        defer { p.tearDown() }
        let h = try XCTUnwrap(p.hostSecured.get())
        let d = try XCTUnwrap(p.displaySecured.get())
        XCTAssertEqual(h.pairingCode, d.pairingCode)
        XCTAssertEqual(h.pairingCode.count, 6)
        XCTAssertEqual(h.peerIdentityKey, p.displayId.publicKey)
        XCTAssertEqual(d.peerIdentityKey, p.hostId.publicKey)
        XCTAssertTrue(p.host.isSecured)
        XCTAssertTrue(p.display.isSecured)
    }

    private func messages() -> [ControlMessage] {
        let fmt = WireVideoFormat(codec: 1, width: 1920, height: 1080, fps: 60, bitDepth: 8)
        var blob = Data(count: 2 << 20)
        for i in stride(from: 0, to: blob.count, by: 997) { blob[i] = UInt8(truncatingIfNeeded: i) }
        return [
            .pairConfirm(PairConfirmMessage()),
            .pairResult(PairResultMessage(accepted: true)),
            .capabilities(CapabilitiesMessage(role: "display", deviceName: "iMac", osVersion: "12.7",
                panelPixelWidth: 5120, panelPixelHeight: 2880, panelWidthMM: 596.7, panelHeightMM: 335.7,
                backingScale: 2, edrHeadroom: 1, refreshHz: 60, hwDecodeH264: true, hwDecodeHEVC: true,
                hwEncodeH264: false, hwEncodeHEVC: false, wideColor: true)),
            .probeResult(ProbeResultMessage(json: Data("{\"x\":1}".utf8))),
            .linkProbeStart(LinkProbeStartMessage(trainId: 7, rateBps: 50_000_000, durationMs: 200, packetCount: 800)),
            .linkProbeResult(LinkProbeResultMessage(trainId: 7, received: 799, firstArrivalMicros: 10,
                                                    lastArrivalMicros: 99, jitterMs: 0.25)),
            .sessionRequest(SessionRequestMessage(format: fmt, hiDPI: true, cursorMode: "overlay",
                                                  audio: false, fecRatio: 0.1)),
            .sessionAccept(SessionAcceptMessage(udpPort: 5000)),
            .reconfigure(ReconfigureMessage(format: fmt)),
            .cursorImage(CursorImageMessage(id: 9, png: Data([1, 2, 3]), hotX: 1.5, hotY: 2.5, widthPt: 16, heightPt: 24)),
            .hostState(HostStateMessage(displayAsleep: true, mirroring: false)),
            .probeBlob(blob),
            .hostState(HostStateMessage(displayAsleep: false, mirroring: true)),
        ]
    }

    func testAllMessagesBothDirections() throws {
        let p = try securedPair()
        defer { p.tearDown() }
        let msgs = messages()
        let eh = expectation(description: "host got all")
        let ed = expectation(description: "display got all")
        p.onHostMsg = { if p.hostMsgs.get().count == msgs.count { eh.fulfill() } }
        p.onDisplayMsg = { if p.displayMsgs.get().count == msgs.count { ed.fulfill() } }
        for m in msgs { p.host.send(m); p.display.send(m) }
        wait(for: [eh, ed], timeout: 10)
        XCTAssertEqual(p.hostMsgs.get(), msgs)
        XCTAssertEqual(p.displayMsgs.get(), msgs)
    }

    func testPreHandshakeSendIsDropped() throws {
        let p = Pair()
        let e1 = expectation(description: "host secured")
        let e2 = expectation(description: "display secured")
        p.onHostSecured = { e1.fulfill() }
        p.onDisplaySecured = { e2.fulfill() }
        try p.start()
        p.host.send(.hostState(HostStateMessage(displayAsleep: true, mirroring: true)))
        wait(for: [e1, e2], timeout: 5)
        defer { p.tearDown() }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(p.displayMsgs.get().isEmpty)
        XCTAssertTrue(p.displayClosed.get().isEmpty)
    }

    func testKeepalivesKeepIdleChannelOpen() throws {
        let p = try securedPair()
        defer { p.tearDown() }
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(p.hostClosed.get().isEmpty)
        XCTAssertTrue(p.displayClosed.get().isEmpty)
        XCTAssertTrue(p.hostMsgs.get().isEmpty, "keepalive must not surface as a message")
    }

    func testCloseGivesPeerClosedAndFiresOnce() throws {
        let p = try securedPair()
        let eh = expectation(description: "host closed")
        let ed = expectation(description: "display closed")
        p.onHostClosed = { eh.fulfill() }
        p.onDisplayClosed = { ed.fulfill() }
        p.host.close()
        wait(for: [eh, ed], timeout: 5)
        p.host.close()
        p.display.close()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(p.hostClosed.get(), [.localClose])
        XCTAssertEqual(p.displayClosed.get(), [.peerClosed])
        // send after close is ignored
        p.host.send(.keepalive)
    }

    func testHandshakeTimeoutAgainstSilentPeer() throws {
        let held = Box<[NWConnection]>([])
        let loop = try Loopback { conn in
            conn.start(queue: DispatchQueue(label: "silent"))
            held.mutate { $0.append(conn) }
        }
        let q = DispatchQueue(label: "ms.control.timeout")
        let ch = ControlChannel(connection: loop.connect(), role: .host, identity: makeIdentity("H"),
                                isKnownPeer: { _ in false }, queue: q)
        let e = expectation(description: "closed")
        let t0 = Date()
        let r = Box<ControlCloseReason?>(nil)
        ch.onClosed = { reason in r.mutate { $0 = reason }; e.fulfill() }
        ch.start()
        wait(for: [e], timeout: 8)
        let dt = Date().timeIntervalSince(t0)
        XCTAssertEqual(r.get(), .timeout)
        XCTAssertGreaterThan(dt, 4)
        XCTAssertLessThan(dt, 8)
        held.get().forEach { $0.cancel() }
    }

    func testGarbageInsteadOfHelloReplyCloses() throws {
        let loop = try Loopback { conn in
            conn.start(queue: DispatchQueue(label: "garbage"))
            conn.send(content: Data("this is definitely not a frame, hello!".utf8), completion: .contentProcessed { _ in })
        }
        let ch = ControlChannel(connection: loop.connect(), role: .host, identity: makeIdentity("H"),
                                isKnownPeer: { _ in false }, queue: DispatchQueue(label: "ms.control.garbage"))
        let e = expectation(description: "closed")
        let r = Box<ControlCloseReason?>(nil)
        ch.onClosed = { reason in r.mutate { $0 = reason }; e.fulfill() }
        ch.start()
        wait(for: [e], timeout: 5)
        switch r.get() {
        case .handshakeFailed?, .protocolError?: break
        default: XCTFail("unexpected reason \(String(describing: r.get()))")
        }
    }

    func testBadHandshakeContentCloses() throws {
        // Well-framed helloReply with junk keys -> handshakeFailed
        let junk = HelloReplyMessage(v: 1, deviceId: "x", deviceName: "x", identityKey: Data(count: 3),
                                     ephKey: Data(count: 3), nonce: Data(count: 3), knowsPeer: false)
        let loop = try Loopback { conn in
            conn.start(queue: DispatchQueue(label: "junk"))
            let m = ControlMessage.helloReply(junk)
            let f = ControlFramer.frame(typeCode: m.typeCode, body: (try? m.encodeBody()) ?? Data())
            conn.send(content: f, completion: .contentProcessed { _ in })
        }
        let ch = ControlChannel(connection: loop.connect(), role: .host, identity: makeIdentity("H"),
                                isKnownPeer: { _ in false }, queue: DispatchQueue(label: "ms.control.junk"))
        let e = expectation(description: "closed")
        let r = Box<ControlCloseReason?>(nil)
        ch.onClosed = { reason in r.mutate { $0 = reason }; e.fulfill() }
        ch.start()
        wait(for: [e], timeout: 5)
        guard case .handshakeFailed? = r.get() else { return XCTFail("got \(String(describing: r.get()))") }
    }

    func testTamperedCiphertextClosesWithProtocolError() throws {
        let display = makeIdentity("RawDisplay")
        let rawQueue = DispatchQueue(label: "raw.display")
        let state = Box<(ControlFramer, DisplayHandshake)>((ControlFramer(),
                      DisplayHandshake(identity: display, isKnownPeer: { _ in false })))
        let loop = try Loopback { conn in
            conn.start(queue: rawQueue)
            func send(_ m: ControlMessage) {
                let f = ControlFramer.frame(typeCode: m.typeCode, body: (try? m.encodeBody()) ?? Data())
                conn.send(content: f, completion: .contentProcessed { _ in })
            }
            func loop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                    guard let data = data else { return }
                    state.mutate { s in
                        s.0.append(data)
                        while let fr = try? s.0.next() {
                            guard let m = try? ControlMessage.decode(typeCode: fr.typeCode, body: fr.body) else { continue }
                            switch m {
                            case .hello(let h):
                                if let r = try? s.1.handleHello(h) { send(.helloReply(r)) }
                            case .reveal(let r):
                                if let (reply, _) = try? s.1.handleReveal(r) {
                                    send(.revealReply(reply))
                                    // forged "sealed" hostState body
                                    let bad = ControlFramer.frame(typeCode: 20, body: Data(repeating: 0x42, count: 40))
                                    conn.send(content: bad, completion: .contentProcessed { _ in })
                                }
                            default: break
                            }
                        }
                    }
                    if err == nil && !done { loop() }
                }
            }
            loop()
        }
        let ch = ControlChannel(connection: loop.connect(), role: .host, identity: makeIdentity("H"),
                                isKnownPeer: { _ in false }, queue: DispatchQueue(label: "ms.control.tamper"))
        let e = expectation(description: "closed")
        let r = Box<ControlCloseReason?>(nil)
        let msgs = Box<Int>(0)
        ch.onMessage = { _ in msgs.mutate { $0 += 1 } }
        ch.onClosed = { reason in r.mutate { $0 = reason }; e.fulfill() }
        ch.start()
        wait(for: [e], timeout: 5)
        guard case .protocolError? = r.get() else { return XCTFail("got \(String(describing: r.get()))") }
        XCTAssertEqual(msgs.get(), 0)
    }
}
