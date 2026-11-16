import Foundation
import MSCore
import MSProtocol

/// Host-side adaptive bitrate and FEC (PLAN.md section 6.6, "Rate control"). Pure: no timers, no I/O;
/// time is injected through `nowMicros`. Feed it every feedback packet; it evaluates once per second
/// from the counter deltas since the previous evaluation.
public struct RateController {
    public struct Output: Equatable {
        public var bitrate: Int
        public var fecRatio: Double
        /// True exactly once, after the bitrate has sat at the floor for 5 s.
        public var switchTo30fps: Bool
    }

    public static let evaluationIntervalMicros: UInt64 = 1_000_000
    public static let startShare = 0.6
    public static let rampUpFactor = 1.05
    public static let backoffFactor = 0.8
    public static let jitterGoodMs = 5.0
    public static let jitterBadMs = 10.0
    public static let fecRaiseLoss = 0.02
    public static let fecLowerLoss = 0.002
    public static let fecLowerAfterMicros: UInt64 = 10_000_000
    public static let floorToFps30Micros: UInt64 = 5_000_000

    public let profileBitrate: Int
    /// The link default: FEC never drops below this.
    public let minFecRatio: Double
    /// 0.6 x measured throughput once a link probe exists (T4.1); nil means no extra cap.
    public var throughputCapBps: Int?

    public private(set) var bitrate: Int
    public private(set) var fecRatio: Double
    public private(set) var fpsReduced = false

    private var lastEval: UInt64?
    private var prev: FeedbackPacket?
    private var lowLossSince: UInt64?
    private var floorSince: UInt64?

    public init(profileBitrate: Int, linkFecRatio: Double) {
        self.profileBitrate = max(MSConstants.minBitrate, profileBitrate)
        self.minFecRatio = min(max(linkFecRatio, 0), MSConstants.fecRatioMax)
        self.bitrate = max(MSConstants.minBitrate, Int(Double(self.profileBitrate) * Self.startShare))
        self.fecRatio = self.minFecRatio
    }

    public var initialBitrate: Int { max(MSConstants.minBitrate, Int(Double(profileBitrate) * Self.startShare)) }

    /// Returns the new settings when an evaluation ran and something changed, else nil.
    public mutating func ingest(_ fb: FeedbackPacket, nowMicros now: UInt64) -> Output? {
        guard let last = lastEval, let p = prev else {
            lastEval = now
            prev = fb
            lowLossSince = now
            return nil
        }
        guard now &- last >= Self.evaluationIntervalMicros else { return nil }
        lastEval = now
        prev = fb

        let received = Double(fb.fragsReceived &- p.fragsReceived)
        let lost = Double(fb.fragsLost &- p.fragsLost)
        let total = received + lost
        let loss = total > 0 ? lost / total : 0
        let framesLost = (fb.framesDropped &- p.framesDropped) > 0
        let jitter = fb.jitterMs

        let before = Output(bitrate: bitrate, fecRatio: fecRatio, switchTo30fps: false)

        // Bitrate.
        if framesLost || jitter > Self.jitterBadMs {
            bitrate = max(MSConstants.minBitrate, Int(Double(bitrate) * Self.backoffFactor))
        } else if jitter < Self.jitterGoodMs {
            var cap = profileBitrate
            if let t = throughputCapBps { cap = min(cap, max(MSConstants.minBitrate, t)) }
            if bitrate < cap { bitrate = min(cap, Int(Double(bitrate) * Self.rampUpFactor)) }
        }

        // FEC.
        if loss > Self.fecRaiseLoss {
            fecRatio = min(MSConstants.fecRatioMax, fecRatio + MSConstants.fecRatioStep)
            lowLossSince = now
        } else if loss < Self.fecLowerLoss {
            let since = lowLossSince ?? now
            lowLossSince = since
            if now &- since >= Self.fecLowerAfterMicros {
                fecRatio = max(minFecRatio, fecRatio - MSConstants.fecRatioStep)
                lowLossSince = now
            }
        } else {
            lowLossSince = now
        }
        fecRatio = (fecRatio * 1000).rounded() / 1000

        // 30 fps fallback.
        var switchFps = false
        if bitrate <= MSConstants.minBitrate {
            let since = floorSince ?? now
            floorSince = since
            if !fpsReduced, now &- since >= Self.floorToFps30Micros {
                fpsReduced = true
                switchFps = true
            }
        } else {
            floorSince = nil
        }

        let out = Output(bitrate: bitrate, fecRatio: fecRatio, switchTo30fps: switchFps)
        return (out.bitrate != before.bitrate || out.fecRatio != before.fecRatio || switchFps) ? out : nil
    }
}
