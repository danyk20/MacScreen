import XCTest
@testable import MSCore

final class MSCoreTests: XCTestCase {
    func testModuleName() {
        XCTAssertEqual(MSCoreModule.name, "MSCore")
    }
}
