import Foundation
import MSProtocol

/// Symmetric RTT and clock-offset estimator (NTP-style four-timestamp exchange).
/// Pure logic: time is injected, no queues, no timers. Use from one queue.
public final class PingClock {
    private static let window = 16
    private static let alpha = 1.0 / 8.0

    private struct Sample {
        var rttMicros: Int64
        var offsetMicros: Int64
    }

    private var nextId: UInt32 = 1
    private var pending: [(id: UInt32, t0: UInt64)] = []
    private var samples: [Sample] = []
    private var smoothedRttMs: Double?
    private var total = 0

    public init() {}

    /// Creates a ping; ids start at 1. The last 16 `t0` values are remembered.
    public func makePing(nowMicros: UInt64) -> PingPacket {
        let id = nextId
        nextId = nextId &+ 1
        if nextId == 0 { nextId = 1 }
        pending.append((id, nowMicros))
        if pending.count > PingClock.window { pending.removeFirst(pending.count - PingClock.window) }
        return PingPacket(id: id, t0: nowMicros)
    }

    /// Answers a peer's ping. `t1` = local receive time, `t2` = local send time of the pong.
    public func handlePing(_ p: PingPacket, receivedAtMicros t1: UInt64, sendingAtMicros t2: UInt64) -> PongPacket {
        PongPacket(id: p.id, t0: p.t0, t1: t1, t2: t2)
    }

    /// Consumes a pong. Unknown or duplicate ids and mismatched `t0` are ignored.
    public func handlePong(_ p: PongPacket, nowMicros t3: UInt64) {
        guard let idx = pending.firstIndex(where: { $0.id == p.id }), pending[idx].t0 == p.t0 else { return }
        pending.remove(at: idx)

        let t0 = Int64(bitPattern: p.t0), t1 = Int64(bitPattern: p.t1)
        let t2 = Int64(bitPattern: p.t2), t3s = Int64(bitPattern: t3)
        let rtt = max(0, (t3s &- t0) &- (t2 &- t1))
        let offset = ((t1 &- t0) &+ (t2 &- t3s)) / 2

        samples.append(Sample(rttMicros: rtt, offsetMicros: offset))
        if samples.count > PingClock.window { samples.removeFirst(samples.count - PingClock.window) }
        total += 1

        let ms = Double(rtt) / 1000.0
        if let s = smoothedRttMs {
            smoothedRttMs = s + PingClock.alpha * (ms - s)
        } else {
            smoothedRttMs = ms
        }
    }

    /// Smoothed RTT in ms (EWMA, alpha 1/8); nil until the first sample.
    public var rttMs: Double? { smoothedRttMs }

    /// Minimum RTT over the last 16 samples.
    public var minRttMs: Double? {
        guard let m = samples.map({ $0.rttMicros }).min() else { return nil }
        return Double(m) / 1000.0
    }

    /// Peer clock minus local clock, from the lowest-RTT sample of the last 16 (latest on ties).
    public var offsetMicros: Int64? {
        var best: Sample?
        for s in samples where best == nil || s.rttMicros <= best!.rttMicros { best = s }
        return best?.offsetMicros
    }

    /// Total accepted samples since creation or the last `reset()`.
    public var sampleCount: Int { total }

    public func reset() {
        pending.removeAll()
        samples.removeAll()
        smoothedRttMs = nil
        total = 0
    }
}
