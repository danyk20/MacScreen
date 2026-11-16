import Foundation
import CoreVideo
import MSCore
import MSCodec

private final class DecodeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var latencies: [UInt64: Double] = [:]
    private var count = 0
    private var width = 0
    private var height = 0

    func delivered(_ pb: CVPixelBuffer, captureMicros: UInt64, decodeMs: Double) {
        lock.lock()
        latencies[captureMicros] = decodeMs
        if count == 0 {
            width = CVPixelBufferGetWidth(pb)
            height = CVPixelBufferGetHeight(pb)
        }
        count += 1
        lock.unlock()
    }

    var deliveredCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func snapshot() -> (latenciesMs: [Double], width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        return (latencies.sorted { $0.key < $1.key }.map { $0.value }, width, height)
    }
}

public enum DecodeBench {
    private static let waitMicros: UInt64 = 5_000_000
    private static let maxInFlight = 4

    /// Pass 1 (paced): frames are submitted at `format.fps`; per-frame latency is the decodeMs the decoder reports.
    /// Pass 2 (unpaced): a new decoder, at most 4 frames in flight, throughput = frames / wall seconds.
    public static func run(sample: SampleFile) -> BenchResult {
        let format = sample.header.format
        let bitrate = sample.header.bitrate
        let total = sample.frames.count
        let fps = Swift.max(format.fps, 1)
        let interval = 1000.0 / Double(fps)

        func result(frames: Int, hardware: Bool, stats: (mean: Double, p95: Double, max: Double, warmupExcluded: Int)?,
                    throughput: Double, size: (Int, Int)?, reason: String?) -> BenchResult {
            BenchResult(format: format, bitrate: bitrate, frames: frames, hardware: hardware,
                        meanMs: stats?.mean ?? 0, p95Ms: stats?.p95 ?? 0, maxMs: stats?.max ?? 0,
                        throughputFps: throughput, passed: reason == nil, failureReason: reason,
                        warmupExcluded: stats?.warmupExcluded ?? 0,
                        outputWidth: size?.0, outputHeight: size?.1)
        }

        guard total > 0 else {
            return result(frames: 0, hardware: false, stats: nil, throughput: 0, size: nil, reason: "sample has no frames")
        }

        // Pass 1: paced.
        let paced = DecodeCollector()
        let decoder1 = VideoDecoder(codec: format.codec) { pb, t, ms in
            paced.delivered(pb, captureMicros: t, decodeMs: ms)
        }
        var hardware = false
        var thrown: String?
        let start = MonoClock.nowMicros()
        let intervalMicros = UInt64(1_000_000 / fps)
        for (i, f) in sample.frames.enumerated() {
            let due = start + UInt64(i) * intervalMicros
            let now = MonoClock.nowMicros()
            if due > now { Thread.sleep(forTimeInterval: Double(due - now) / 1_000_000) }
            do {
                try decoder1.decode(f)
            } catch {
                thrown = "decode error on frame \(i): \(error)"
                break
            }
            if i == 0 { hardware = decoder1.isHardwareAccelerated }
        }
        let deadline1 = MonoClock.nowMicros() + waitMicros
        while thrown == nil && paced.deliveredCount < total && MonoClock.nowMicros() < deadline1 {
            Thread.sleep(forTimeInterval: 0.002)
        }
        decoder1.flush()
        decoder1.invalidate()

        let snap = paced.snapshot()
        let stats = BenchRules.summarize(latenciesInOrder: snap.latenciesMs)
        let size = snap.width > 0 ? (snap.width, snap.height) : nil
        let pacedCount = paced.deliveredCount
        if let thrown {
            return result(frames: pacedCount, hardware: hardware, stats: stats, throughput: 0, size: size, reason: thrown)
        }
        if pacedCount < total {
            return result(frames: pacedCount, hardware: hardware, stats: stats, throughput: 0, size: size,
                          reason: "paced pass decoded only \(pacedCount) of \(total) frames")
        }

        // Pass 2: unpaced.
        let fast = DecodeCollector()
        let decoder2 = VideoDecoder(codec: format.codec) { pb, t, ms in
            fast.delivered(pb, captureMicros: t, decodeMs: ms)
        }
        var thrown2: String?
        let start2 = MonoClock.nowMicros()
        let guardDeadline = start2 + waitMicros + UInt64(total) * 200_000
        submit: for (i, f) in sample.frames.enumerated() {
            while decoder2.pendingFrames >= maxInFlight {
                if MonoClock.nowMicros() > guardDeadline { thrown2 = "unpaced pass stalled at frame \(i)"; break submit }
                Thread.sleep(forTimeInterval: 0.0005)
            }
            do { try decoder2.decode(f) } catch {
                thrown2 = "decode error on frame \(i) (unpaced pass): \(error)"
                break
            }
        }
        let deadline2 = MonoClock.nowMicros() + waitMicros
        while thrown2 == nil && fast.deliveredCount < total && MonoClock.nowMicros() < deadline2 {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let wall = Double(MonoClock.nowMicros() - start2) / 1_000_000
        decoder2.flush()
        decoder2.invalidate()
        let fastCount = fast.deliveredCount
        let throughput = wall > 0 ? Double(fastCount) / wall : 0

        var reason: String?
        if let thrown2 {
            reason = thrown2
        } else if fastCount < total {
            reason = "unpaced pass decoded only \(fastCount) of \(total) frames"
        } else if !hardware {
            reason = "decoder is not hardware accelerated"
        } else if stats.p95 >= BenchRules.decodeP95Share * interval {
            reason = String(format: "p95 %.2f ms exceeds %.2f ms", stats.p95, BenchRules.decodeP95Share * interval)
        } else if throughput < BenchRules.decodeThroughputFactor * Double(fps) {
            reason = String(format: "throughput %.1f fps below %.1f fps", throughput,
                            BenchRules.decodeThroughputFactor * Double(fps))
        }
        return result(frames: pacedCount, hardware: hardware, stats: stats, throughput: throughput, size: size, reason: reason)
    }
}
