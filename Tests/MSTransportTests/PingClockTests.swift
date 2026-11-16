import XCTest
@testable import MSTransport
import MSProtocol

final class PingClockTests: XCTestCase {
    /// Simulates a peer whose clock = local + offset.
    private func exchange(_ c: PingClock, at t0: UInt64, offset: Int64, up: UInt64, down: UInt64, proc: UInt64 = 0) {
        let ping = c.makePing(nowMicros: t0)
        let t1 = UInt64(Int64(t0 + up) + offset)
        let t2 = t1 + proc
        let pong = c.handlePing(ping, receivedAtMicros: t1, sendingAtMicros: t2)
        c.handlePong(pong, nowMicros: t0 + up + proc + down)
    }

    func testSymmetricPositiveOffset() {
        let c = PingClock()
        XCTAssertNil(c.rttMs); XCTAssertNil(c.offsetMicros); XCTAssertNil(c.minRttMs)
        for i in 0..<5 { exchange(c, at: 10_000_000 + UInt64(i) * 250_000, offset: 5_000_000, up: 1000, down: 1000) }
        XCTAssertEqual(c.rttMs!, 2.0, accuracy: 0.001)
        XCTAssertEqual(c.minRttMs!, 2.0, accuracy: 0.001)
        XCTAssertEqual(Double(c.offsetMicros!), 5_000_000, accuracy: 1)
        XCTAssertEqual(c.sampleCount, 5)
    }

    func testNegativeOffset() {
        let c = PingClock()
        exchange(c, at: 50_000_000, offset: -7_000_000, up: 1000, down: 1000)
        XCTAssertEqual(Double(c.offsetMicros!), -7_000_000, accuracy: 1)
    }

    func testOffsetComesFromMinRttSample() {
        let c = PingClock()
        exchange(c, at: 1_000_000, offset: 5_000_000, up: 1000, down: 1000)       // clean
        exchange(c, at: 2_000_000, offset: 5_000_000, up: 9000, down: 1000)       // skewed
        exchange(c, at: 3_000_000, offset: 5_000_000, up: 1000, down: 12000)      // skewed
        XCTAssertEqual(Double(c.offsetMicros!), 5_000_000, accuracy: 1)
        XCTAssertEqual(c.minRttMs!, 2.0, accuracy: 0.001)
    }

    func testUnknownAndDuplicatePongIgnored() {
        let c = PingClock()
        c.handlePong(PongPacket(id: 99, t0: 1, t1: 2, t2: 3), nowMicros: 10)
        XCTAssertEqual(c.sampleCount, 0)
        let ping = c.makePing(nowMicros: 1000)
        XCTAssertEqual(ping.id, 1)
        let bad = PongPacket(id: ping.id, t0: 999, t1: 0, t2: 0)
        c.handlePong(bad, nowMicros: 2000)
        XCTAssertEqual(c.sampleCount, 0)
        let pong = c.handlePing(ping, receivedAtMicros: 1500, sendingAtMicros: 1500)
        c.handlePong(pong, nowMicros: 2000)
        c.handlePong(pong, nowMicros: 2100)
        XCTAssertEqual(c.sampleCount, 1)
        XCTAssertEqual(c.makePing(nowMicros: 3000).id, 2)
    }

    func testProcessingTimeExcluded() {
        let c = PingClock()
        exchange(c, at: 1_000_000, offset: 0, up: 1000, down: 1000, proc: 5000)
        XCTAssertEqual(c.rttMs!, 2.0, accuracy: 0.001)
    }

    func testEwmaStepChange() {
        let c = PingClock()
        for i in 0..<3 { exchange(c, at: UInt64(i + 1) * 1_000_000, offset: 0, up: 1000, down: 1000) }
        XCTAssertEqual(c.rttMs!, 2.0, accuracy: 0.001)
        exchange(c, at: 10_000_000, offset: 0, up: 5000, down: 5000)   // 10 ms sample
        XCTAssertEqual(c.rttMs!, 2.0 + 8.0 / 8.0, accuracy: 0.001)
        for i in 0..<100 { exchange(c, at: 20_000_000 + UInt64(i) * 1000, offset: 0, up: 5000, down: 5000) }
        XCTAssertEqual(c.rttMs!, 10.0, accuracy: 0.01)
    }

    func testOnlyLast16SamplesKept() {
        let c = PingClock()
        exchange(c, at: 1_000_000, offset: 0, up: 100, down: 100)   // tiny rtt, will age out
        for i in 0..<16 { exchange(c, at: 2_000_000 + UInt64(i) * 1000, offset: 0, up: 1000, down: 1000) }
        XCTAssertEqual(c.minRttMs!, 2.0, accuracy: 0.001)
        XCTAssertEqual(c.sampleCount, 17)
    }

    func testReset() {
        let c = PingClock()
        exchange(c, at: 1_000_000, offset: 3, up: 1000, down: 1000)
        c.reset()
        XCTAssertNil(c.rttMs); XCTAssertNil(c.offsetMicros); XCTAssertEqual(c.sampleCount, 0)
    }
}
