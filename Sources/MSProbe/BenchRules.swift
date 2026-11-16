import Foundation
import MSCore

/// Shared rules for EncodeBench and DecodeBench (PLAN §6.10).
public enum BenchRules {
    /// The first frames (by frame order) are excluded from latency statistics.
    public static let warmupFrames = 10
    /// The encoder must keep up with the frame rate (p95 below this share of the frame interval).
    /// Its latency is reported separately; 4K60 HEVC on an M2 measures ~12 ms (0.72 of the interval).
    public static let encodeP95Share = 0.85
    public static let decodeP95Share = 0.6
    public static let decodeThroughputFactor = 1.5

    /// Splits per-frame latencies (already in frame order) into the measured part and the
    /// number of warm-up frames excluded. If there are not more frames than the warm-up, none are excluded.
    static func statsInput(latenciesInOrder latencies: [Double]) -> (measured: [Double], warmupExcluded: Int) {
        guard latencies.count > warmupFrames else { return (latencies, 0) }
        return (Array(latencies.dropFirst(warmupFrames)), warmupFrames)
    }

    static func summarize(latenciesInOrder latencies: [Double])
        -> (mean: Double, p95: Double, max: Double, warmupExcluded: Int) {
        let input = statsInput(latenciesInOrder: latencies)
        var stats = RollingStats(window: Swift.max(input.measured.count, 1))
        for l in input.measured { stats.add(l) }
        return (stats.mean, stats.p95, stats.max, input.warmupExcluded)
    }
}
