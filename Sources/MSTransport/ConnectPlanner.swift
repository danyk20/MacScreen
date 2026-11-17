import Foundation
import Network
import MSCore

private final class DoneFlag: @unchecked Sendable { var done = false; var last = "setup" }
private let connectLog = Log.logger("transport")

/// One step of the interface preference order (PLAN.md section 7, Lifecycle).
public struct ConnectAttempt: Equatable, @unchecked Sendable {
    public let interface: NWInterface.InterfaceType?   // nil = unconstrained
    public let timeout: TimeInterval
    public init(interface: NWInterface.InterfaceType?, timeout: TimeInterval) {
        self.interface = interface
        self.timeout = timeout
    }
}

/// Ordered connect attempts: wired Ethernet / Thunderbolt Bridge, then Wi-Fi (500 ms each),
/// then unconstrained. The connect function is injected so the order is unit-testable.
public struct ConnectPlanner {
    public static let constrainedTimeout: TimeInterval = 0.5
    public static let unconstrainedTimeout: TimeInterval = 10

    public let attempts: [ConnectAttempt]

    public init(attempts: [ConnectAttempt] = ConnectPlanner.defaultAttempts) {
        self.attempts = attempts
    }

    public static let defaultAttempts: [ConnectAttempt] = [
        ConnectAttempt(interface: .wiredEthernet, timeout: constrainedTimeout),
        ConnectAttempt(interface: .wifi, timeout: constrainedTimeout),
        ConnectAttempt(interface: nil, timeout: unconstrainedTimeout),
    ]

    /// Runs the attempts in order and returns the first result the connect function produces.
    /// `connect` must return nil on failure or timeout (and clean up after itself).
    public func run<C>(shouldContinue: () -> Bool = { true },
                       connect: (ConnectAttempt) async -> C?) async -> (attempt: ConnectAttempt, result: C)? {
        for a in attempts {
            guard shouldContinue() else { return nil }
            if let r = await connect(a) { return (a, r) }
        }
        return nil
    }

    /// Real connect function: starts an `NWConnection` constrained to the attempt's interface and
    /// returns it once `.ready`, or nil after the timeout / failure.
    public static func connectNW(to endpoint: NWEndpoint, queue: DispatchQueue,
                                 attempt: ConnectAttempt) async -> NWConnection? {
        let params = ControlChannel.tcpParameters()
        if let t = attempt.interface { params.requiredInterfaceType = t }
        let conn = NWConnection(to: endpoint, using: params)
        return await withCheckedContinuation { (cont: CheckedContinuation<NWConnection?, Never>) in
            let lock = NSLock()
            let flag = DoneFlag()
            @Sendable func finish(_ ok: Bool) {
                lock.lock()
                if flag.done { lock.unlock(); return }
                flag.done = true
                let last = flag.last
                lock.unlock()
                // Which attempt failed and how (timeout vs. waiting/failed with an error) -- the session
                // only reports "could not connect", so this is the one place the cause is visible.
                let iface = attempt.interface.map { "\($0)" } ?? "any"
                if ok {
                    connectLog.info("connect \(String(describing: endpoint), privacy: .public) via \(iface, privacy: .public): ready")
                } else {
                    connectLog.notice("connect \(String(describing: endpoint), privacy: .public) via \(iface, privacy: .public) (\(attempt.timeout, privacy: .public) s) failed; last state \(last, privacy: .public)")
                }
                if ok { conn.stateUpdateHandler = nil } else { conn.stateUpdateHandler = nil; conn.cancel() }
                cont.resume(returning: ok ? conn : nil)
            }
            conn.stateUpdateHandler = { state in
                lock.lock(); flag.last = "\(state)"; lock.unlock()
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + attempt.timeout) { finish(false) }
        }
    }
}
