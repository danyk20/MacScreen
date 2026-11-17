import XCTest
import CryptoKit
import MSCore
@testable import MSProtocol

/// Deterministic SplitMix64 so every failure reproduces.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SeededRNG {
    mutating func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &self) }) }

    /// Flips 1...4 random bits, optionally truncates or extends.
    mutating func mutate(_ d: Data) -> Data {
        var out = d
        if !out.isEmpty {
            for _ in 0..<Int.random(in: 1...4, using: &self) {
                let i = Int.random(in: 0..<out.count, using: &self)
                out[out.startIndex + i] ^= UInt8(1 << Int.random(in: 0...7, using: &self))
            }
        }
        switch Int.random(in: 0..<6, using: &self) {
        case 0: out = out.prefix(Int.random(in: 0...out.count, using: &self))
        case 1: out.append(bytes(Int.random(in: 1...40, using: &self)))
        default: break
        }
        return out
    }
}

final class FuzzTests: XCTestCase {
    private let iterations = 20_000

    // MARK: Control messages and framing

    private func sampleMessages() -> [ControlMessage] {
        let fmt = WireVideoFormat(codec: 2, width: 3840, height: 2160, fps: 60, bitDepth: 10)
        return [
            .hello(HelloMessage(v: 1, deviceId: "id", deviceName: "n", identityKey: Data(repeating: 1, count: 32),
                                commit: Data(repeating: 2, count: 32))),
            .reveal(RevealMessage(ephKey: Data(repeating: 3, count: 32), nonce: Data(repeating: 4, count: 32),
                                  signature: Data(repeating: 5, count: 64))),
            .pairResult(PairResultMessage(accepted: true)),
            .linkProbeStart(LinkProbeStartMessage(trainId: 1, rateBps: 10_000_000, durationMs: 500, packetCount: 400)),
            .linkProbeResult(LinkProbeResultMessage(trainId: 1, received: 3, firstArrivalMicros: 1,
                                                    lastArrivalMicros: 2, jitterMs: 0.5)),
            .sessionRequest(SessionRequestMessage(format: fmt, hiDPI: true, cursorMode: "overlay", audio: true,
                                                  fecRatio: 0.1)),
            .sessionAccept(SessionAcceptMessage(udpPort: 5000)),
            .reconfigure(ReconfigureMessage(format: fmt)),
            .cursorImage(CursorImageMessage(id: 3, png: Data([1, 2, 3]), hotX: 1, hotY: 2, widthPt: 8, heightPt: 8)),
            .hostState(HostStateMessage(displayAsleep: false, mirroring: true)),
            .bye(ByeMessage(reason: "x")),
        ]
    }

    func testControlMessageDecodeRandomBodies() {
        var rng = SeededRNG(1)
        for _ in 0..<iterations {
            let type = UInt8.random(in: 0...255, using: &rng)
            let body = rng.bytes(Int.random(in: 0...200, using: &rng))
            _ = try? ControlMessage.decode(typeCode: type, body: body)
        }
    }

    func testControlMessageDecodeMutatedValidBodies() throws {
        var rng = SeededRNG(2)
        let samples = try sampleMessages().map { ($0.typeCode, try $0.encodeBody()) }
        var decoded = 0
        for i in 0..<iterations {
            let (t, b) = samples[i % samples.count]
            if (try? ControlMessage.decode(typeCode: t, body: rng.mutate(b))) != nil { decoded += 1 }
        }
        XCTAssertLessThan(decoded, iterations)  // mutation must break at least some
    }

    func testControlMessageHostileJSON() {
        let bodies = [
            #"{"udpPort":99999999999999999999}"#,
            #"{"udpPort":-1}"#,
            #"{"trainId":4294967296,"rateBps":1e999,"durationMs":0,"packetCount":0}"#,
            #"{"format":{"codec":2,"width":9223372036854775807,"height":-9223372036854775808,"fps":1,"bitDepth":8},"hiDPI":true,"cursorMode":"x","audio":false,"fecRatio":1e999}"#,
            String(repeating: "[", count: 5000),
            #"{"png":"!!!notbase64","id":1}"#,
            "null", "", "{}", "[]",
        ]
        for t in UInt8(0)...UInt8(255) {
            for b in bodies { _ = try? ControlMessage.decode(typeCode: t, body: Data(b.utf8)) }
        }
    }

    func testFramerLengthAttacks() throws {
        // 0xFFFFFFFF, just above the limit, and zero: rejected from the 4-byte header alone, nothing buffered.
        for len in [UInt32.max, UInt32(ControlFramer.maxFrameLength + 1), 0x8000_0000] {
            var f = ControlFramer()
            var w = ByteWriter(capacity: 4)
            w.u32(len)
            f.append(w.data)
            XCTAssertThrowsError(try f.next()) {
                XCTAssertEqual($0 as? ControlMessageError, .frameTooLarge(Int(len)))
            }
        }
        var f = ControlFramer()
        f.append(Data([0, 0, 0, 0]))
        XCTAssertThrowsError(try f.next())

        // The pre-handshake limit is far smaller.
        var pre = ControlFramer()
        pre.limit = ControlFramer.maxHandshakeFrameLength
        var w = ByteWriter(capacity: 4)
        w.u32(UInt32(ControlFramer.maxHandshakeFrameLength + 1))
        pre.append(w.data)
        XCTAssertThrowsError(try pre.next())
        XCTAssertLessThan(ControlFramer.maxHandshakeFrameLength, ControlFramer.maxFrameLength)
    }

    func testFramerPartialFramesAndByteAtATime() throws {
        var stream = Data()
        let msgs = sampleMessages()
        for m in msgs { stream.append(ControlFramer.frame(typeCode: m.typeCode, body: try m.encodeBody())) }
        var f = ControlFramer()
        var got: [UInt8] = []
        for byte in stream {
            f.append(Data([byte]))
            while let fr = try f.next() { got.append(fr.typeCode) }
        }
        XCTAssertEqual(got, msgs.map { $0.typeCode })
        // Incomplete header and incomplete body both wait.
        var g = ControlFramer()
        g.append(Data([0, 0, 1]))
        XCTAssertNil(try g.next())
        g.append(Data([0, 21]))  // length 256, one body byte so far
        XCTAssertNil(try g.next())
    }

    func testFramerRandomStreamNeverTraps() {
        var rng = SeededRNG(3)
        for _ in 0..<2000 {
            var f = ControlFramer()
            f.limit = 4096
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                f.append(rng.bytes(Int.random(in: 0...64, using: &rng)))
                do { while try f.next() != nil {} } catch { break }
            }
        }
    }

    // MARK: Packet codecs

    private func validPackets() -> [(String, Data)] {
        [
            ("video", VideoFragment(frameId: 7, isKeyframe: true, blockIndex: 0, blockCount: 1, fragIndex: 0, k: 2,
                                    m: 1, frameLength: 2000, captureTimeMicros: 9,
                                    payload: Data(repeating: 1, count: 1200)).encode()),
            ("audio", AudioPacket(seq: 1, hostTimeMicros: 2, pcm: Data(count: AudioPacket.pcmSize)).encode()),
            ("cursor", CursorPacket(seq: 1, x: 0.5, y: 0.5, visible: true, imageId: 2).encode()),
            ("ping", PingPacket(id: 1, t0: 2).encode()),
            ("pong", PongPacket(id: 1, t0: 2, t1: 3, t2: 4).encode()),
            ("feedback", FeedbackPacket(highestDecodedFrame: 1, framesDecoded: 2, framesDropped: 3, fragsReceived: 4,
                                        fragsLost: 5, fragsRecovered: 6, avgDecodeMsX10: 7, jitterMsX10: 8,
                                        requestKeyframe: true).encode()),
            ("nack", NackPacket(frameId: 1, blockIndex: 0, fragIndices: [1, 2, 3]).encode()),
            ("probe", LinkProbePacket(trainId: 1, seq: 2).encode()),
            ("header", PacketHeader(type: .videoData, counter: 5).encode()),
        ]
    }

    private func decodeAll(_ d: Data) {
        _ = try? PacketHeader.decode(d)
        _ = try? VideoFragment.decode(d)
        _ = try? AudioPacket.decode(d)
        _ = try? CursorPacket.decode(d)
        _ = try? PingPacket.decode(d)
        _ = try? PongPacket.decode(d)
        _ = try? FeedbackPacket.decode(d)
        _ = try? NackPacket.decode(d)
        _ = try? LinkProbePacket.decode(d)
    }

    func testPacketCodecsRandomAndMutated() {
        var rng = SeededRNG(4)
        let valid = validPackets()
        for i in 0..<iterations {
            decodeAll(rng.bytes(Int.random(in: 0...1300, using: &rng)))
            decodeAll(rng.mutate(valid[i % valid.count].1))
            // Slice with a non-zero startIndex must not index out of range.
            let padded = rng.bytes(5) + valid[i % valid.count].1
            decodeAll(padded.dropFirst(5))
            decodeAll(padded.dropFirst(Int.random(in: 0...padded.count, using: &rng)))
        }
    }

    func testPacketCodecsTruncationEveryLength() {
        for (_, d) in validPackets() {
            for n in 0..<d.count {
                decodeAll(d.prefix(n))
            }
        }
        for n in 0..<28 { XCTAssertThrowsError(try FeedbackPacket.decode(Data(count: n))) }
        for n in 0..<28 { XCTAssertThrowsError(try PongPacket.decode(Data(count: n))) }
        for n in 0..<12 { XCTAssertThrowsError(try PacketHeader.decode(Data(count: n))) }
    }

    func testNackCountLargerThanPayload() {
        // count byte 255 but only two indices present: must throw, not read past the end or allocate blindly.
        var w = ByteWriter(capacity: 10)
        w.u32(1); w.u8(0); w.u8(255); w.u16(1); w.u16(2)
        XCTAssertThrowsError(try NackPacket.decode(w.data))
        XCTAssertThrowsError(try NackPacket.decode(Data([0, 0, 0, 1, 0, 255])))
    }

    func testVideoFragmentFieldAttacks() {
        func make(k: UInt16, m: UInt16, blockCount: UInt8, blockIndex: UInt8, payload: Int, frameLength: UInt32) -> Data {
            var w = ByteWriter(capacity: 28 + payload)
            w.u32(1); w.u8(0); w.u8(blockIndex); w.u8(blockCount); w.u8(0)
            w.u16(0); w.u16(k); w.u16(m); w.u16(0); w.u32(frameLength); w.u64(0)
            w.zeros(payload)
            return w.data
        }
        XCTAssertThrowsError(try VideoFragment.decode(make(k: 0, m: 0, blockCount: 1, blockIndex: 0, payload: 10, frameLength: 10)))
        XCTAssertThrowsError(try VideoFragment.decode(make(k: 65, m: 0, blockCount: 1, blockIndex: 0, payload: 10, frameLength: 10)))
        XCTAssertThrowsError(try VideoFragment.decode(make(k: 1, m: 33, blockCount: 1, blockIndex: 0, payload: 10, frameLength: 10)))
        XCTAssertThrowsError(try VideoFragment.decode(make(k: 1, m: 0, blockCount: 0, blockIndex: 0, payload: 10, frameLength: 10)))
        XCTAssertThrowsError(try VideoFragment.decode(make(k: 1, m: 0, blockCount: 1, blockIndex: 1, payload: 10, frameLength: 10)))
        XCTAssertThrowsError(try VideoFragment.decode(make(k: 1, m: 0, blockCount: 1, blockIndex: 0, payload: 0, frameLength: 10)))
        XCTAssertThrowsError(try VideoFragment.decode(make(k: 1, m: 0, blockCount: 1, blockIndex: 0, payload: 1201, frameLength: 10)))
        XCTAssertNoThrow(try VideoFragment.decode(make(k: 1, m: 0, blockCount: 1, blockIndex: 0, payload: 10, frameLength: UInt32.max)))
    }

    // MARK: Reassembler

    func testReassemblerRandomFragmentsBounded() {
        var rng = SeededRNG(5)
        let r = Reassembler()
        var now: UInt64 = 1_000_000
        for i in 0..<iterations {
            now += UInt64.random(in: 0...20_000, using: &rng)
            let frameLength = [0, 1, 1200, 1201, 76_800, 76_801, 19_584_000, 19_584_001, UInt32.max]
                .randomElement(using: &rng)!
            let f = VideoFragment(
                frameId: UInt32.random(in: 0...40, using: &rng) &+ UInt32(i / 500),
                isKeyframe: Bool.random(using: &rng),
                blockIndex: UInt8.random(in: 0...255, using: &rng) % 4,
                blockCount: UInt8.random(in: 0...255, using: &rng) % 5,
                fragIndex: UInt16.random(in: 0...80, using: &rng),
                k: UInt16.random(in: 0...70, using: &rng),
                m: UInt16.random(in: 0...34, using: &rng),
                frameLength: frameLength,
                captureTimeMicros: UInt64.random(in: 0...UInt64.max, using: &rng),
                payload: rng.bytes([0, 1, 10, 1199, 1200, 1201].randomElement(using: &rng)!))
            let type: PacketType = Bool.random(using: &rng) ? .videoData : .videoParity
            let rtt: Double? = [nil, 0, 5, 99.9, 100, -1, .nan, .infinity].randomElement(using: &rng)!
            _ = r.ingest(type: type, fragment: f, nowMicros: now, rttMs: rtt)
            if i % 7 == 0 { _ = r.tick(nowMicros: now, rttMs: rtt) }
            XCTAssertLessThanOrEqual(r.framesInAssembly, MSConstants.reassemblyMaxFrames)
        }
    }

    /// Geometrically valid fragments only (so frames really assemble), random order, duplicates, random loss.
    func testReassemblerValidTrafficWithLossAndDuplicates() throws {
        var rng = SeededRNG(6)
        let r = Reassembler()
        var now: UInt64 = 1_000_000
        var delivered = 0
        for frameId in 0..<300 {
            let length = Int.random(in: 1...(64 * 1200 * 2 + 17), using: &rng)
            let totalFrags = (length + 1199) / 1200
            let blockCount = (totalFrags + 63) / 64
            var frags: [(PacketType, VideoFragment)] = []
            var offset = 0
            for b in 0..<blockCount {
                let k = b == blockCount - 1 ? totalFrags - 64 * (blockCount - 1) : 64
                var shards: [Data] = []
                for _ in 0..<k {
                    let n = min(1200, length - offset)
                    shards.append(rng.bytes(n)); offset += n
                }
                let m = 4
                let parity = try ReedSolomon.encode(data: shards, parityCount: m, shardSize: 1200)
                for (i, s) in shards.enumerated() {
                    frags.append((.videoData, VideoFragment(frameId: UInt32(frameId), isKeyframe: frameId % 30 == 0,
                        blockIndex: UInt8(b), blockCount: UInt8(blockCount), fragIndex: UInt16(i), k: UInt16(k),
                        m: UInt16(m), frameLength: UInt32(length), captureTimeMicros: 1, payload: s)))
                }
                for (i, s) in parity.enumerated() {
                    frags.append((.videoParity, VideoFragment(frameId: UInt32(frameId), isKeyframe: frameId % 30 == 0,
                        blockIndex: UInt8(b), blockCount: UInt8(blockCount), fragIndex: UInt16(i), k: UInt16(k),
                        m: UInt16(m), frameLength: UInt32(length), captureTimeMicros: 1, payload: s)))
                }
            }
            frags.shuffle(using: &rng)
            for (t, f) in frags where Int.random(in: 0..<100, using: &rng) >= 3 {
                now += 100
                for e in r.ingest(type: t, fragment: f, nowMicros: now, rttMs: 5) {
                    if case .frame(_, let p, _, _) = e { delivered += 1; XCTAssertGreaterThan(p.count, 0) }
                }
                if Int.random(in: 0..<10, using: &rng) == 0 {  // duplicate
                    _ = r.ingest(type: t, fragment: f, nowMicros: now, rttMs: 5)
                }
                XCTAssertLessThanOrEqual(r.framesInAssembly, MSConstants.reassemblyMaxFrames)
            }
            now += 20_000
            _ = r.tick(nowMicros: now, rttMs: 5)
        }
        XCTAssertGreaterThan(delivered, 100)
    }

    // MARK: ReedSolomon

    func testReedSolomonRandomParametersNeverTrap() {
        var rng = SeededRNG(7)
        for _ in 0..<3000 {
            let k = Int.random(in: -1...70, using: &rng)
            let m = Int.random(in: -1...40, using: &rng)
            let size = Int.random(in: 0...64, using: &rng)
            let total = max(0, min(k + m, 300))
            let shards: [Data?] = (0..<total).map { _ in Int.random(in: 0..<3, using: &rng) == 0 ? nil : rng.bytes(Int.random(in: 0...70, using: &rng)) }
            _ = try? ReedSolomon.reconstruct(shards: shards, dataCount: k, parityCount: m, shardSize: size)
            let data = (0..<max(0, min(k, 70))).map { _ in rng.bytes(Int.random(in: 0...70, using: &rng)) }
            _ = try? ReedSolomon.encode(data: data, parityCount: m, shardSize: size)
        }
    }

    func testReedSolomonRoundTripRandomErasures() throws {
        var rng = SeededRNG(8)
        for _ in 0..<300 {
            let k = Int.random(in: 1...64, using: &rng)
            let m = Int.random(in: 0...32, using: &rng)
            let size = Int.random(in: 1...48, using: &rng)
            let data = (0..<k).map { _ in rng.bytes(size) }
            let parity = try ReedSolomon.encode(data: data, parityCount: m, shardSize: size)
            var shards: [Data?] = data + parity
            var idx = Array(0..<(k + m)); idx.shuffle(using: &rng)
            for i in idx.prefix(m) { shards[i] = nil }
            let out = try ReedSolomon.reconstruct(shards: shards, dataCount: k, parityCount: m, shardSize: size)
            XCTAssertEqual(out, data)
        }
    }

    // MARK: ReplayWindow

    /// Reference model: accepted iff never accepted and within `size` of the highest.
    func testReplayWindowMatchesModelIncludingExtremes() {
        var rng = SeededRNG(9)
        for round in 0..<40 {
            var w = ReplayWindow()
            var seen = Set<UInt64>()
            var highest: UInt64 = 0
            let base: UInt64 = [0, 1, 1 << 32, UInt64.max - 3000, UInt64.max - 50, UInt64.max - 1500][round % 6]
            for _ in 0..<1500 {
                let c: UInt64
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: c = UInt64.max &- UInt64.random(in: 0...20, using: &rng)
                case 1: c = base &+ UInt64.random(in: 0...3000, using: &rng)
                case 2: c = highest &- UInt64.random(in: 0...1100, using: &rng)
                default: c = highest &+ UInt64.random(in: 0...5, using: &rng)
                }
                let expected: Bool
                if c == 0 { expected = false }
                else if seen.contains(c) { expected = false }
                else if c <= highest && highest - c >= ReplayWindow.size { expected = false }
                else { expected = true }
                XCTAssertEqual(w.accept(c), expected, "round \(round) counter \(c) highest \(highest)")
                if expected { seen.insert(c); highest = max(highest, c) }
            }
        }
    }

    func testReplayWindowCounterMaxDoesNotTrap() {
        var w = ReplayWindow()
        XCTAssertTrue(w.accept(UInt64.max - 5))
        XCTAssertTrue(w.accept(UInt64.max))          // used to overflow `c += 1` in the clearing loop
        XCTAssertFalse(w.accept(UInt64.max))
        XCTAssertTrue(w.accept(UInt64.max - 1))
        XCTAssertFalse(w.accept(UInt64.max - 1))
        XCTAssertFalse(w.accept(UInt64.max - ReplayWindow.size))  // outside the window
        XCTAssertFalse(w.accept(0))
        var v = ReplayWindow()
        XCTAssertTrue(v.accept(UInt64.max))
        XCTAssertTrue(v.accept(UInt64.max - ReplayWindow.size + 1))
    }

    func testReplayWindowRingWraparound() {
        var w = ReplayWindow()
        for c in 1...5000 as ClosedRange<UInt64> { XCTAssertTrue(w.accept(c)) }
        for c in 1...5000 as ClosedRange<UInt64> { XCTAssertFalse(w.accept(c)) }
        XCTAssertTrue(w.accept(10_000))
        XCTAssertFalse(w.accept(5000))  // 5000 is 5000 behind: out of window
        XCTAssertTrue(w.accept(9_999))
        XCTAssertFalse(w.accept(9_999))
    }

    // MARK: Ciphers

    private func key(_ b: UInt8) -> SymmetricKey { SymmetricKey(data: Data(repeating: b, count: 32)) }

    func testPacketOpenerRandomAndTamperedDatagrams() throws {
        var rng = SeededRNG(10)
        let sealer = PacketSealer(key: key(1))
        let opener = PacketOpener(key: key(1))
        let valid = try sealer.seal(type: 1, payload: Data(repeating: 9, count: 100))
        for _ in 0..<iterations {
            XCTAssertThrowsError(try opener.open(rng.bytes(Int.random(in: 0...1400, using: &rng))))
        }
        for _ in 0..<iterations {
            var m = rng.mutate(valid)
            if m == valid { m.append(0) }
            XCTAssertThrowsError(try opener.open(m))
        }
        for n in 0..<valid.count { XCTAssertThrowsError(try opener.open(valid.prefix(n))) }
        // The untouched datagram still opens exactly once: failures did not poison the replay window.
        XCTAssertEqual(try opener.open(valid).payload.count, 100)
        XCTAssertThrowsError(try opener.open(valid)) { XCTAssertEqual($0 as? CipherError, .replayed) }
        // Sliced input with non-zero startIndex.
        let s = PacketSealer(key: key(1))
        let d2 = try s.seal(type: 2, payload: Data([1, 2, 3]))
        let o2 = PacketOpener(key: key(1))
        XCTAssertEqual(try o2.open((Data([0xFF, 0xEE]) + d2).dropFirst(2)).payload, Data([1, 2, 3]))
    }

    func testPacketOpenerRejectsWrongKeyAndReplayedCounterZero() throws {
        let sealer = PacketSealer(key: key(1))
        let d = try sealer.seal(type: 1, payload: Data([1]))
        XCTAssertThrowsError(try PacketOpener(key: key(2)).open(d))
        // Header type byte and reserved bytes are authenticated.
        for i in 0..<12 {
            var m = d; m[i] ^= 1
            XCTAssertThrowsError(try PacketOpener(key: key(1)).open(m), "header byte \(i)")
        }
    }

    func testControlOpenerRandomAndCounterSemantics() throws {
        var rng = SeededRNG(11)
        let sealer = ControlSealer(key: key(3))
        let opener = ControlOpener(key: key(3))
        let a = try sealer.seal(Data("one".utf8))
        let b = try sealer.seal(Data("two".utf8))
        for _ in 0..<iterations { XCTAssertThrowsError(try opener.open(rng.bytes(Int.random(in: 0...64, using: &rng)))) }
        for _ in 0..<2000 {
            var m = rng.mutate(a); if m == a { m.append(1) }
            XCTAssertThrowsError(try opener.open(m))
        }
        // Out of order (b before a) and replay both fail; failures never advance the counter.
        XCTAssertThrowsError(try opener.open(b))
        XCTAssertEqual(try opener.open(a), Data("one".utf8))
        XCTAssertThrowsError(try opener.open(a))
        XCTAssertEqual(try opener.open(b), Data("two".utf8))
        XCTAssertThrowsError(try opener.open(Data()))
    }

    func testDirectionsUseDistinctKeysAndNonces() throws {
        // A frame sealed for one direction never opens in the other, even with the same counter.
        let r = try handshakeKeys()
        let h2d = try ControlSealer(key: r.ctlH2D).seal(Data("x".utf8))
        XCTAssertThrowsError(try ControlOpener(key: r.ctlD2H).open(h2d))
        let m = try PacketSealer(key: r.medH2D).seal(type: 1, payload: Data([1]))
        XCTAssertThrowsError(try PacketOpener(key: r.medD2H).open(m))
        XCTAssertThrowsError(try PacketOpener(key: r.ctlH2D).open(m))
        // Same plaintext, same counter, different keys: distinct ciphertext.
        let a = try PacketSealer(key: r.medH2D).seal(type: 1, payload: Data(count: 32))
        let b = try PacketSealer(key: r.medD2H).seal(type: 1, payload: Data(count: 32))
        XCTAssertNotEqual(a.dropFirst(12), b.dropFirst(12))
    }

    func testSealerNeverRepeatsCounter() throws {
        let s = PacketSealer(key: key(5))
        var seen = Set<UInt64>()
        for _ in 0..<5000 {
            let d = try s.seal(type: 1, payload: Data([1]))
            let h = try PacketHeader.decode(d)
            XCTAssertTrue(seen.insert(h.counter).inserted)
            XCTAssertGreaterThan(h.counter, 0)
        }
    }

    private func handshakeKeys() throws -> SessionKeys {
        let (_, _, h, _) = try runHandshake()
        return h.keys
    }

    // MARK: Handshake

    private func ident(_ n: String) -> Identity {
        Identity(deviceId: UUID().uuidString, deviceName: n, signingKey: Curve25519.Signing.PrivateKey())
    }

    private func runHandshake(host: Identity? = nil, disp: Identity? = nil)
        throws -> (HelloMessage, RevealMessage, HandshakeResult, HandshakeResult) {
        let h = HostHandshake(identity: host ?? ident("H"), isKnownPeer: { _ in false })
        let d = DisplayHandshake(identity: disp ?? ident("D"), isKnownPeer: { _ in false })
        let hello = h.makeHello()
        let reply = try d.handleHello(hello)
        let reveal = try h.handleHelloReply(reply)
        let (rr, dres) = try d.handleReveal(reveal)
        let hres = try h.handleRevealReply(rr)
        return (hello, reveal, hres, dres)
    }

    private func flip(_ d: Data, _ byte: Int, _ bit: Int) -> Data {
        var x = d; x[x.startIndex + byte] ^= UInt8(1 << bit); return x
    }

    /// Runs a handshake where `tamper` may modify each message in flight. Returns true when BOTH sides
    /// completed (which must never happen for a modified authenticated field).
    private func completes(host: Identity, disp: Identity,
                           hello t1: (HelloMessage) -> HelloMessage = { $0 },
                           reply t2: (HelloReplyMessage) -> HelloReplyMessage = { $0 },
                           reveal t3: (RevealMessage) -> RevealMessage = { $0 },
                           revealReply t4: (RevealReplyMessage) -> RevealReplyMessage = { $0 }) -> Bool {
        do {
            let h = HostHandshake(identity: host, isKnownPeer: { _ in false })
            let d = DisplayHandshake(identity: disp, isKnownPeer: { _ in false })
            let reply = try d.handleHello(t1(h.makeHello()))
            let reveal = try h.handleHelloReply(t2(reply))
            let (rr, _) = try d.handleReveal(t3(reveal))
            _ = try h.handleRevealReply(t4(rr))
            return true
        } catch { return false }
    }

    func testEveryBitFlipInAuthenticatedHandshakeFieldsFailsClosed() {
        let host = ident("H"), disp = ident("D")
        XCTAssertTrue(completes(host: host, disp: disp))
        for byte in 0..<32 { for bit in 0..<8 {
            XCTAssertFalse(completes(host: host, disp: disp, hello: { var m = $0; m.identityKey = self.flip(m.identityKey, byte, bit); return m }), "hello.identityKey \(byte)/\(bit)")
            XCTAssertFalse(completes(host: host, disp: disp, hello: { var m = $0; m.commit = self.flip(m.commit, byte, bit); return m }), "hello.commit \(byte)/\(bit)")
            XCTAssertFalse(completes(host: host, disp: disp, reply: { var m = $0; m.identityKey = self.flip(m.identityKey, byte, bit); return m }), "reply.identityKey \(byte)/\(bit)")
            XCTAssertFalse(completes(host: host, disp: disp, reply: { var m = $0; m.ephKey = self.flip(m.ephKey, byte, bit); return m }), "reply.ephKey \(byte)/\(bit)")
            XCTAssertFalse(completes(host: host, disp: disp, reply: { var m = $0; m.nonce = self.flip(m.nonce, byte, bit); return m }), "reply.nonce \(byte)/\(bit)")
            XCTAssertFalse(completes(host: host, disp: disp, reveal: { var m = $0; m.ephKey = self.flip(m.ephKey, byte, bit); return m }), "reveal.ephKey \(byte)/\(bit)")
            XCTAssertFalse(completes(host: host, disp: disp, reveal: { var m = $0; m.nonce = self.flip(m.nonce, byte, bit); return m }), "reveal.nonce \(byte)/\(bit)")
        } }
        for byte in 0..<64 { for bit in 0..<8 {
            XCTAssertFalse(completes(host: host, disp: disp, reveal: { var m = $0; m.signature = self.flip(m.signature, byte, bit); return m }), "reveal.signature \(byte)/\(bit)")
            XCTAssertFalse(completes(host: host, disp: disp, revealReply: { var m = $0; m.signature = self.flip(m.signature, byte, bit); return m }), "revealReply.signature \(byte)/\(bit)")
        } }
    }

    func testWrongLengthsAndVersionsAreRejected() {
        let host = ident("H"), disp = ident("D")
        for len in [0, 1, 31, 33, 64, 4096] {
            let junk = Data(repeating: 7, count: len)
            XCTAssertFalse(completes(host: host, disp: disp, hello: { var m = $0; m.commit = junk; return m }))
            XCTAssertFalse(completes(host: host, disp: disp, hello: { var m = $0; m.identityKey = junk; return m }))
            XCTAssertFalse(completes(host: host, disp: disp, reply: { var m = $0; m.nonce = junk; return m }))
            XCTAssertFalse(completes(host: host, disp: disp, reply: { var m = $0; m.ephKey = junk; return m }))
            XCTAssertFalse(completes(host: host, disp: disp, reveal: { var m = $0; m.signature = junk; return m }))
            XCTAssertFalse(completes(host: host, disp: disp, revealReply: { _ in RevealReplyMessage(signature: junk) }))
        }
        XCTAssertFalse(completes(host: host, disp: disp, hello: { var m = $0; m.v = 2; return m }))
        XCTAssertFalse(completes(host: host, disp: disp, reply: { var m = $0; m.v = 0; return m }))
    }

    func testSignatureFromWrongIdentityAndWrongCommit() throws {
        let host = ident("H"), disp = ident("D"), mallory = ident("M")
        // Reveal signed by another identity over the right transcript.
        let h = HostHandshake(identity: host, isKnownPeer: { _ in false })
        let d = DisplayHandshake(identity: disp, isKnownPeer: { _ in false })
        let reply = try d.handleHello(h.makeHello())
        let reveal = try h.handleHelloReply(reply)
        let t = HandshakeCrypto.transcript(idH: host.publicKey, idD: disp.publicKey, ephH: reveal.ephKey,
                                           ephD: reply.ephKey, nonceH: reveal.nonce, nonceD: reply.nonce)
        let forged = RevealMessage(ephKey: reveal.ephKey, nonce: reveal.nonce, signature: try HandshakeCrypto.sign(t, mallory))
        XCTAssertThrowsError(try d.handleReveal(forged)) { XCTAssertEqual($0 as? HandshakeError, .badSignature) }

        // Reveal that does not match the commit (attacker picks its ephemeral after seeing the commit).
        let h2 = HostHandshake(identity: host, isKnownPeer: { _ in false })
        let d2 = DisplayHandshake(identity: disp, isKnownPeer: { _ in false })
        let reply2 = try d2.handleHello(h2.makeHello())
        let reveal2 = try h2.handleHelloReply(reply2)
        let other = RevealMessage(ephKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                  nonce: reveal2.nonce, signature: reveal2.signature)
        XCTAssertThrowsError(try d2.handleReveal(other)) { XCTAssertEqual($0 as? HandshakeError, .commitMismatch) }
        // A failed reveal does not leave the Display half-open: the correct reveal still works once.
        XCTAssertNoThrow(try d2.handleReveal(reveal2))
    }

    func testReplayedRevealAndOutOfOrderMessages() throws {
        let host = ident("H"), disp = ident("D")
        let h = HostHandshake(identity: host, isKnownPeer: { _ in false })
        let d = DisplayHandshake(identity: disp, isKnownPeer: { _ in false })
        let hello = h.makeHello()
        let reply = try d.handleHello(hello)
        let reveal = try h.handleHelloReply(reply)
        let (rr, _) = try d.handleReveal(reveal)
        _ = try h.handleRevealReply(rr)

        // Same reveal twice on one Display, a second hello, and a reply replayed on the Host: wrongState.
        XCTAssertThrowsError(try d.handleReveal(reveal)) { XCTAssertEqual($0 as? HandshakeError, .wrongState) }
        XCTAssertThrowsError(try d.handleHello(hello)) { XCTAssertEqual($0 as? HandshakeError, .wrongState) }
        XCTAssertThrowsError(try h.handleHelloReply(reply)) { XCTAssertEqual($0 as? HandshakeError, .wrongState) }
        XCTAssertThrowsError(try h.handleRevealReply(rr)) { XCTAssertEqual($0 as? HandshakeError, .wrongState) }

        // Recorded hello + reveal replayed against a fresh Display: its new ephemeral key/nonce
        // change the transcript, so the recorded signature fails.
        let fresh = DisplayHandshake(identity: disp, isKnownPeer: { _ in false })
        _ = try fresh.handleHello(hello)
        XCTAssertThrowsError(try fresh.handleReveal(reveal)) { XCTAssertEqual($0 as? HandshakeError, .badSignature) }

        // Out of order from the start.
        let d2 = DisplayHandshake(identity: disp, isKnownPeer: { _ in false })
        XCTAssertThrowsError(try d2.handleReveal(reveal)) { XCTAssertEqual($0 as? HandshakeError, .wrongState) }
        let h2 = HostHandshake(identity: host, isKnownPeer: { _ in false })
        XCTAssertThrowsError(try h2.handleHelloReply(reply)) { XCTAssertEqual($0 as? HandshakeError, .wrongState) }
        XCTAssertThrowsError(try h2.handleRevealReply(rr)) { XCTAssertEqual($0 as? HandshakeError, .wrongState) }
        _ = h2.makeHello()
        XCTAssertThrowsError(try h2.handleRevealReply(rr)) { XCTAssertEqual($0 as? HandshakeError, .wrongState) }
        // A revealReply captured from session 1 does not satisfy a new Host in session 2.
        let d3 = DisplayHandshake(identity: disp, isKnownPeer: { _ in false })
        let reply3 = try d3.handleHello(h2.makeHello())
        _ = try h2.handleHelloReply(reply3)
        XCTAssertThrowsError(try h2.handleRevealReply(rr)) { XCTAssertEqual($0 as? HandshakeError, .badSignature) }
    }

    func testHandshakeRandomMessagesNeverTrap() {
        var rng = SeededRNG(12)
        let host = ident("H"), disp = ident("D")
        for _ in 0..<2000 {
            let h = HostHandshake(identity: host, isKnownPeer: { _ in false })
            let d = DisplayHandshake(identity: disp, isKnownPeer: { _ in false })
            _ = h.makeHello()
            _ = try? d.handleHello(HelloMessage(v: 1, deviceId: "x", deviceName: "y",
                identityKey: rng.bytes([0, 32, 33].randomElement(using: &rng)!),
                commit: rng.bytes([0, 32, 33].randomElement(using: &rng)!)))
            _ = try? h.handleHelloReply(HelloReplyMessage(v: 1, deviceId: "x", deviceName: "y",
                identityKey: rng.bytes(32), ephKey: rng.bytes(32), nonce: rng.bytes(32), knowsPeer: Bool.random(using: &rng)))
            _ = try? h.handleRevealReply(RevealReplyMessage(signature: rng.bytes(64)))
            _ = try? d.handleReveal(RevealMessage(ephKey: rng.bytes(32), nonce: rng.bytes(32), signature: rng.bytes(64)))
        }
    }

    func testPairingCodeFormatAndConstantTimeCompare() throws {
        var rng = SeededRNG(13)
        for _ in 0..<500 {
            let c = HandshakeCrypto.pairingCode(transcript: rng.bytes(32))
            XCTAssertEqual(c.count, 6)
            XCTAssertTrue(c.allSatisfy { $0 >= "0" && $0 <= "9" })
        }
        XCTAssertTrue(constantTimeEqual("012345", "012345"))
        XCTAssertFalse(constantTimeEqual("012345", "012346"))
        XCTAssertFalse(constantTimeEqual("012345", "01234"))
        XCTAssertFalse(constantTimeEqual("", "012345"))
        XCTAssertTrue(constantTimeEqual("", ""))
        // Both sides derive the same code, different sessions derive different ones.
        let a = try runHandshake(), b = try runHandshake()
        XCTAssertEqual(a.2.pairingCode, a.3.pairingCode)
        XCTAssertNotEqual(a.2.transcript, b.2.transcript)
    }

    /// Unauthenticated hello/reply metadata. Documented limitation: deviceId, deviceName and knowsPeer are not
    /// part of the signed transcript, so an active attacker can change them without breaking the handshake
    /// (keys and SAS are unaffected). Display-side enforcement (`paired = peerWasKnown`) does not rely on them.
    func testUnauthenticatedMetadataDoesNotAffectKeysOrCode() throws {
        let host = ident("H"), disp = ident("D")
        let h = HostHandshake(identity: host, isKnownPeer: { _ in false })
        let d = DisplayHandshake(identity: disp, isKnownPeer: { _ in false })
        var hello = h.makeHello()
        hello.deviceName = "Evil"
        var reply = try d.handleHello(hello)
        reply.knowsPeer = true
        let reveal = try h.handleHelloReply(reply)
        let (rr, dres) = try d.handleReveal(reveal)
        let hres = try h.handleRevealReply(rr)
        XCTAssertEqual(hres.pairingCode, dres.pairingCode)
        XCTAssertEqual(dres.peerDeviceName, "Evil")
        XCTAssertEqual(hres.peerKnowsUs, true)
    }
}
