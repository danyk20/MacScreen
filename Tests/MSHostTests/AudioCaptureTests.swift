import XCTest
import MSCore
import MSProtocol
@testable import MSHost

/// Synthetic source: pushes a counting s16 pattern in odd-sized chunks from a timer thread. No CoreAudio.
final class SyntheticAudioSource: AudioInputSource {
    private let queue = DispatchQueue(label: "test.audio.source")
    private var timer: DispatchSourceTimer?
    private(set) var started = false
    func start(onSamples: @escaping (UnsafeRawBufferPointer) -> Void) throws {
        started = true
        var n: Int16 = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(3))
        t.setEventHandler {
            // 7 ms worth = 336 frames: not a multiple of 240.
            var chunk = [Int16](repeating: 0, count: 336 * 2)
            for i in 0..<chunk.count { chunk[i] = n; n &+= 1 }
            chunk.withUnsafeBytes { onSamples($0) }
        }
        timer = t
        t.resume()
    }
    func stop() { timer?.cancel(); timer = nil; started = false }
}

final class FakeAudioDevices: AudioDeviceControlling {
    var devices: [String: AudioDeviceIdentifier] = [:]
    var uids: [AudioDeviceIdentifier: String] = [1: "uid-1", 9: "uid-9", 2: "uid-2", 3: "uid-3"]
    var builtIn: AudioDeviceIdentifier?
    var nonVirtual: AudioDeviceIdentifier?
    var current: AudioDeviceIdentifier? = 1
    var setCalls: [AudioDeviceIdentifier] = []
    func deviceID(named name: String) -> AudioDeviceIdentifier? { devices[name] }
    func defaultOutput() -> AudioDeviceIdentifier? { current }
    func setDefaultOutput(_ id: AudioDeviceIdentifier) -> Bool { setCalls.append(id); current = id; return true }
    func uid(of id: AudioDeviceIdentifier) -> String? { uids[id] }
    func deviceID(uid: String) -> AudioDeviceIdentifier? { uids.first { $0.value == uid }?.key }
    func builtInOutputDevice(excluding: AudioDeviceIdentifier) -> AudioDeviceIdentifier? {
        builtIn == excluding ? nil : builtIn
    }
    func firstNonVirtualOutputDevice(excluding: AudioDeviceIdentifier) -> AudioDeviceIdentifier? {
        nonVirtual == excluding ? nil : nonVirtual
    }
}

/// A fresh UserDefaults suite so tests never touch the app's real preferences.
private func isolatedDefaults() -> UserDefaults {
    let name = "test.audio.\(UUID().uuidString)"
    return UserDefaults(suiteName: name)!
}

final class AudioCaptureTests: XCTestCase {
    func testPacketsAre240FramesWithContiguousSamplesAndSequence() throws {
        let lock = NSLock()
        var got: [AudioPacket] = []
        let cap = AudioCapture(source: SyntheticAudioSource()) { p in lock.lock(); got.append(p); lock.unlock() }
        try cap.start()
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            lock.lock(); let c = got.count; lock.unlock()
            if c >= 20 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        cap.stop()
        lock.lock(); let pk = got; lock.unlock()
        XCTAssertGreaterThanOrEqual(pk.count, 20)
        var expected: Int16 = 0
        for (i, p) in pk.enumerated() {
            XCTAssertEqual(p.seq, UInt32(i))
            XCTAssertEqual(p.pcm.count, 960)
            XCTAssertGreaterThan(p.hostTimeMicros, 0)
            let samples = p.pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            for s in samples { XCTAssertEqual(s, expected); expected &+= 1 }
        }
    }

    func testSwitcherRemembersAndRestoresOnlyIfStillDefault() throws {
        let f = FakeAudioDevices()
        f.devices["MacScreen Display"] = 9
        let defaults = isolatedDefaults()
        let sw = AudioOutputSwitcher(control: f, defaults: defaults)
        XCTAssertTrue(sw.isDevicePresent)
        try sw.enable()
        XCTAssertEqual(f.current, 9)
        sw.restore()
        XCTAssertEqual(f.current, 1)

        try sw.enable()
        f.current = 5                      // user picked something else
        f.setCalls = []
        sw.restore()
        XCTAssertEqual(f.current, 5)
        XCTAssertTrue(f.setCalls.isEmpty)
    }

    func testSwitcherMissingDeviceChangesNothing() {
        let f = FakeAudioDevices()
        let sw = AudioOutputSwitcher(control: f, defaults: isolatedDefaults())
        XCTAssertFalse(sw.isDevicePresent)
        XCTAssertThrowsError(try sw.enable()) { XCTAssertEqual($0 as? AudioSwitchError, .deviceNotFound) }
        sw.restore()
        XCTAssertTrue(f.setCalls.isEmpty)
        XCTAssertEqual(f.current, 1)
    }

    func testStrandedDefaultRestoresToPersistedUID() throws {
        let f = FakeAudioDevices()
        f.devices["MacScreen Display"] = 9
        f.current = 9                                   // a previous run was killed while we were default
        let defaults = isolatedDefaults()
        defaults.set("uid-2", forKey: AudioOutputSwitcher.previousUIDKey)
        let sw = AudioOutputSwitcher(control: f, defaults: defaults)
        sw.restoreIfStranded()
        XCTAssertEqual(f.current, 2)
        XCTAssertNil(defaults.string(forKey: AudioOutputSwitcher.previousUIDKey))
    }

    func testStrandedDefaultFallsBackToBuiltInWhenNoPersistedUID() throws {
        let f = FakeAudioDevices()
        f.devices["MacScreen Display"] = 9
        f.current = 9
        f.builtIn = 3
        f.nonVirtual = 2
        let sw = AudioOutputSwitcher(control: f, defaults: isolatedDefaults())
        sw.restoreIfStranded()
        XCTAssertEqual(f.current, 3)
    }

    func testRestoreIfStrandedDoesNothingWhenOurDeviceIsNotDefault() throws {
        let f = FakeAudioDevices()
        f.devices["MacScreen Display"] = 9
        f.current = 5                                   // user's own output
        f.builtIn = 3
        let defaults = isolatedDefaults()
        defaults.set("uid-2", forKey: AudioOutputSwitcher.previousUIDKey)
        let sw = AudioOutputSwitcher(control: f, defaults: defaults)
        sw.restoreIfStranded()
        XCTAssertTrue(f.setCalls.isEmpty)
        XCTAssertEqual(f.current, 5)
        XCTAssertEqual(defaults.string(forKey: AudioOutputSwitcher.previousUIDKey), "uid-2")
    }

    func testTurningSoundOffWhileActiveRestoresImmediately() throws {
        let f = FakeAudioDevices()
        f.devices["MacScreen Display"] = 9
        let defaults = isolatedDefaults()
        let sw = AudioOutputSwitcher(control: f, defaults: defaults)
        try sw.enable()
        XCTAssertEqual(f.current, 9)
        sw.restore()                                    // what the toggle-off path calls mid-session
        XCTAssertEqual(f.current, 1)
        XCTAssertFalse(sw.isActive)
        XCTAssertNil(defaults.string(forKey: AudioOutputSwitcher.previousUIDKey))
    }

    func testQuitWithStrandedDeviceRestoresEvenWhenNeverEnabled() throws {
        // Sound setting off: this instance never enabled anything. The device is stranded from a previous run.
        let f = FakeAudioDevices()
        f.devices["MacScreen Display"] = 9
        f.current = 9
        f.builtIn = 3
        let sw = AudioOutputSwitcher(control: f, defaults: isolatedDefaults())
        XCTAssertFalse(sw.isActive)
        sw.restore()                                    // quit path: no-op without an active switch
        sw.restoreIfStranded()
        XCTAssertEqual(f.current, 3)
    }

    func testLaunchAfterKilledRunRestoresPersistedOutput() throws {
        let f = FakeAudioDevices()
        f.devices["MacScreen Display"] = 9
        let defaults = isolatedDefaults()
        // First run: switched to our device, then killed (no restore ran).
        let killed = AudioOutputSwitcher(control: f, defaults: defaults)
        try killed.enable()
        XCTAssertEqual(f.current, 9)
        // Second run: a fresh instance sees our device as default and nothing active.
        let launched = AudioOutputSwitcher(control: f, defaults: defaults)
        launched.restoreIfStranded()
        XCTAssertEqual(f.current, 1)
        XCTAssertNil(defaults.string(forKey: AudioOutputSwitcher.previousUIDKey))
    }

    func testRestoreIfStrandedDoesNotRestoreWhileAudioIsActive() throws {
        let f = FakeAudioDevices()
        f.devices["MacScreen Display"] = 9
        let defaults = isolatedDefaults()
        let sw = AudioOutputSwitcher(control: f, defaults: defaults)
        try sw.enable()
        XCTAssertEqual(f.current, 9)
        XCTAssertEqual(defaults.string(forKey: AudioOutputSwitcher.previousUIDKey), "uid-1")
        f.setCalls = []
        sw.restoreIfStranded()                          // session audio active: must leave our device in place
        XCTAssertTrue(f.setCalls.isEmpty)
        XCTAssertEqual(f.current, 9)
        sw.restore()
        XCTAssertEqual(f.current, 1)
        XCTAssertNil(defaults.string(forKey: AudioOutputSwitcher.previousUIDKey))
    }
}
