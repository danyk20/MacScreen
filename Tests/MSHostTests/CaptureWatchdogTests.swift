import XCTest
@testable import MSHost

final class CaptureWatchdogTests: XCTestCase {
    /// Ticks every 0.5 s from `from` to `to` with a fixed count; returns (time, action) for non-none actions.
    private func run(_ w: inout CaptureWatchdog, from: Double, to: Double, count: UInt64,
                     running: Bool = false, screen: Bool = true) -> [(Double, CaptureWatchdog.Action)] {
        var out: [(Double, CaptureWatchdog.Action)] = []
        var t = from
        while t <= to + 1e-9 {
            let a = w.tick(now: t, frameCount: count, streamRunning: running, screenAvailable: screen)
            if a != .none { out.append((t, a)) }
            t += 0.5
        }
        return out
    }

    func testHealthyStreamDoesNothing() {
        var w = CaptureWatchdog()
        for i in 0..<100 {
            XCTAssertEqual(w.tick(now: Double(i) * 0.5, frameCount: UInt64(i * 10), streamRunning: true,
                                  screenAvailable: true), .none)
        }
        XCTAssertTrue(w.isHealthy)
    }

    /// The reported bug: SCK stopped the stream (display slept) and nothing restarted it.
    func testStoppedStreamEscalatesRestartRecreateEnd() {
        var w = CaptureWatchdog()
        _ = w.tick(now: 0, frameCount: 5, streamRunning: true, screenAvailable: true)
        let acts = run(&w, from: 0.5, to: 30, count: 5, running: false)
        XCTAssertEqual(acts.map { $0.1 }, [.restartCapture, .recreateDisplay, .endSession])
        XCTAssertEqual(acts.map { $0.0 }, [2, 6, 15])
        XCTAssertEqual(CaptureWatchdog.endAfter, 15)
        XCTAssertFalse(w.isHealthy)
    }

    /// Static screen: SCK goes silent but the stream runs; only an occasional cheap restart, and the
    /// capture stays "healthy" until then (the Host keeps its heartbeat).
    func testSilentRunningStreamRestartsLate() {
        var w = CaptureWatchdog()
        _ = w.tick(now: 0, frameCount: 5, streamRunning: true, screenAvailable: true)
        XCTAssertTrue(run(&w, from: 0.5, to: 9.5, count: 5, running: true).isEmpty)
        XCTAssertTrue(w.isHealthy)
        XCTAssertEqual(w.tick(now: 10, frameCount: 5, streamRunning: true, screenAvailable: true), .restartCapture)
        XCTAssertFalse(w.isHealthy)
        XCTAssertEqual(w.tick(now: 10.5, frameCount: 6, streamRunning: true, screenAvailable: true), .none)
        XCTAssertTrue(w.isHealthy)
    }

    func testSilentStreamThatStaysSilentEscalates() {
        var w = CaptureWatchdog()
        _ = w.tick(now: 0, frameCount: 5, streamRunning: true, screenAvailable: true)
        let acts = run(&w, from: 0.5, to: 40, count: 5, running: true)
        XCTAssertEqual(acts.map { $0.1 }, [.restartCapture, .recreateDisplay, .endSession])
        XCTAssertEqual(acts.map { $0.0 }, [10, 14, 23])
    }

    func testFramesResumingResetsEscalation() {
        var w = CaptureWatchdog()
        _ = w.tick(now: 0, frameCount: 1, streamRunning: true, screenAvailable: true)
        XCTAssertEqual(w.tick(now: 2, frameCount: 1, streamRunning: false, screenAvailable: true), .restartCapture)
        XCTAssertEqual(w.tick(now: 3, frameCount: 9, streamRunning: true, screenAvailable: true), .none)
        XCTAssertTrue(w.isHealthy)
        // A later stall starts over at restart, not at the next stage.
        let acts = run(&w, from: 3.5, to: 6, count: 9, running: false)
        XCTAssertEqual(acts.map { $0.1 }, [.restartCapture])
        XCTAssertEqual(acts.first?.0, 5)
    }

    func testScreenUnavailablePausesThenRestartsOnReturn() {
        var w = CaptureWatchdog()
        _ = w.tick(now: 0, frameCount: 3, streamRunning: true, screenAvailable: true)
        // Display asleep for a minute, stream stopped by SCK: no escalation at all.
        XCTAssertTrue(run(&w, from: 0.5, to: 60, count: 3, running: false, screen: false).isEmpty)
        XCTAssertTrue(w.isWaitingForScreen)
        XCTAssertFalse(w.isHealthy)
        // Screen back, frames still missing: immediate restart, then the normal ladder from there.
        XCTAssertEqual(w.tick(now: 60.5, frameCount: 3, streamRunning: false, screenAvailable: true), .restartCapture)
        XCTAssertFalse(w.isWaitingForScreen)
        let acts = run(&w, from: 61, to: 80, count: 3, running: false)
        XCTAssertEqual(acts.map { $0.1 }, [.recreateDisplay, .endSession])
        XCTAssertEqual(acts.map { $0.0 }, [64.5, 73.5])
    }

    func testScreenBackWithFramesFlowingNeedsNoRestart() {
        var w = CaptureWatchdog()
        _ = w.tick(now: 0, frameCount: 3, streamRunning: true, screenAvailable: true)
        XCTAssertEqual(w.tick(now: 1, frameCount: 3, streamRunning: true, screenAvailable: false), .none)
        XCTAssertEqual(w.tick(now: 1.5, frameCount: 4, streamRunning: true, screenAvailable: true), .none)
        XCTAssertFalse(w.isWaitingForScreen)
    }
}

final class WakeGateTests: XCTestCase {
    func testProceedsWhenAwakeAndUnlocked() {
        let g = WakeGate(startedAt: 100)
        XCTAssertEqual(g.decide(now: 100, screenAsleep: false, locked: false), .proceed)
    }

    func testWaitsWhileAsleepOrLocked() {
        let g = WakeGate(startedAt: 100)
        XCTAssertEqual(g.decide(now: 100.5, screenAsleep: true, locked: false), .wait)
        XCTAssertEqual(g.decide(now: 130, screenAsleep: false, locked: true), .wait)
        XCTAssertEqual(g.decide(now: 159.9, screenAsleep: true, locked: true), .wait)
        XCTAssertEqual(g.decide(now: 145, screenAsleep: false, locked: false), .proceed)
    }

    func testBoundedWait() {
        let g = WakeGate(startedAt: 100)
        XCTAssertEqual(g.decide(now: 100 + WakeGate.timeout, screenAsleep: false, locked: true), .timedOut)
    }

    /// Simulated wake sequence: screen asleep for 2 s, then locked until 7 s; polled every 500 ms.
    func testPollingSequence() {
        let g = WakeGate(startedAt: 0)
        var t = 0.0
        var result: WakeGate.Decision = .wait
        while result == .wait {
            result = g.decide(now: t, screenAsleep: t < 2, locked: t < 7)
            if result == .wait { t += WakeGate.pollInterval }
        }
        XCTAssertEqual(result, .proceed)
        XCTAssertEqual(t, 7)
    }
}
