import Foundation
import CoreVideo
import MSCore
import MSCodec

public struct BenchResult: Codable {
    public var format: VideoFormat
    public var bitrate: Int
    public var frames: Int
    public var hardware: Bool
    public var meanMs: Double
    public var p95Ms: Double
    public var maxMs: Double
    public var throughputFps: Double
    public var passed: Bool
    public var failureReason: String?
    /// Number of leading frames excluded from meanMs/p95Ms/maxMs (BenchRules.warmupFrames).
    public var warmupExcluded: Int
    /// Decoded picture size (DecodeBench only).
    public var outputWidth: Int?
    public var outputHeight: Int?

    public init(format: VideoFormat, bitrate: Int, frames: Int, hardware: Bool, meanMs: Double, p95Ms: Double,
                maxMs: Double, throughputFps: Double, passed: Bool, failureReason: String?,
                warmupExcluded: Int = 0, outputWidth: Int? = nil, outputHeight: Int? = nil) {
        self.format = format
        self.bitrate = bitrate
        self.frames = frames
        self.hardware = hardware
        self.meanMs = meanMs
        self.p95Ms = p95Ms
        self.maxMs = maxMs
        self.throughputFps = throughputFps
        self.passed = passed
        self.failureReason = failureReason
        self.warmupExcluded = warmupExcluded
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
    }
}

private final class BenchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var submit: [UInt64: UInt64] = [:]
    private var latencies: [UInt64: Double] = [:]
    private var frames: [EncodedFrame] = []

    func submitted(_ key: UInt64, at t: UInt64) {
        lock.lock(); submit[key] = t; lock.unlock()
    }

    func delivered(_ f: EncodedFrame) {
        let now = MonoClock.nowMicros()
        lock.lock()
        if let t0 = submit[f.captureTimeMicros] {
            latencies[f.captureTimeMicros] = Double(now &- t0) / 1000.0
        }
        frames.append(f)
        lock.unlock()
    }

    var deliveredCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    /// Frames and latencies, both in frame order.
    func snapshot() -> (frames: [EncodedFrame], latenciesMs: [Double]) {
        lock.lock(); defer { lock.unlock() }
        return (frames.sorted { $0.captureTimeMicros < $1.captureTimeMicros },
                latencies.sorted { $0.key < $1.key }.map { $0.value })
    }
}

public enum EncodeBench {
    public static func run(format: VideoFormat, bitrate: Int, frameCount: Int = 90) -> (BenchResult, SampleFile?) {
        func failure(_ reason: String) -> (BenchResult, SampleFile?) {
            (BenchResult(format: format, bitrate: bitrate, frames: 0, hardware: false, meanMs: 0, p95Ms: 0,
                         maxMs: 0, throughputFps: 0, passed: false, failureReason: reason), nil)
        }
        let collector = BenchCollector()
        let encoder: VideoEncoder
        let pattern: TestPattern
        do {
            encoder = try VideoEncoder(format: format, bitrate: bitrate) { collector.delivered($0) }
        } catch {
            return failure("encoder creation failed: \(error)")
        }
        do {
            pattern = try TestPattern(width: format.width, height: format.height, bitDepth: format.bitDepth)
        } catch {
            encoder.invalidate()
            return failure("test pattern failed: \(error)")
        }

        let fps = Swift.max(format.fps, 1)
        let intervalMicros = UInt64(1_000_000 / fps)
        let start = MonoClock.nowMicros()
        for i in 0..<frameCount {
            let pb: CVPixelBuffer
            do { pb = try pattern.frame(i) } catch {
                encoder.invalidate()
                return failure("frame generation failed: \(error)")
            }
            let due = start + UInt64(i) * intervalMicros
            let now = MonoClock.nowMicros()
            if due > now { Thread.sleep(forTimeInterval: Double(due - now) / 1_000_000) }
            let key = UInt64(i) * 1_000_000 / UInt64(fps)
            collector.submitted(key, at: MonoClock.nowMicros())
            encoder.encode(pb, captureTimeMicros: key)
        }
        // Wait for outstanding frames (bounded).
        let deadline = MonoClock.nowMicros() + 5_000_000
        while collector.deliveredCount < frameCount && MonoClock.nowMicros() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        let wallSeconds = Double(MonoClock.nowMicros() - start) / 1_000_000
        encoder.invalidate()

        let snap = collector.snapshot()
        let stats = BenchRules.summarize(latenciesInOrder: snap.latenciesMs)
        let interval = 1000.0 / Double(fps)
        var reason: String?
        if snap.frames.count < frameCount {
            reason = "only \(snap.frames.count) of \(frameCount) frames delivered"
        } else if stats.p95 >= BenchRules.encodeP95Share * interval {
            reason = String(format: "p95 %.2f ms exceeds %.2f ms", stats.p95, BenchRules.encodeP95Share * interval)
        }
        let result = BenchResult(
            format: format, bitrate: bitrate, frames: snap.frames.count, hardware: true,
            meanMs: stats.mean, p95Ms: stats.p95, maxMs: stats.max,
            throughputFps: wallSeconds > 0 ? Double(snap.frames.count) / wallSeconds : 0,
            passed: reason == nil, failureReason: reason, warmupExcluded: stats.warmupExcluded)
        let sample = SampleFile(header: .init(format: format, frameCount: snap.frames.count, bitrate: bitrate),
                                frames: snap.frames)
        return (result, sample)
    }
}
