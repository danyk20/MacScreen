import CPrivateAPI
import CoreGraphics
import XCTest
@testable import MSHost

final class VirtualDisplayTests: XCTestCase {
    private var created: [VirtualDisplay] = []

    override func tearDown() {
        // Destroy, then wait for the ids to go offline: WindowServer reuses ids and tears
        // displays down asynchronously, which would otherwise disturb the next test.
        let ids = created.map { $0.displayID }
        created.forEach { $0.destroy() }
        created.removeAll()
        poll(3) { !ids.contains(where: { isOnline($0) }) }
        if !ids.isEmpty { spin(1.0) }
        super.tearDown()
    }

    // MARK: Helpers

    private func config(_ w: Int, _ h: Int, hiDPI: Bool, serial: UInt32 = UInt32.random(in: 1...UInt32.max)) -> VirtualDisplayConfig {
        VirtualDisplayConfig(name: "MacScreen Test", pixelWidth: w, pixelHeight: h, hiDPI: hiDPI,
                             refreshRate: 60, sizeMM: CGSize(width: 600, height: 337.5), serial: serial)
    }

    private func make(_ c: VirtualDisplayConfig) throws -> VirtualDisplay {
        let vd = try VirtualDisplay.create(c)
        created.append(vd)
        return vd
    }

    private func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    @discardableResult
    private func poll(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return cond()
    }

    private func profilerText() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPDisplaysDataType"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// CoreGraphics' in-process online list can be stale in xctest (see observedMode), so a
    /// display counts as online if CG lists it or system_profiler (separate process) shows it.
    private func isOnline(_ id: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        if CGGetOnlineDisplayList(64, &ids, &count) == .success, ids.prefix(Int(count)).contains(id) {
            return true
        }
        return profilerText().contains("MacScreen Test:")
    }

    /// Mode as reported by CoreGraphics. On macOS 27, a non-GUI process (xctest) that creates a
    /// second virtual display gets nil from CGDisplayCopyDisplayMode / CGDisplayScreenSize even
    /// though WindowServer has the right mode (stale client-side cache). In that case fall back
    /// to asking system_profiler (separate process) about the "MacScreen Test" display.
    private func observedMode(_ id: CGDirectDisplayID) -> (px: (Int, Int), pt: (Int, Int), viaProfiler: Bool)? {
        if let m = VirtualDisplay.currentModeDescription(id) {
            return ((m.pixelsWide, m.pixelsHigh), (m.pointsWide, m.pointsHigh), false)
        }
        let text = profilerText()
        guard let r = text.range(of: "MacScreen Test:") else { return nil }
        let block = String(text[r.upperBound...].prefix(400))
        func nums(_ key: String) -> (Int, Int)? {
            guard let kr = block.range(of: key) else { return nil }
            let rest = block[kr.upperBound...].prefix(40)
            let parts = rest.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return parts.count >= 2 ? (parts[0], parts[1]) : nil
        }
        guard let px = nums("Resolution:") else { return nil }
        let pt = nums("UI Looks like:") ?? px
        return (px, pt, true)
    }

    private func modeIs(_ id: CGDirectDisplayID, px: (Int, Int), pt: (Int, Int)) -> Bool {
        guard let m = observedMode(id) else { return false }
        return m.px == px && m.pt == pt
    }

    // MARK: Tests

    func testPrivateAPIAvailable() {
        XCTAssertTrue(MSPrivateAPIAvailable())
    }

    func testCreateHiDPI() throws {
        let c = config(3840, 2160, hiDPI: true)
        let vd = try make(c)
        XCTAssertNotEqual(vd.displayID, 0)
        XCTAssertTrue(poll(3) { isOnline(vd.displayID) }, "display not online")
        let id = vd.displayID
        XCTAssertEqual(CGDisplayVendorNumber(id), 0x4D53)
        XCTAssertEqual(CGDisplayModelNumber(id), 1)
        XCTAssertEqual(CGDisplaySerialNumber(id), c.serial)
        _ = poll(3) { modeIs(id, px: (3840, 2160), pt: (1920, 1080)) }
        let m = observedMode(id)
        print("HiDPI mode: \(String(describing: m))")
        XCTAssertEqual(m?.px.0, 3840, "mode: \(String(describing: m))")
        XCTAssertEqual(m?.px.1, 2160, "mode: \(String(describing: m))")
        XCTAssertEqual(m?.pt.0, 1920)
        XCTAssertEqual(m?.pt.1, 1080)
        if m?.viaProfiler == false {  // CGDisplayScreenSize is 0 in the stale-cache state
            let size = CGDisplayScreenSize(id)
            print("Screen size mm: \(size)")
            XCTAssertEqual(size.width, 600, accuracy: 1)
            XCTAssertEqual(size.height, 337.5, accuracy: 1)
        }
    }

    func testCreateNonHiDPI() throws {
        let vd = try make(config(2560, 1440, hiDPI: false))
        let id = vd.displayID
        XCTAssertTrue(poll(3) { isOnline(id) })
        _ = poll(3) { modeIs(id, px: (2560, 1440), pt: (2560, 1440)) }
        let m = observedMode(id)
        print("Non-HiDPI mode: \(String(describing: m))")
        XCTAssertEqual(m?.px.0, 2560)
        XCTAssertEqual(m?.px.1, 1440)
        XCTAssertEqual(m?.pt.0, 2560)
        XCTAssertEqual(m?.pt.1, 1440)
    }

    func testApplySwitchesMode() throws {
        let hi = config(3840, 2160, hiDPI: true)
        let vd = try make(hi)
        let id = vd.displayID
        XCTAssertTrue(poll(3) { modeIs(id, px: (3840, 2160), pt: (1920, 1080)) },
                      "initial: \(String(describing: observedMode(id)))")

        var lo = hi
        lo.pixelWidth = 2560; lo.pixelHeight = 1440; lo.hiDPI = false
        try vd.apply(lo)
        XCTAssertEqual(vd.config, lo)
        XCTAssertTrue(poll(3) { modeIs(id, px: (2560, 1440), pt: (2560, 1440)) },
                      "after apply lo: \(String(describing: observedMode(id)))")

        try vd.apply(hi)
        XCTAssertTrue(poll(3) { modeIs(id, px: (3840, 2160), pt: (1920, 1080)) },
                      "after apply hi: \(String(describing: observedMode(id)))")
        XCTAssertEqual(vd.displayID, id)

        var renamed = hi; renamed.name = "Other"
        XCTAssertThrowsError(try vd.apply(renamed)) { XCTAssertTrue(isInvalid($0)) }
        var reserial = hi; reserial.serial = 1
        XCTAssertThrowsError(try vd.apply(reserial)) { XCTAssertTrue(isInvalid($0)) }
        var bigger = hi; bigger.pixelWidth = 4096
        XCTAssertThrowsError(try vd.apply(bigger)) { XCTAssertTrue(isInvalid($0)) }
    }

    func testDestroy() throws {
        let vd = try make(config(1920, 1080, hiDPI: false))
        let id = vd.displayID
        XCTAssertTrue(poll(3) { isOnline(id) })
        vd.destroy()
        XCTAssertTrue(poll(3) { !isOnline(id) }, "display still online after destroy")
        vd.destroy()
    }

    func testStaysAlive() throws {
        let vd = try make(config(1920, 1080, hiDPI: false))
        let id = vd.displayID
        XCTAssertTrue(poll(3) { isOnline(id) })
        spin(5)
        XCTAssertTrue(isOnline(id))
    }

    func testMirroring() throws {
        let vd = try make(config(1920, 1080, hiDPI: false))
        XCTAssertTrue(poll(3) { isOnline(vd.displayID) })
        XCTAssertFalse(vd.isMirroringMain)
        try vd.setMirrorsMain(true)
        XCTAssertTrue(poll(2) { vd.isMirroringMain })
        try vd.setMirrorsMain(false)
        XCTAssertTrue(poll(2) { !vd.isMirroringMain })
    }

    private func isInvalid(_ e: Error) -> Bool {
        if case VirtualDisplayError.invalidConfig = e { return true }
        return false
    }

    func testValidationErrors() {
        let bad: [VirtualDisplayConfig] = [
            config(1921, 1080, hiDPI: false),
            config(1920, 1081, hiDPI: false),
            config(320, 200, hiDPI: false),
            config(9000, 1080, hiDPI: false),
            { var c = config(1920, 1080, hiDPI: false); c.refreshRate = 500; return c }(),
            { var c = config(1920, 1080, hiDPI: false); c.refreshRate = 10; return c }(),
            { var c = config(1920, 1080, hiDPI: false); c.sizeMM = .zero; return c }(),
        ]
        for c in bad {
            XCTAssertThrowsError(try VirtualDisplay.create(c)) { XCTAssertTrue(isInvalid($0), "\(c)") }
        }
    }

    func testCreateOffMainThread() {
        let exp = expectation(description: "bg")
        var result: Error?
        DispatchQueue.global().async {
            do {
                let vd = try VirtualDisplay.create(self.config(1920, 1080, hiDPI: false))
                DispatchQueue.main.async { vd.destroy() }
            } catch { result = error }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(result as? VirtualDisplayError, .notMainThread)
    }

    func testSerialForDeviceId() {
        let a = VirtualDisplay.serial(forDeviceId: "device-a")
        XCTAssertEqual(a, VirtualDisplay.serial(forDeviceId: "device-a"))
        XCTAssertNotEqual(a, VirtualDisplay.serial(forDeviceId: "device-b"))
        // SHA-256("abc") = ba7816bf...
        XCTAssertEqual(VirtualDisplay.serial(forDeviceId: "abc"), 0xBA7816BF)
    }
}
