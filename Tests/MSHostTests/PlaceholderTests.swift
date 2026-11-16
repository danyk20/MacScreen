import XCTest
@testable import MSHost

final class MSHostPlaceholderTests: XCTestCase {
    func testModuleLoads() { XCTAssertEqual(MSHostModule.name, "MSHost") }
}
