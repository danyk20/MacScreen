import XCTest
import Network
import CryptoKit
import MSCore
import MSProtocol
@testable import MSTransport

private final class Locked<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
}

/// Display-role ControlChannel on a loopback listener, driven by a raw TCP client that speaks (or abuses) the protocol.
private final class Rig {
    let queue = DispatchQueue(label: "test.ctl.sec")
    let displayId = Identity(deviceId: UUID().uuidString, deviceName: "D", signingKey: Curve25519.Signing.PrivateKey())
    let hostId = Identity(deviceId: UUID().uuidString, deviceName: "H", signingKey: Curve25519.Signing.PrivateKey())
    let listener: NWListener
    var channel: ControlChannel?
    let closed = Locked<[ControlCloseReason]>([])
    let messages = Locked<[ControlMessage]>([])
    let secured = Locked(false)
    var client: NWConnection!
    private let rx = Locked(Data())
    private var framer = ControlFramer()
    // Host side of the handshake and ciphers, for tests that authenticate.
    private var hostHS: HostHandshake?
    var sealer: ControlSealer?
    var opener: ControlOpener?

    init() throws {
        listener = try NWListener(using: ControlChannel.tcpParameters(), on: .any)
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { sem.signal() } }
        let did = displayId
        let q = queue
        let closed = self.closed, messages = self.messages, secured = self.secured
        listener.newConnectionHandler = { [unowned self] conn in
            let ch = ControlChannel(connection: conn, role: .display, identity: did, isKnownPeer: { _ in false }, queue: q)
            ch.onClosed = { r in closed.mutate { $0.append(r) } }
            ch.onMessage = { m in messages.mutate { $0.append(m) } }
            ch.onSecured = { _ in secured.mutate { $0 = true } }
            self.channel = ch
            ch.start()
        }
        listener.start(queue: queue)
        guard sem.wait(timeout: .now() + 5) == .success, let p = listener.port else { throw XCTSkip("listener not ready") }
        client = NWConnection(to: .hostPort(host: "127.0.0.1", port: p), using: ControlChannel.tcpParameters())
        let ready = DispatchSemaphore(value: 0)
        client.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        client.start(queue: DispatchQueue(label: "test.ctl.client"))
        guard ready.wait(timeout: .now() + 5) == .success else { throw XCTSkip("client not ready") }
        pump()
    }

    deinit { client.cancel(); listener.cancel() }

    private func pump() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
            guard let self = self else { return }
            if let d = d { self.rx.mutate { $0.append(d) } }
            if err == nil && !done { self.pump() }
        }
    }

    func send(_ d: Data) { client.send(content: d, completion: .contentProcessed { _ in }) }

    func sendFrame(_ type: UInt8, _ body: Data) { send(ControlFramer.frame(typeCode: type, body: body)) }

    func readFrame(timeout: TimeInterval = 5) -> (typeCode: UInt8, body: Data)? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let chunk = rx.get()
            if !chunk.isEmpty { rx.mutate { $0.removeAll() }; framer.append(chunk) }
            if let f = try? framer.next() { return f }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    func waitClosed(timeout: TimeInterval = 5) -> ControlCloseReason? {
        let end = Date().addingTimeInterval(timeout)
        while closed.get().isEmpty && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        return closed.get().first
    }

    /// Completes the host side of the handshake against the Display channel (frames sent byte by byte
    /// when `dribble` is set, to exercise partial-frame reassembly).
    func handshake(dribble: Bool = false) throws {
        let hh = HostHandshake(identity: hostId, isKnownPeer: { _ in false })
        hostHS = hh
        func put(_ m: ControlMessage) throws {
            let f = ControlFramer.frame(typeCode: m.typeCode, body: try m.encodeBody())
            if dribble { for b in f { send(Data([b])); Thread.sleep(forTimeInterval: 0.001) } } else { send(f) }
        }
        try put(.hello(hh.makeHello()))
        let rf = try XCTUnwrap(readFrame())
        guard case .helloReply(let reply) = try ControlMessage.decode(typeCode: rf.typeCode, body: rf.body) else {
            return XCTFail("expected helloReply")
        }
        try put(.reveal(try hh.handleHelloReply(reply)))
        let rr = try XCTUnwrap(readFrame())
        guard case .revealReply(let rep) = try ControlMessage.decode(typeCode: rr.typeCode, body: rr.body) else {
            return XCTFail("expected revealReply")
        }
        let res = try hh.handleRevealReply(rep)
        sealer = ControlSealer(key: res.keys.ctlH2D)
        opener = ControlOpener(key: res.keys.ctlD2H)
        let end = Date().addingTimeInterval(3)
        while !secured.get() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(secured.get())
    }

    func sendSealed(_ m: ControlMessage) throws {
        sendFrame(m.typeCode, try XCTUnwrap(sealer).seal(try m.encodeBody()))
    }
}

final class ControlChannelSecurityTests: XCTestCase {
    private func assertProtocolClose(_ r: ControlCloseReason?, file: StaticString = #filePath, line: UInt = #line) {
        switch r {
        case .protocolError?, .handshakeFailed?: break
        default: XCTFail("expected protocol/handshake failure, got \(String(describing: r))", file: file, line: line)
        }
    }

    func testOversizeAndZeroLengthHeadersCloseTheChannel() throws {
        for len in [UInt32.max, 0x7FFF_FFFF, UInt32(ControlFramer.maxHandshakeFrameLength + 1), 0] {
            let rig = try Rig()
            var w = ByteWriter(capacity: 5)
            w.u32(len); w.u8(1)
            rig.send(w.data)
            assertProtocolClose(rig.waitClosed())
        }
    }

    func testNonHandshakeAndUnknownFramesBeforeHandshakeClose() throws {
        for type in [UInt8(21), 22, 19, 0x80, 200, 0, 9] {
            let rig = try Rig()
            rig.sendFrame(type, Data("{}".utf8))
            assertProtocolClose(rig.waitClosed())
        }
    }

    func testGarbageBeforeHandshakeNeverCrashes() throws {
        var rng = SeededRNG(31)
        for _ in 0..<15 {
            let rig = try Rig()
            rig.send(rng.bytes(Int.random(in: 1...3000, using: &rng)))
            _ = rig.waitClosed(timeout: 1)  // either closed on framing or still waiting; both fine
        }
    }

    func testHandshakeMessageOfWrongRoleOrOrderCloses() throws {
        // A Display only accepts hello then reveal. A helloReply or a reveal first is a protocol error.
        let rig = try Rig()
        rig.sendFrame(2, Data("{}".utf8))
        assertProtocolClose(rig.waitClosed())
        let rig2 = try Rig()
        let hh = HostHandshake(identity: rig2.hostId, isKnownPeer: { _ in false })
        let hello = hh.makeHello()
        rig2.sendFrame(3, try JSONEncoder().encode(RevealMessage(ephKey: Data(count: 32), nonce: Data(count: 32), signature: Data(count: 64))))
        assertProtocolClose(rig2.waitClosed())
        _ = hello
    }

    func testPartialFramesStillHandshake() throws {
        let rig = try Rig()
        try rig.handshake(dribble: true)
        XCTAssertTrue(rig.closed.get().isEmpty)
    }

    func testAuthenticatedFramesAreDeliveredAndLimitRaisedAfterHandshake() throws {
        let rig = try Rig()
        try rig.handshake()
        // 200 KB sealed probeBlob: far above the 64 KB pre-handshake limit, accepted once authenticated.
        try rig.sendSealed(.probeBlob(Data(repeating: 7, count: 200_000)))
        let end = Date().addingTimeInterval(5)
        while rig.messages.get().isEmpty && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(rig.messages.get(), [.probeBlob(Data(repeating: 7, count: 200_000))])
        XCTAssertTrue(rig.closed.get().isEmpty)
    }

    func testTamperedReplayedAndHandshakeFramesAfterSecureClose() throws {
        // Flipped ciphertext bit.
        let a = try Rig(); try a.handshake()
        var sealed = try XCTUnwrap(a.sealer).seal(try ControlMessage.hostState(HostStateMessage(displayAsleep: false, mirroring: false)).encodeBody())
        sealed[0] ^= 1
        a.sendFrame(20, sealed)
        assertProtocolClose(a.waitClosed())
        XCTAssertTrue(a.messages.get().isEmpty)

        // Replay of a sealed frame (counter is implicit, so the second copy no longer authenticates).
        let b = try Rig(); try b.handshake()
        let s = try XCTUnwrap(b.sealer).seal(try ControlMessage.hostState(HostStateMessage(displayAsleep: false, mirroring: true)).encodeBody())
        b.sendFrame(20, s); b.sendFrame(20, s)
        assertProtocolClose(b.waitClosed())
        XCTAssertEqual(b.messages.get().count, 1)

        // Plaintext (unsealed) application frame after the handshake.
        let c = try Rig(); try c.handshake()
        c.sendFrame(20, try ControlMessage.hostState(HostStateMessage(displayAsleep: false, mirroring: true)).encodeBody())
        assertProtocolClose(c.waitClosed())
        XCTAssertTrue(c.messages.get().isEmpty)

        // Handshake frame after the handshake.
        let d = try Rig(); try d.handshake()
        d.sendFrame(1, Data("{}".utf8))
        assertProtocolClose(d.waitClosed())

        // Authenticated frame whose plaintext is not valid for its type.
        let e = try Rig(); try e.handshake()
        e.sendFrame(16, try XCTUnwrap(e.sealer).seal(Data("not json".utf8)))
        assertProtocolClose(e.waitClosed())
        XCTAssertTrue(e.messages.get().isEmpty)
    }

    func testPeerByeIsNotForwardedAsMessage() throws {
        let rig = try Rig(); try rig.handshake()
        try rig.sendSealed(.bye(ByeMessage(reason: "x")))
        XCTAssertEqual(rig.waitClosed(), .peerClosed)
        XCTAssertTrue(rig.messages.get().isEmpty)
    }
}

/// Local copy of the deterministic generator used by the protocol fuzz tests.
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &self) }) }
}
