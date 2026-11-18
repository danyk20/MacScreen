import XCTest
@testable import MSProtocol

final class DeviceNameTests: XCTestCase {
    func testTrimsAndCollapsesWhitespace() {
        XCTAssertEqual(DeviceName.sanitize("  Living   room \n iMac "), "Living room iMac")
    }

    func testEmptyOrBlankIsNil() {
        XCTAssertNil(DeviceName.sanitize(""))
        XCTAssertNil(DeviceName.sanitize("  \n\t "))
    }

    func testControlCharactersRemoved() {
        XCTAssertEqual(DeviceName.sanitize("Mac\u{0}\u{7}Book"), "MacBook")
    }

    func testLengthLimited() {
        let n = DeviceName.sanitize(String(repeating: "x", count: 200))
        XCTAssertEqual(n?.count, DeviceName.maxLength)
    }

    func testUnicodeKept() {
        XCTAssertEqual(DeviceName.sanitize("Danielov iMac \u{1F5A5}"), "Danielov iMac \u{1F5A5}")
    }

    func testRenamePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ms-rename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try IdentityStore(directory: dir, defaultDeviceName: "Old")
        try store.setDeviceName("New name")
        XCTAssertEqual(store.identity.deviceName, "New name")
        let reopened = try IdentityStore(directory: dir, defaultDeviceName: "Ignored")
        XCTAssertEqual(reopened.identity.deviceName, "New name")
        XCTAssertEqual(reopened.identity.deviceId, store.identity.deviceId)
    }
}
