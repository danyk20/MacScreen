import XCTest
import Network
import CryptoKit
@testable import MSTransport
import MSProtocol
import MSCore

private final class Collector {
    private let lock = NSLock()
    private var items: [(type: PacketType, payload: Data, at: UInt64)] = []
    func add(_ t: PacketType, _ p: Data) {
        let now = MonoClock.nowMicros()
        lock.lock(); items.append((t, p, now)); lock.unlock()
    }
    var all: [(type: PacketType, payload: Data, at: UInt64)] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}

final class MediaChannelTests: XCTestCase {
    private let queue = DispatchQueue(label: "ms.media.test", qos: .userInteractive)
    private let k1 = SymmetricKey(size: .bits256)   // host -> display
    private let k2 = SymmetricKey(size: .bits256)   // display -> host
    private var server: MediaServer!
    private var client: MediaClient!
    private var serverRx = Collector()
    private var clientRx = Collector()

    private func u32(_ v: UInt32, size: Int = 8) -> Data {
        var d = Data(count: max(size, 4))
        d[0] = UInt8(v >> 24); d[1] = UInt8((v >> 16) & 0xff); d[2] = UInt8((v >> 8) & 0xff); d[3] = UInt8(v & 0xff)
        return d
    }
    private func seq(_ d: Data) -> UInt32 {
        let b = Data(d)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private func wait(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return cond()
    }

    private func setUpPair(connectClient: Bool = true) throws {
        server = MediaServer(sealKey: k2, openKey: k1, queue: queue)
        server.onPacket = { [serverRx] t, p in serverRx.add(t, p) }
        try server.start()
        XCTAssertTrue(wait(5) { self.server.port != nil }, "listener not ready")
        client = MediaClient(host: "127.0.0.1", port: server.port!, sealKey: k1, openKey: k2, queue: queue)
        client.onPacket = { [clientRx] t, p in clientRx.add(t, p) }
        client.start()
    }

    override func tearDown() {
        client?.close(); server?.close()
        client = nil; server = nil
        super.tearDown()
    }

    private func rawConnection() -> NWConnection {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port!)!, using: MediaParameters.udp())
        c.start(queue: DispatchQueue(label: "ms.raw"))
        return c
    }

    func testSinglePacketEachDirection() throws {
        try setUpPair()
        let a = Data((0..<100).map { UInt8($0) })
        client.send(.cursor, a)
        XCTAssertTrue(wait(5) { self.serverRx.count == 1 })
        XCTAssertEqual(serverRx.all[0].type, .cursor)
        XCTAssertEqual(serverRx.all[0].payload, a)
        let b = Data((0..<40).map { UInt8(255 - $0) })
        server.send(.feedback, b)
        XCTAssertTrue(wait(5) { self.clientRx.count == 1 })
        XCTAssertEqual(clientRx.all[0].type, .feedback)
        XCTAssertEqual(clientRx.all[0].payload, b)
    }

    func testTenThousandPacketsAtFiftyMbit() throws {
        try setUpPair()
        let total = 10_000, perBatch = 80
        let start = MonoClock.nowMicros()
        var next = start
        for b in 0..<(total / perBatch) {
            let items: [(PacketType, Data)] = (0..<perBatch).map { i in
                (.videoData, u32(UInt32(b * perBatch + i), size: 1200))
            }
            client.sendBatch(items, paceOverMicros: 4000)
            next += 16_000
            let now = MonoClock.nowMicros()
            if next > now { Thread.sleep(forTimeInterval: Double(next - now) / 1e6) }
        }
        XCTAssertTrue(wait(10) { self.serverRx.count >= total })
        let wall = Double(MonoClock.nowMicros() - start) / 1e6
        print("MEDIA 10000 packets wall time: \(wall) s")
        let rx = serverRx.all
        XCTAssertEqual(rx.count, total)
        for (i, r) in rx.enumerated() {
            XCTAssertEqual(seq(r.payload), UInt32(i), "out of order at \(i)")
            if seq(r.payload) != UInt32(i) { break }
            XCTAssertEqual(r.payload.count, 1200)
        }
        XCTAssertEqual(server.counters.authFailures, 0)
        XCTAssertEqual(server.counters.replays, 0)
        XCTAssertEqual(client.counters.packetsSent, UInt64(total))
        XCTAssertEqual(server.counters.packetsReceived, UInt64(total))
        XCTAssertEqual(client.counters.sendErrors, 0)
    }

    func testPacingSpansTimeAndKeepsOrder() throws {
        try setUpPair()
        client.send(.ping, u32(0))            // establish the return path / connection
        XCTAssertTrue(wait(5) { self.serverRx.count == 1 })
        let items: [(PacketType, Data)] = (1...160).map { (.videoData, u32(UInt32($0))) }
        client.sendBatch(items, paceOverMicros: 8000)
        XCTAssertTrue(wait(5) { self.serverRx.count == 161 })
        let rx = Array(serverRx.all.dropFirst())
        XCTAssertEqual(rx.map { seq($0.payload) }, (1...160).map { UInt32($0) })
        let span = rx.last!.at - rx.first!.at
        XCTAssertGreaterThanOrEqual(span, 5000)
        XCTAssertLessThanOrEqual(span, 40_000)

        // Overlapping batches keep global order.
        let a: [(PacketType, Data)] = (1000..<1100).map { (.videoData, u32(UInt32($0))) }
        let b: [(PacketType, Data)] = (1100..<1200).map { (.videoData, u32(UInt32($0))) }
        client.sendBatch(a, paceOverMicros: 8000)
        client.sendBatch(b, paceOverMicros: 8000)
        client.send(.videoData, u32(1200))
        XCTAssertTrue(wait(5) { self.serverRx.count == 161 + 201 })
        XCTAssertEqual(serverRx.all.dropFirst(161).map { seq($0.payload) }, (1000...1200).map { UInt32($0) })
    }

    func testWrongKeyDatagramRejectedAndReturnPathUnchanged() throws {
        try setUpPair()
        client.send(.cursor, u32(1))
        XCTAssertTrue(wait(5) { self.serverRx.count == 1 })

        let raw = rawConnection()
        let forged = try PacketSealer(key: SymmetricKey(size: .bits256)).seal(type: PacketType.cursor.rawValue, payload: u32(99))
        raw.send(content: forged, completion: .contentProcessed { _ in })
        XCTAssertTrue(wait(5) { self.server.counters.authFailures == 1 })
        XCTAssertEqual(serverRx.count, 1)

        server.send(.feedback, u32(7))
        XCTAssertTrue(wait(5) { self.clientRx.count == 1 })
        XCTAssertEqual(clientRx.all[0].type, .feedback)
        raw.cancel()
    }

    func testReplayDeliveredOnce() throws {
        try setUpPair()
        let raw = rawConnection()
        let sealed = try PacketSealer(key: k1).seal(type: PacketType.audio.rawValue, payload: u32(5))
        raw.send(content: sealed, completion: .contentProcessed { _ in })
        XCTAssertTrue(wait(5) { self.serverRx.count == 1 })
        raw.send(content: sealed, completion: .contentProcessed { _ in })
        XCTAssertTrue(wait(5) { self.server.counters.replays == 1 })
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(serverRx.count, 1)
        XCTAssertEqual(server.counters.authFailures, 0)
        raw.cancel()
    }

    func testServerSendBeforeAnyPacketIsDropped() throws {
        try setUpPair()
        server.send(.feedback, u32(1))
        queue.sync {}
        XCTAssertTrue(wait(2) { self.server.counters.sendErrors == 1 })
        XCTAssertEqual(server.counters.packetsSent, 0)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(clientRx.count, 0)
    }

    func testCloseTwiceAndCountersAddUp() throws {
        try setUpPair()
        for i in 0..<20 { client.send(.cursor, u32(UInt32(i))) }
        XCTAssertTrue(wait(5) { self.serverRx.count == 20 })
        for i in 0..<5 { server.send(.feedback, u32(UInt32(i))) }
        XCTAssertTrue(wait(5) { self.clientRx.count == 5 })
        let c = client.counters, s = server.counters
        XCTAssertEqual(c.packetsSent, 20)
        XCTAssertEqual(s.packetsReceived, 20)
        XCTAssertEqual(c.bytesSent, s.bytesReceived)
        XCTAssertEqual(c.bytesSent, 20 * UInt64(8 + 12 + 16))
        XCTAssertEqual(s.packetsSent, 5)
        XCTAssertEqual(c.packetsReceived, 5)
        XCTAssertEqual(s.bytesSent, c.bytesReceived)
        client.close(); client.close()
        server.close(); server.close()
        client.send(.cursor, u32(1))   // after close: no crash
        queue.sync {}
    }
}
