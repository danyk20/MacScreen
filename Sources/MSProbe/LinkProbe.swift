import Foundation
import MSCore
import MSProtocol

/// UDP train helpers (PLAN section 6.10 step 3): sending plan on the Host, arrival statistics on the Display.
public enum LinkProbe {
    public static let defaultRatesBps = [10, 20, 40, 80, 160].map { $0 * 1_000_000 }
    public static let defaultTrainDurationMs = 500

    public static func packetCount(rateBps: Int, durationMs: Int) -> Int {
        Swift.max(1, rateBps / 8 * durationMs / 1000 / MSConstants.fragmentSize)
    }

    public static func startMessage(trainId: UInt32, rateBps: Int, durationMs: Int) -> LinkProbeStartMessage {
        LinkProbeStartMessage(trainId: trainId, rateBps: rateBps, durationMs: durationMs,
                              packetCount: packetCount(rateBps: rateBps, durationMs: durationMs))
    }

    /// Media-channel items of one train, to be sent paced over `durationMs`.
    public static func packets(trainId: UInt32, count: Int) -> [(PacketType, Data)] {
        (0..<count).map { (.linkProbe, LinkProbePacket(trainId: trainId, seq: UInt32($0)).encode()) }
    }

    /// Mean absolute deviation (ms) of packet spacing from the nominal spacing.
    /// `arrivals` are (seq, arrival micros) in arrival order.
    static func jitterMs(arrivals: [(seq: UInt32, at: UInt64)], spacingMicros: Double) -> Double {
        guard arrivals.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1..<arrivals.count {
            let dt = Double(Int64(bitPattern: arrivals[i].at &- arrivals[i - 1].at))
            let ds = Double(Int64(arrivals[i].seq) - Int64(arrivals[i - 1].seq))
            sum += abs(dt - spacingMicros * ds)
        }
        return sum / Double(arrivals.count - 1) / 1000
    }
}

/// Display side bookkeeping of link probe trains. Not thread-safe: use from one queue.
final class LinkProbeReceiver {
    private struct Train {
        var arrivals: [(seq: UInt32, at: UInt64)] = []
        var expected: LinkProbeStartMessage?
        var finished = false
    }
    private var trains: [UInt32: Train] = [:]

    func packet(_ p: LinkProbePacket, at: UInt64) {
        var t = trains[p.trainId] ?? Train()
        guard !t.finished else { return }
        t.arrivals.append((p.seq, at))
        trains[p.trainId] = t
    }

    func expect(_ m: LinkProbeStartMessage) {
        var t = trains[m.trainId] ?? Train()
        t.expected = m
        trains[m.trainId] = t
        // Keep memory bounded across many runs.
        if trains.count > 16 { for k in trains.keys.sorted().prefix(trains.count - 16) { trains[k] = nil } }
    }

    func isComplete(_ id: UInt32) -> Bool {
        guard let t = trains[id], let e = t.expected, !t.finished else { return false }
        return t.arrivals.count >= e.packetCount
    }

    /// Builds the result once; nil if unknown or already finished.
    func finish(_ id: UInt32) -> LinkProbeResultMessage? {
        guard var t = trains[id], let e = t.expected, !t.finished else { return nil }
        t.finished = true
        trains[id] = t
        let spacing = Double(e.durationMs) * 1000 / Double(Swift.max(e.packetCount, 1))
        return LinkProbeResultMessage(
            trainId: id, received: t.arrivals.count,
            firstArrivalMicros: t.arrivals.first?.at ?? 0, lastArrivalMicros: t.arrivals.last?.at ?? 0,
            jitterMs: LinkProbe.jitterMs(arrivals: t.arrivals, spacingMicros: spacing))
    }
}
