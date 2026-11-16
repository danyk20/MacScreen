import XCTest
@testable import MSTransport

final class MSTransportTests: XCTestCase {
    func testModuleName() {
        XCTAssertEqual(MSTransportModule.name, "MSTransport")
    }
}
