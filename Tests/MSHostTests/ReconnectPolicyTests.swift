import XCTest
@testable import MSHost

final class ReconnectPolicyTests: XCTestCase {
    func testNotArmedBeforeConnect() {
        let p = ReconnectPolicy()
        XCTAssertFalse(p.shouldReconnect(seenIds: ["d"], now: 100))
        XCTAssertNil(p.waitTime(now: 0))
    }

    func testReconnectsAfterCloseWithBackoff() {
        var p = ReconnectPolicy()
        p.userConnect(id: "d")
        p.sessionStreaming()
        p.sessionEnded(.closed(.timeout), now: 10)
        XCTAssertFalse(p.shouldReconnect(seenIds: ["d"], now: 10.5), "backoff")
        XCTAssertFalse(p.shouldReconnect(seenIds: [], now: 20), "display not seen")
        XCTAssertTrue(p.shouldReconnect(seenIds: ["d"], now: 11))
        p.reconnectStarted()
        XCTAssertFalse(p.shouldReconnect(seenIds: ["d"], now: 50), "attempt in flight")
    }

    func testBackoffGrowsAndCapsAndResets() {
        var p = ReconnectPolicy()
        p.userConnect(id: "d")
        var delays: [Double] = []
        for _ in 0..<8 {
            p.sessionEnded(.failure("x"), now: 0)
            delays.append(p.nextAllowedAt)
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
        p.sessionStreaming()
        p.sessionEnded(.peerBye("busy"), now: 100)
        XCTAssertEqual(p.nextAllowedAt, 101)
    }

    func testUserDisconnectDisablesUntilConnect() {
        var p = ReconnectPolicy()
        p.userConnect(id: "d")
        p.userDisconnect()
        p.sessionEnded(.stopped, now: 0)
        XCTAssertFalse(p.shouldReconnect(seenIds: ["d"], now: 1000))
        p.userConnect(id: "d")
        p.sessionEnded(.closed(.peerClosed), now: 0)
        XCTAssertTrue(p.shouldReconnect(seenIds: ["d"], now: 5))
    }

    func testUserReconnectKeepsAutoReconnectWithoutBackoff() {
        var p = ReconnectPolicy()
        p.userConnect(id: "d")
        p.sessionStreaming()
        p.userReconnect(id: "d")
        XCTAssertTrue(p.enabled)
        XCTAssertEqual(p.nextAllowedAt, 0)
        XCTAssertFalse(p.shouldReconnect(seenIds: ["d"], now: 0), "attempt in flight")
        p.sessionEnded(.closed(.peerClosed), now: 0)
        XCTAssertTrue(p.enabled)
        XCTAssertTrue(p.shouldReconnect(seenIds: ["d"], now: 1.5))
    }

    func testPairingFailuresDisable() {
        var p = ReconnectPolicy()
        p.userConnect(id: "d")
        p.sessionEnded(.pairingDenied, now: 0)
        XCTAssertFalse(p.enabled)
        p.userConnect(id: "d")
        p.sessionEnded(.pairingCodeMismatch, now: 0)
        XCTAssertFalse(p.enabled)
    }
}
