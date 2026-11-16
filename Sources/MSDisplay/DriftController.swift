import Foundation

/// Pure drift controller for the audio jitter buffer (PLAN.md section 6.9, T5.3).
/// Fed the current fill level (frames) once per render callback together with the number of frames
/// rendered (its notion of time), it returns a playback rate (gentle resampling: >1 consumes the
/// buffer faster) and, for gross overflow, a number of frames to skip.
public struct DriftController {
    public struct Output: Equatable {
        public var ratio: Double
        public var skipFrames: Int
    }

    public let targetFrames: Double
    public let deadbandFrames: Double
    public let maxDeviation: Double      // max |ratio - 1|
    public let gain: Double              // ratio change per frame of fill error
    public let hardOverflowFrames: Double
    private var smoothed: Double?
    private let smoothingFrames: Double  // EWMA time constant in frames

    public init(targetFrames: Int, sampleRate: Int = 48000) {
        self.targetFrames = Double(targetFrames)
        deadbandFrames = Double(sampleRate) * 0.002
        maxDeviation = 0.005
        gain = 0.005 / (Double(sampleRate) * 0.020)   // 20 ms error -> full correction
        hardOverflowFrames = Double(sampleRate) * 0.080
        smoothingFrames = Double(sampleRate) * 0.200
    }

    public mutating func reset() { smoothed = nil }

    public var smoothedFill: Double? { smoothed }

    public mutating func update(fillFrames: Int, renderedFrames: Int) -> Output {
        let fill = Double(fillFrames)
        let a = min(1.0, Double(max(renderedFrames, 1)) / smoothingFrames)
        let s = smoothed.map { $0 + a * (fill - $0) } ?? fill
        smoothed = s
        let err = s - targetFrames
        if err > hardOverflowFrames {
            smoothed = targetFrames
            return Output(ratio: 1, skipFrames: Int(err))
        }
        var e = 0.0
        if err > deadbandFrames { e = err - deadbandFrames }
        else if err < -deadbandFrames { e = err + deadbandFrames }
        let r = max(-maxDeviation, min(maxDeviation, e * gain))
        return Output(ratio: 1 + r, skipFrames: 0)
    }
}

/// Pure sequence handling for audio packets.
public struct AudioSequenceTracker {
    public enum Verdict: Equatable {
        case accept(missingBefore: Int)
        case drop
    }
    public static let maxFill = 20          // packets of silence inserted for a gap
    public static let resyncGap = 100
    private var expected: UInt32?

    public init() {}
    public mutating func reset() { expected = nil }

    public mutating func classify(_ seq: UInt32) -> Verdict {
        guard let e = expected else { expected = seq &+ 1; return .accept(missingBefore: 0) }
        let diff = Int(Int32(bitPattern: seq &- e))
        if diff == 0 { expected = seq &+ 1; return .accept(missingBefore: 0) }
        if diff > 0 {
            expected = seq &+ 1
            return .accept(missingBefore: diff <= Self.resyncGap ? min(diff, Self.maxFill) : 0)
        }
        if diff < -1000 { expected = seq &+ 1; return .accept(missingBefore: 0) }  // Host restarted
        return .drop
    }
}
