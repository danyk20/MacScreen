import Foundation

/// RFC 3550 (section 6.4.1) interarrival jitter, one sample per video frame: S = the frame's capture time
/// on the Host clock, R = arrival of its first fragment on the Display clock. The clock offset cancels in
/// the difference, so no synchronisation is needed. Not thread-safe.
public struct InterarrivalJitter {
    private var last: (sent: UInt64, arrived: UInt64)?
    private var lastKey: UInt32?
    /// Smoothed jitter in microseconds (J in RFC 3550).
    public private(set) var jitterMicros: Double = 0

    public init() {}

    public var jitterMs: Double { jitterMicros / 1000 }

    /// `key` (frame id) must increase; retransmitted or reordered samples are ignored.
    public mutating func add(key: UInt32, sentMicros: UInt64, arrivedMicros: UInt64) {
        if let k = lastKey, Int32(bitPattern: key &- k) <= 0 { return }
        lastKey = key
        defer { last = (sentMicros, arrivedMicros) }
        guard let p = last else { return }
        let dr = Double(Int64(bitPattern: arrivedMicros &- p.arrived))
        let ds = Double(Int64(bitPattern: sentMicros &- p.sent))
        // A gap of seconds (static screen, reconnect) is not jitter: restart the pair without a sample.
        guard abs(ds) < 1_000_000 else { return }
        jitterMicros += (abs(dr - ds) - jitterMicros) / 16
    }
}
