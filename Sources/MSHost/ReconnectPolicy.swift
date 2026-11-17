import Foundation

/// Host auto-reconnect state machine (PLAN.md section 7, Lifecycle). Pure: time is passed in.
public struct ReconnectPolicy: Equatable {
    public static let baseDelay: Double = 1
    public static let maxDelay: Double = 30

    public private(set) var enabled = false
    public private(set) var targetId: String?
    public private(set) var failures = 0
    public private(set) var nextAllowedAt: Double = 0
    private var attemptInFlight = false

    public init() {}

    /// User chose Connect: arm auto-reconnect for this Display.
    public mutating func userConnect(id: String) {
        enabled = true
        targetId = id
        failures = 0
        nextAllowedAt = 0
        attemptInFlight = true
    }

    /// User chose Disconnect (or cancelled pairing): no more automatic reconnects until Connect.
    public mutating func userDisconnect() {
        enabled = false
        attemptInFlight = false
    }

    /// User chose Reconnect: the new attempt starts at once, without backoff, and auto-reconnect stays armed.
    /// Call instead of `sessionEnded` for the stopped session.
    public mutating func userReconnect(id: String) {
        enabled = true
        targetId = id
        failures = 0
        nextAllowedAt = 0
        attemptInFlight = true
    }

    public mutating func sessionStreaming() {
        failures = 0
    }

    public mutating func sessionEnded(_ reason: HostSessionEnd, now: Double) {
        attemptInFlight = false
        switch reason {
        case .stopped, .pairingCodeMismatch, .pairingDenied:
            enabled = false
        case .peerBye, .failure, .closed:
            failures += 1
            nextAllowedAt = now + Self.delay(afterFailures: failures)
        }
    }

    public static func delay(afterFailures n: Int) -> Double {
        min(maxDelay, baseDelay * pow(2, Double(max(0, n - 1))))
    }

    /// True when the Display is currently seen and a reconnect is due.
    public func shouldReconnect(seenIds: [String], now: Double) -> Bool {
        guard enabled, !attemptInFlight, let id = targetId, seenIds.contains(id) else { return false }
        return now >= nextAllowedAt
    }

    /// Seconds to wait before a due reconnect may start (0 when due now); nil when not armed.
    public func waitTime(now: Double) -> Double? {
        guard enabled, !attemptInFlight, targetId != nil else { return nil }
        return max(0, nextAllowedAt - now)
    }

    /// Display id to resume after sleep, if auto-reconnect is armed. Read before stopping the session.
    public var sleepResumeTarget: String? { enabled ? targetId : nil }

    /// Seconds after wake before the first reconnect; lets the network and Bonjour settle.
    public static let wakeSettleDelay: Double = 3

    /// Re-arm after wake: the Display must be seen again and the settle delay must pass. No tight loop.
    public mutating func resumeAfterWake(id: String, now: Double) {
        enabled = true
        targetId = id
        failures = 0
        attemptInFlight = false
        nextAllowedAt = now + Self.wakeSettleDelay
    }

    public mutating func reconnectStarted() {
        attemptInFlight = true
    }
}
