import XCTest
import Network
import MSCore
@testable import MSTransport

final class ManualAddressTests: XCTestCase {
    private let dp = MSConstants.defaultControlPort

    func testPlainIPv4UsesDefaultPort() {
        XCTAssertEqual(ManualAddress.parse("192.168.1.20"), ManualAddress(host: "192.168.1.20", port: dp))
    }

    func testIPv4WithPortAndWhitespace() {
        XCTAssertEqual(ManualAddress.parse("  10.0.0.5:5000 \n"), ManualAddress(host: "10.0.0.5", port: 5000))
    }

    func testHostnames() {
        XCTAssertEqual(ManualAddress.parse("5k-imac.local"), ManualAddress(host: "5k-imac.local", port: dp))
        XCTAssertEqual(ManualAddress.parse("imac_2:47801"), ManualAddress(host: "imac_2", port: 47801))
    }

    func testIPv6() {
        XCTAssertEqual(ManualAddress.parse("[fe80::1]:47800"), ManualAddress(host: "fe80::1", port: 47800))
        XCTAssertEqual(ManualAddress.parse("[fe80::1]"), ManualAddress(host: "fe80::1", port: dp))
        XCTAssertEqual(ManualAddress.parse("fe80::1"), ManualAddress(host: "fe80::1", port: dp))
    }

    func testSchemeIsTolerated() {
        XCTAssertEqual(ManualAddress.parse("tcp://192.168.1.20:47800"), ManualAddress(host: "192.168.1.20", port: 47800))
    }

    func testRejectsGarbage() {
        for bad in ["", "   ", "host name", "a..b", ".local", "host:", "host:0", "host:65536", "host:abc",
                    "[fe80::1", "[fe80::1]x", "bad/host", "evil;rm", String(repeating: "a", count: 300)] {
            XCTAssertNil(ManualAddress.parse(bad), "should reject \"\(bad.prefix(20))\"")
        }
    }

    func testDisplayTextOmitsDefaultPort() {
        XCTAssertEqual(ManualAddress(host: "1.2.3.4", port: dp).display, "1.2.3.4")
        XCTAssertEqual(ManualAddress(host: "1.2.3.4", port: 5).display, "1.2.3.4:5")
        XCTAssertEqual(ManualAddress(host: "fe80::1", port: 5).display, "[fe80::1]:5")
    }

    func testEndpointIsHostPort() {
        guard case let .hostPort(host, port) = ManualAddress(host: "1.2.3.4", port: 77).endpoint else {
            return XCTFail("expected hostPort")
        }
        XCTAssertEqual("\(host)", "1.2.3.4")
        XCTAssertEqual(port.rawValue, 77)
    }
}

final class AdvertiserPortTests: XCTestCase {
    private func ready(_ a: DisplayAdvertiser) -> XCTestExpectation {
        let e = expectation(description: "ready")
        a.onStateChange = { up in if up { e.fulfill() } }
        return e
    }

    func testUsesPreferredPortWhenFree() throws {
        let port: UInt16 = 47_913
        let a = DisplayAdvertiser(deviceId: "A", deviceName: "A", queue: DispatchQueue(label: "t1"), preferredPort: port)
        let e = ready(a)
        try a.start()
        wait(for: [e], timeout: 5)
        XCTAssertEqual(a.port, port)
        a.stop()
    }

    func testFallsBackToRandomPortWhenTaken() throws {
        let port: UInt16 = 47_914
        let first = DisplayAdvertiser(deviceId: "A", deviceName: "A", queue: DispatchQueue(label: "t2"), preferredPort: port)
        let e1 = ready(first)
        try first.start()
        wait(for: [e1], timeout: 5)
        XCTAssertEqual(first.port, port)

        let second = DisplayAdvertiser(deviceId: "B", deviceName: "B", queue: DispatchQueue(label: "t3"), preferredPort: port)
        let e2 = ready(second)
        try second.start()
        wait(for: [e2], timeout: 5)
        XCTAssertNotNil(second.port)
        XCTAssertNotEqual(second.port, port)
        first.stop(); second.stop()
    }
}
