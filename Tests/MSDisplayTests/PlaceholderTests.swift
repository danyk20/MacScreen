import XCTest
@testable import MSDisplay

final class MSDisplayPlaceholderTests: XCTestCase {
    func testModuleLoads() { XCTAssertEqual(MSDisplayModule.name, "MSDisplay") }
}
