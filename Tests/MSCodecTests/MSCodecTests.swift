import XCTest
@testable import MSCodec

final class MSCodecTests: XCTestCase {
    func testModuleName() {
        XCTAssertEqual(MSCodecModule.name, "MSCodec")
    }
}
