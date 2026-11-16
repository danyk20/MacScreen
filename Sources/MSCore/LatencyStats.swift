import Foundation
import os

/// Rolling p50 / p95 / max over a fixed window (nearest-rank percentiles). NOT thread-safe.
public struct LatencyStats {
    private var buf: [Double]
    private var next = 0
    public private(set) var count = 0

    public init(window: Int = 600) {
        buf = [Double](repeating: 0, count: Swift.max(window, 1))
    }

    public mutating func add(_ v: Double) {
        buf[next] = v
        next = (next + 1) % buf.count
        if count < buf.count { count += 1 }
    }

    /// Nearest-rank percentile, `p` in 0...1; 0 when empty.
    public func percentile(_ p: Double) -> Double {
        guard count > 0 else { return 0 }
        let sorted = buf[0..<count].sorted()
        let idx = Int((p * Double(count)).rounded(.up)) - 1
        return sorted[Swift.min(Swift.max(idx, 0), count - 1)]
    }

    public var p50: Double { percentile(0.5) }
    public var p95: Double { percentile(0.95) }
    public var max: Double { count > 0 ? (buf[0..<count].max() ?? 0) : 0 }

    public mutating func reset() {
        next = 0
        count = 0
    }
}

/// Signpost intervals per pipeline stage (category "latency"; view in Instruments, os_signpost).
public enum Signpost {
    private static let log = OSLog(subsystem: MSConstants.logSubsystem, category: "latency")

    public static func begin(_ name: StaticString, id: UInt64) {
        os_signpost(.begin, log: log, name: name, signpostID: OSSignpostID(id))
    }

    public static func end(_ name: StaticString, id: UInt64) {
        os_signpost(.end, log: log, name: name, signpostID: OSSignpostID(id))
    }

    public static func event(_ name: StaticString, id: UInt64) {
        os_signpost(.event, log: log, name: name, signpostID: OSSignpostID(id))
    }
}

/// Display-side per-frame stage times (all `MonoClock` microseconds on the Display clock, except
/// `captureMicros`, which is on the Host clock).
public struct FrameLatencyRecord {
    public var frameId: UInt32 = 0
    public var captureMicros: UInt64 = 0
    public var firstFragMicros: UInt64 = 0
    public var completeMicros: UInt64 = 0
    public var decodeStartMicros: UInt64 = 0
    public var decodeDoneMicros: UInt64 = 0
    public var presentMicros: UInt64 = 0
    /// capture -> present in ms, using the PingClock offset (Host clock minus Display clock).
    public var latencyMs: Double = 0
    public init() {}
}

/// Thread-safe collector: rolling capture->present stats plus per-frame rows for CSV export.
public final class LatencyRecorder: @unchecked Sendable {
    public static let csvHeader = "frame_id,capture_us_host,first_fragment_us,complete_us,decode_start_us,decode_done_us,present_us,"
        + "receive_reassemble_ms,decode_ms,render_ms,capture_to_present_ms"

    private let lock = NSLock()
    private var pending: [UInt64: FrameLatencyRecord] = [:]
    private var rows: [FrameLatencyRecord] = []
    private var stats: LatencyStats
    private var offset: Int64 = 0
    private let maxRows: Int

    public init(window: Int = 600, maxRows: Int = 200_000) {
        stats = LatencyStats(window: window)
        self.maxRows = maxRows
    }

    /// Host clock minus Display clock (`PingClock.offsetMicros`); 0 until known.
    public func setClockOffset(_ micros: Int64?) {
        lock.lock(); offset = micros ?? offset; lock.unlock()
    }

    public func frameComplete(frameId: UInt32, captureMicros: UInt64, firstFragMicros: UInt64, completeMicros: UInt64) {
        lock.lock(); defer { lock.unlock() }
        var r = FrameLatencyRecord()
        r.frameId = frameId; r.captureMicros = captureMicros
        r.firstFragMicros = firstFragMicros; r.completeMicros = completeMicros
        pending[captureMicros] = r
        if pending.count > 64 {
            // Frames that never reached the screen: drop the oldest.
            for k in pending.keys.sorted().prefix(pending.count - 64) { pending[k] = nil }
        }
    }

    public func decodeStarted(captureMicros: UInt64, atMicros: UInt64) {
        lock.lock(); pending[captureMicros]?.decodeStartMicros = atMicros; lock.unlock()
    }

    public func decodeDone(captureMicros: UInt64, atMicros: UInt64) {
        lock.lock(); pending[captureMicros]?.decodeDoneMicros = atMicros; lock.unlock()
    }

    public func presented(captureMicros: UInt64, atMicros: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard var r = pending.removeValue(forKey: captureMicros) else { return }
        r.presentMicros = atMicros
        let d = Int64(bitPattern: atMicros) &+ offset &- Int64(bitPattern: captureMicros)
        r.latencyMs = Double(d) / 1000.0
        stats.add(r.latencyMs)
        rows.append(r)
        if rows.count > maxRows { rows.removeFirst(rows.count - maxRows) }
    }

    public var snapshot: (p50: Double, p95: Double, max: Double, count: Int) {
        lock.lock(); defer { lock.unlock() }
        return (stats.p50, stats.p95, stats.max, stats.count)
    }

    public var rowCount: Int { lock.lock(); defer { lock.unlock() }; return rows.count }

    public func csv() -> String {
        lock.lock(); let rs = rows; lock.unlock()
        func ms(_ a: UInt64, _ b: UInt64) -> String {
            a == 0 || b == 0 ? "" : String(format: "%.3f", Double(Int64(bitPattern: b &- a)) / 1000.0)
        }
        var out = Self.csvHeader + "\n"
        for r in rs {
            out += "\(r.frameId),\(r.captureMicros),\(r.firstFragMicros),\(r.completeMicros),\(r.decodeStartMicros),"
                + "\(r.decodeDoneMicros),\(r.presentMicros),\(ms(r.firstFragMicros, r.completeMicros)),"
                + "\(ms(r.decodeStartMicros, r.decodeDoneMicros)),\(ms(r.decodeDoneMicros, r.presentMicros)),"
                + String(format: "%.3f", r.latencyMs) + "\n"
        }
        return out
    }

    public func writeCSV(to url: URL) throws {
        try csv().write(to: url, atomically: true, encoding: .utf8)
    }
}
