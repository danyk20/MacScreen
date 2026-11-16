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
    var current: AudioDeviceIdentifier? = 1
    var setCalls: [AudioDeviceIdentifier] = []
    func deviceID(named name: String) -> AudioDeviceIdentifier? { devices[name] }
    func defaultOutput() -> AudioDeviceIdentifier? { current }
    func setDefaultOutput(_ id: AudioDeviceIdentifier) -> Bool { setCalls.append(id); current = id; return true }
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
        let sw = AudioOutputSwitcher(control: f)
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
        let sw = AudioOutputSwitcher(control: f)
        XCTAssertFalse(sw.isDevicePresent)
        XCTAssertThrowsError(try sw.enable()) { XCTAssertEqual($0 as? AudioSwitchError, .deviceNotFound) }
        sw.restore()
        XCTAssertTrue(f.setCalls.isEmpty)
        XCTAssertEqual(f.current, 1)
    }
}
