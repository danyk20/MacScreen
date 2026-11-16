import XCTest
@testable import MSProtocol

final class MSProtocolTests: XCTestCase {
    func testModuleName() {
        XCTAssertEqual(MSProtocolModule.name, "MSProtocol")
    }
}
