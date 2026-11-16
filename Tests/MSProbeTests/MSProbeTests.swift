import XCTest
@testable import MSProbe

final class MSProbeTests: XCTestCase {
    func testModuleName() {
        XCTAssertEqual(MSProbeModule.name, "MSProbe")
    }
}
