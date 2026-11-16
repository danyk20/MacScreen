import XCTest
import Network
@testable import MSTransport

final class ConnectPlannerTests: XCTestCase {
    func testDefaultOrderAndTimeouts() {
        let a = ConnectPlanner().attempts
        XCTAssertEqual(a.map { $0.interface }, [.wiredEthernet, .wifi, nil])
        XCTAssertEqual(a[0].timeout, 0.5)
        XCTAssertEqual(a[1].timeout, 0.5)
    }

    func testWiredWinsStopsEarly() async {
        var tried: [NWInterface.InterfaceType?] = []
        let r = await ConnectPlanner().run { a -> String? in tried.append(a.interface); return "ok" }
        XCTAssertEqual(r?.attempt.interface, .wiredEthernet)
        XCTAssertEqual(tried.count, 1)
    }

    func testFallsThroughToWifiThenAny() async {
        var tried: [NWInterface.InterfaceType?] = []
        let r = await ConnectPlanner().run { a -> Int? in tried.append(a.interface); return a.interface == nil ? 3 : nil }
        XCTAssertEqual(tried, [.wiredEthernet, .wifi, nil])
        XCTAssertEqual(r?.result, 3)
    }

    func testAllFailAndCancel() async {
        let r = await ConnectPlanner().run { _ -> Int? in nil }
        XCTAssertNil(r)
        var n = 0
        _ = await ConnectPlanner().run(shouldContinue: { n == 0 }) { _ -> Int? in n += 1; return nil }
        XCTAssertEqual(n, 1)
    }
}
