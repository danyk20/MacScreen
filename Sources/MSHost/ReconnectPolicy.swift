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

    public mutating func reconnectStarted() {
        attemptInFlight = true
    }
}
