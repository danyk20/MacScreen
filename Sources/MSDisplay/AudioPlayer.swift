import AVFoundation
import Foundation
import MSCore
import MSProtocol

/// Pulls interleaved s16 stereo frames. `render` runs on a real-time thread.
public typealias AudioRenderCallback = (_ out: UnsafeMutablePointer<Int16>, _ frames: Int) -> Void

public protocol AudioOutput: AnyObject {
    func start(render: @escaping AudioRenderCallback) throws
    func stop()
}

/// Real output through AVAudioEngine (48 kHz stereo float; conversion happens in the source node).
public final class EngineAudioOutput: AudioOutput {
    private var engine: AVAudioEngine?
    private let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 16384 * 2)
    public init() {}
    deinit { scratch.deallocate() }

    public func start(render: @escaping AudioRenderCallback) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(MSConstants.audioSampleRate),
                                channels: AVAudioChannelCount(MSConstants.audioChannels), interleaved: false)!
        let scratch = self.scratch
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl in
            let n = min(Int(frameCount), 16384)
            render(scratch, n)
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            for ch in 0..<min(bufs.count, 2) {
                guard let p = bufs[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<n { p[i] = Float(scratch[i * 2 + ch]) * (1.0 / 32768.0) }
                if Int(frameCount) > n { for i in n..<Int(frameCount) { p[i] = 0 } }
            }
            return noErr
        }
        let e = AVAudioEngine()
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: fmt)
        try e.start()
        engine = e
    }

    public func stop() {
        engine?.stop()
        engine = nil
    }
}

/// Plays Host audio packets (s16le 48 kHz stereo). The render callback only touches the ring and its
/// own state (no locks, no allocation).
public final class AudioPlayer {
    private static let bytesPerFrame = 4
    private let output: AudioOutput
    private let ring: SPSCRingBuffer
    private let renderer: Renderer
    private let clock: () -> UInt64
    private let targetFrames: Int

    private let lock = NSLock()           // producer side only
    private var tracker = AudioSequenceTracker()
    private var active = false
    private var offsetMicros: Int64?
    private var delayMs: Double?
    private var stats = Stats()

    public struct Stats: Equatable {
        public var packetsAccepted = 0
        public var packetsDropped = 0       // late / reordered / ring full
        public var silencePackets = 0       // inserted for gaps
    }

    public init(output: AudioOutput, targetMs: Int = MSConstants.audioTargetBufferMs, clock: @escaping () -> UInt64 = MonoClock.nowMicros) {
        self.output = output
        self.clock = clock
        targetFrames = MSConstants.audioSampleRate * targetMs / 1000
        ring = SPSCRingBuffer(capacity: 262144)
        renderer = Renderer(ring: ring, targetFrames: targetFrames)
    }

    public var targetBufferMs: Double { Double(targetFrames) * 1000 / Double(MSConstants.audioSampleRate) }

    public func start() throws {
        lock.lock()
        if active { lock.unlock(); return }
        tracker.reset()
        delayMs = nil
        stats = Stats()
        lock.unlock()
        ring.reset()
        renderer.reset()
        try output.start(render: { [renderer] out, frames in renderer.render(out, frames) })
        lock.lock(); active = true; lock.unlock()
    }

    public func stop() {
        lock.lock()
        let was = active
        active = false
        lock.unlock()
        guard was else { return }
        output.stop()
        ring.reset()
        renderer.reset()
    }

    /// Host clock minus Display clock (PingClock offset), micros.
    public func setClockOffset(_ micros: Int64?) {
        lock.lock(); offsetMicros = micros; lock.unlock()
    }

    public func enqueue(_ p: AudioPacket) {
        guard p.pcm.count == AudioPacket.pcmSize else { return }
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        switch tracker.classify(p.seq) {
        case .drop:
            stats.packetsDropped += 1
        case .accept(let missing):
            if missing > 0 {
                let silence = [UInt8](repeating: 0, count: AudioPacket.pcmSize)
                for _ in 0..<missing {
                    if ring.availableToWrite < silence.count { break }
                    _ = silence.withUnsafeBytes { ring.write($0) }
                    stats.silencePackets += 1
                }
            }
            if ring.availableToWrite < p.pcm.count { stats.packetsDropped += 1; return }
            _ = p.pcm.withUnsafeBytes { ring.write($0) }
            stats.packetsAccepted += 1
            if let off = offsetMicros {
                // Age on the Display clock (network + capture), plus what is buffered ahead of it.
                let now = Int64(bitPattern: clock())
                let hostAsLocal = Int64(bitPattern: p.hostTimeMicros) &- off
                let buffered = Double(ring.availableToRead / Self.bytesPerFrame + renderer.stagedFrames) * 1000.0
                    / Double(MSConstants.audioSampleRate)
                let d = Double(now &- hostAsLocal) / 1000.0 + buffered
                delayMs = delayMs.map { $0 + 0.05 * (d - $0) } ?? d
            }
        }
    }

    /// Smoothed capture-to-speaker delay estimate in ms (nil until a clock offset is known).
    public var audioDelayMs: Double? { lock.lock(); defer { lock.unlock() }; return delayMs }
    public var packetStats: Stats { lock.lock(); defer { lock.unlock() }; return stats }
    public var underruns: Int { renderer.underruns }
    public var fillMs: Double {
        Double(ring.availableToRead / Self.bytesPerFrame + renderer.stagedFrames) * 1000.0 / Double(MSConstants.audioSampleRate)
    }

    // MARK: Real-time renderer

    final class Renderer: @unchecked Sendable {
        private let ring: SPSCRingBuffer
        private let target: Int
        private let cap = 16384                       // stage capacity, frames
        private let stage: UnsafeMutablePointer<Int16>
        private var count = 0                         // frames in stage
        private var pos = 0.0                         // fractional read position in stage
        private var primed = false
        private var drift: DriftController
        private let counters = UnsafeMutablePointer<Int>.allocate(capacity: 2)  // [underruns, stagedFrames]

        init(ring: SPSCRingBuffer, targetFrames: Int) {
            self.ring = ring
            target = targetFrames
            stage = UnsafeMutablePointer<Int16>.allocate(capacity: cap * 2)
            drift = DriftController(targetFrames: targetFrames)
            counters.initialize(repeating: 0, count: 2)
        }
        deinit { stage.deallocate(); counters.deallocate() }

        var underruns: Int { counters[0] }
        var stagedFrames: Int { counters[1] }

        /// Only call while the output is stopped.
        func reset() {
            count = 0; pos = 0; primed = false
            drift.reset()
            counters[1] = 0
        }

        func render(_ out: UnsafeMutablePointer<Int16>, _ frames: Int) {
            // Refill stage from the ring.
            let room = cap - count
            if room > 0 {
                let bytes = min(ring.availableToRead / 4, room) * 4
                if bytes > 0 {
                    let got = ring.read(into: UnsafeMutableRawBufferPointer(start: stage + count * 2, count: bytes))
                    count += got / 4
                }
            }
            if !primed {
                if count - Int(pos) >= target { primed = true; drift.reset() }
                else {
                    out.update(repeating: 0, count: frames * 2)
                    counters[1] = count
                    return
                }
            }
            let fill = count - Int(pos) + ring.availableToRead / 4
            let o = drift.update(fillFrames: fill, renderedFrames: frames)
            if o.skipFrames > 0 { pos += Double(max(0, min(o.skipFrames, count - Int(pos) - 1))) }
            var i = 0
            while i < frames {
                let idx = Int(pos)
                let frac = pos - Double(idx)
                if idx + 1 >= count && !(frac == 0 && idx < count) {
                    // Underrun: silence, re-prime.
                    out.advanced(by: i * 2).update(repeating: 0, count: (frames - i) * 2)
                    counters[0] += 1
                    primed = false
                    break
                }
                let a0 = Float(stage[idx * 2]), a1 = Float(stage[idx * 2 + 1])
                if frac == 0 {
                    out[i * 2] = stage[idx * 2]; out[i * 2 + 1] = stage[idx * 2 + 1]
                } else {
                    let f = Float(frac)
                    let b0 = Float(stage[idx * 2 + 2]), b1 = Float(stage[idx * 2 + 3])
                    out[i * 2] = Int16(a0 + (b0 - a0) * f)
                    out[i * 2 + 1] = Int16(a1 + (b1 - a1) * f)
                }
                pos += o.ratio
                i += 1
            }
            // Compact.
            let used = min(Int(pos), count)
            if used > 0 {
                let rest = count - used
                if rest > 0 { memmove(stage, stage + used * 2, rest * 4) }
                count = rest
                pos -= Double(used)
            }
            counters[1] = count
        }
    }
}
