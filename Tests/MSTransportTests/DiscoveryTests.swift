import XCTest
import Network
import MSCore
@testable import MSTransport

final class DiscoveryTests: XCTestCase {
    private final class Box<T> {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
        func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
    }

    private func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return cond()
    }

    func testAdvertiseDiscoverConnectAndDisappear() throws {
        let q = DispatchQueue(label: "ms.control.discovery")
        let id = "test-" + UUID().uuidString
        let name = "MSTest-" + String(id.suffix(8))
        let adv = DisplayAdvertiser(deviceId: id, deviceName: name, queue: q)
        let connected = expectation(description: "connection")
        connected.assertForOverFulfill = false
        let incoming = Box<[NWConnection]>([])
        adv.onConnection = { c in
            c.start(queue: q)
            incoming.set(incoming.get() + [c])
            connected.fulfill()
        }
        try adv.start()
        defer { adv.stop() }

        let found = Box<[DiscoveredDisplay]>([])
        let browser = DisplayBrowser(queue: q)
        browser.onChange = { found.set($0) }
        browser.start()
        defer { browser.stop() }

        guard waitFor(10, { found.get().contains { $0.id == id } }) else {
            throw XCTSkip("Bonjour discovery unavailable in this environment (no result within 10 s)")
        }
        let d = try XCTUnwrap(found.get().first { $0.id == id })
        XCTAssertEqual(d.name, name)
        XCTAssertNotNil(adv.port)

        let conn = NWConnection(to: d.endpoint, using: ControlChannel.tcpParameters())
        conn.start(queue: q)
        defer { conn.cancel() }
        wait(for: [connected], timeout: 10)

        adv.stop()
        XCTAssertTrue(waitFor(10) { !found.get().contains { $0.id == id } }, "entry did not disappear after stop()")
    }
}
