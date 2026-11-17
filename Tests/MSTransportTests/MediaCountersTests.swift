import XCTest
@testable import MSTransport

final class MediaCountersTests: XCTestCase {
    func testPacketsLostSaturatesInsteadOfTrapping() {
        // A counter jump by an authenticated peer can be up to 2^64; two of them used to overflow `+=`.
        var c = MediaCounters()
        c.addLost(UInt64.max - 1)
        c.addLost(UInt64.max - 1)
        XCTAssertEqual(c.packetsLost, UInt64.max)
        c.addLost(5)
        XCTAssertEqual(c.packetsLost, UInt64.max)
        var d = MediaCounters()
        d.addLost(3); d.addLost(4)
        XCTAssertEqual(d.packetsLost, 7)
    }
}

import Network
import CryptoKit
import MSProtocol

final class MediaServerHostileInputTests: XCTestCase {
    private struct RNG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testGarbageTamperedAndReplayedDatagramsAreDroppedAndCounted() throws {
        let key = SymmetricKey(data: Data(repeating: 9, count: 32))
        let queue = DispatchQueue(label: "test.media.hostile")
        let server = MediaServer(sealKey: SymmetricKey(data: Data(repeating: 1, count: 32)), openKey: key, queue: queue)
        let delivered = NSLock(); var got: [(PacketType, Data)] = []
        server.onPacket = { t, p in delivered.lock(); got.append((t, p)); delivered.unlock() }
        let port = DispatchSemaphore(value: 0)
        server.onListening = { _ in port.signal() }
        try server.start()
        defer { server.close() }
        guard port.wait(timeout: .now() + 5) == .success, let p = server.port else { throw XCTSkip("no port") }

        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p)!, using: MediaParameters.udp())
        let ready = DispatchSemaphore(value: 0)
        conn.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        conn.start(queue: DispatchQueue(label: "test.media.raw"))
        guard ready.wait(timeout: .now() + 5) == .success else { throw XCTSkip("udp not ready") }
        defer { conn.cancel() }

        var rng = RNG(s: 77)
        func send(_ d: Data) { conn.send(content: d, completion: .contentProcessed { _ in }) }
        let sealer = PacketSealer(key: key)
        let valid = try sealer.seal(type: PacketType.cursor.rawValue, payload: Data([1, 2, 3]))
        var hostile = 0
        for i in 0..<300 {
            var d = Data((0..<Int.random(in: 1...1400, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            if i % 3 == 0 { d = valid; d[Int.random(in: 0..<d.count, using: &rng)] ^= 0x10 }
            send(d); hostile += 1
        }
        send(valid); send(valid); send(valid)  // 1 delivery + 2 replays
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            delivered.lock(); let n = got.count; delivered.unlock()
            if n >= 1, server.counters.authFailures + server.counters.replays >= 100 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.2)
        delivered.lock(); let g = got; delivered.unlock()
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.first?.0, .cursor)
        XCTAssertEqual(g.first?.1, Data([1, 2, 3]))
        XCTAssertGreaterThan(server.counters.authFailures, 50)  // UDP may drop some under load
        XCTAssertEqual(server.counters.packetsReceived, 1)
    }
}
