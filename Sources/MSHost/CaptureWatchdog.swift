import CoreGraphics
import Foundation

/// Detects a ScreenCaptureKit stream that delivers nothing while a session streams, and escalates the
/// recovery: restart the capture, then recreate the virtual display, then end the session so the
/// reconnect policy starts a fresh one. Pure: time, frame count and screen state are passed in.
///
/// Background: when the main display sleeps or the session locks, SCK stops the stream ("Failed to find
/// any displays or windows to capture") and `SCShareableContent` lists no displays; nothing restarted it,
/// so the session stayed up with zero frames and the Display showed a frozen picture.
public struct CaptureWatchdog: Equatable {
    public enum Action: Equatable { case none, restartCapture, recreateDisplay, endSession }

    /// Stream stopped by SCK (`didStopWithError`): restart this long after the last frame.
    public static let restartAfter: Double = 2
    /// Stream nominally running but silent: SCK stops even idle frames ~8-10 s after the last change on a
    /// static screen (measured), so silence alone only triggers a (cheap) restart after this long.
    public static let silentRestartAfter: Double = 10
    /// A fresh stream delivers a complete frame within ~0.2 s; without any after a restart, recreate the
    /// virtual display this long after the restart, and end the session this long after the recreate.
    public static let recreateAfterRestart: Double = 4
    public static let endAfterRecreate: Double = 9
    /// Stall-to-end time for a stopped stream (2 + 4 + 9 s).
    public static var endAfter: Double { restartAfter + recreateAfterRestart + endAfterRecreate }

    private var lastCount: UInt64?
    private var stallSince: Double = 0
    private var stageAt: Double = 0
    private var stage = 0                 // 0 none, 1 restarted, 2 recreated, 3 ended
    private var waitingForScreen = false
    private var running = true

    public init() {}

    /// True while the screen is unavailable (asleep or locked); escalation is paused.
    public var isWaitingForScreen: Bool { waitingForScreen }

    /// Capture is not suspected: the stream runs and no recovery is under way. A silent stream on a static
    /// screen counts as healthy.
    public var isHealthy: Bool { lastCount != nil && running && stage == 0 && !waitingForScreen }

    /// `frameCount`: cumulative SCK frames (complete + idle). `streamRunning`: false once SCK stopped the
    /// stream. `screenAvailable`: main display awake and the session unlocked; capture cannot work
    /// otherwise, so the watchdog only waits and restarts when the screen is back.
    public mutating func tick(now: Double, frameCount: UInt64, streamRunning: Bool,
                              screenAvailable: Bool) -> Action {
        running = streamRunning
        guard let last = lastCount else {
            lastCount = frameCount
            stallSince = now
            return .none
        }
        if frameCount != last {
            lastCount = frameCount
            stallSince = now
            stage = 0
            waitingForScreen = false
            return .none
        }
        if !screenAvailable {
            waitingForScreen = true
            stallSince = now
            stage = 0
            return .none
        }
        if waitingForScreen {
            // The screen is back and frames are still missing: the stream most likely died meanwhile.
            waitingForScreen = false
            stage = 1
            stageAt = now
            return .restartCapture
        }
        switch stage {
        case 0:
            let after = streamRunning ? Self.silentRestartAfter : Self.restartAfter
            if now - stallSince >= after { stage = 1; stageAt = now; return .restartCapture }
        case 1:
            if now - stageAt >= Self.recreateAfterRestart { stage = 2; stageAt = now; return .recreateDisplay }
        case 2:
            if now - stageAt >= Self.endAfterRecreate { stage = 3; return .endSession }
        default:
            break
        }
        return .none
    }
}

/// After the Host wakes, waits (bounded) until the main display is awake and the session unlocked before
/// reconnecting: capture cannot start before that. Pure.
public struct WakeGate: Equatable {
    public enum Decision: Equatable { case wait, proceed, timedOut }
    public static let pollInterval: Double = 0.5
    public static let timeout: Double = 60

    public let startedAt: Double
    public init(startedAt: Double) { self.startedAt = startedAt }

    public func decide(now: Double, screenAsleep: Bool, locked: Bool) -> Decision {
        if !screenAsleep && !locked { return .proceed }
        return now - startedAt >= Self.timeout ? .timedOut : .wait
    }
}

/// Live screen state of this Mac. Any thread.
public enum ScreenState {
    public static var mainDisplayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    /// Screen locked, or this user session is not on the console (fast user switching).
    public static var sessionLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = d["CGSSessionScreenIsLocked"] as? Bool, locked { return true }
        if let onConsole = d["kCGSSessionOnConsoleKey"] as? Bool, !onConsole { return true }
        return false
    }

    public static var captureAvailable: Bool { !mainDisplayAsleep && !sessionLocked }
}
