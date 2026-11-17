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
    /// Display-measured RFC 3550 interarrival jitter of video frames. Provisional decision P1: PLAN 6.6 said
    /// 5 / 10 ms, but Wi-Fi shows several ms of jitter even when idle; queueing delay (RTT) is the
    /// congestion signal, jitter only catches heavy contention.
    public static let jitterGoodMs = 10.0
    public static let jitterBadMs = 25.0
    /// Fragments per evaluation window below which the jitter estimate is considered stale.
    public static let minFragsForJitter = 100.0
    public static let fecRaiseLoss = 0.02
    public static let fecLowerLoss = 0.002
    public static let fecLowerAfterMicros: UInt64 = 10_000_000
    public static let floorToFps30Micros: UInt64 = 5_000_000
    /// Packet loss (pre-FEC) above which one evaluation alone backs off.
    public static let heavyLoss = 0.10
    /// Queueing delay (smoothed RTT above the slowly drifting minimum) that backs off / blocks ramp-up.
    /// Measured on Wi-Fi: at ~30 Mbit/s the hotspot queued up to 2.5 s of RTT with little packet loss.
    public static let queueDelayBadMs = 80.0
    public static let queueDelayGoodMs = 30.0
    /// The RTT baseline drifts up by this much per evaluation so a route change is relearned.
    public static let baseRttDriftMs = 0.5

    /// Provisional decision P1: keyframes get this much extra FEC (capped at fecRatioMax). A lost keyframe
    /// costs a re-request plus another 450-650 KB (~0.3 s on a 15-20 Mbit/s Wi-Fi link); +0.10 parity on
    /// the keyframe alone costs ~0.03 s and lets the Display rebuild most losses without a NACK round trip.
    public static let keyframeFecExtra = 0.10

    /// Send-pacing span for one frame (Provisional decision P2, G3: size-scaled pacing kept). The frame's packets
    /// are spread at max(`pacingRateBps`, 2.5 x bitrate), over at least 4 ms: a ~450 KB keyframe at 30 Mbit/s
    /// takes ~48 ms instead of a ~1 Gbit/s burst that lost 20-40 packets on Wi-Fi; a ~70 KB P-frame stays at ~7 ms.
    public static func paceMicros(wireBytes: Int, bitrate: Int) -> UInt64 {
        let paceBps = max(Double(MSConstants.pacingRateBps), 2.5 * Double(bitrate))
        return max(4000, UInt64(Double(wireBytes) * 8 / paceBps * 1e6))
    }

    /// FEC ratio for one frame: the current ratio, raised for keyframes.
    public static func frameFecRatio(_ base: Double, isKeyframe: Bool) -> Double {
        isKeyframe ? min(MSConstants.fecRatioMax, base + keyframeFecExtra) : base
    }

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
    private var prevFramesLost = false
    private var baseRttMs: Double?

    /// `throughputCapBps`: 0.6 x measured throughput (P1). When given, the start bitrate is
    /// min(profile, cap) (PLAN 6.10 step 4) and the cap is the ceiling for ramp-up.
    public init(profileBitrate: Int, linkFecRatio: Double, throughputCapBps: Int? = nil) {
        self.profileBitrate = max(MSConstants.minBitrate, profileBitrate)
        self.minFecRatio = min(max(linkFecRatio, 0), MSConstants.fecRatioMax)
        self.throughputCapBps = throughputCapBps.map { max(MSConstants.minBitrate, $0) }
        if let cap = self.throughputCapBps {
            self.initialBitrate = min(self.profileBitrate, cap)
        } else {
            self.initialBitrate = max(MSConstants.minBitrate, Int(Double(self.profileBitrate) * Self.startShare))
        }
        self.bitrate = initialBitrate
        self.fecRatio = self.minFecRatio
    }

    public let initialBitrate: Int

    /// Returns the new settings when an evaluation ran and something changed, else nil.
    /// `rttMs`: the Host's smoothed RTT to the Display, if known (delay-based congestion signal; the
    /// feedback `jitterMs` is not measured by the Display yet).
    public mutating func ingest(_ fb: FeedbackPacket, nowMicros now: UInt64, rttMs: Double? = nil) -> Output? {
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
        // The Display's jitter is a per-frame estimate: with (almost) no media in the window (static
        // screen, heartbeat frames only, or a capture stall) it is a stale value from the last burst and
        // drove x0.8 every second to the floor (measured 23 -> 3 Mbit/s after a capture recovery).
        let jitter = received >= Self.minFragsForJitter ? fb.jitterMs : 0
        var queueDelay = 0.0
        if let r = rttMs, r >= 0 {
            let base = min(r, (baseRttMs ?? r) + Self.baseRttDriftMs)
            baseRttMs = base
            queueDelay = r - base
        }

        let before = Output(bitrate: bitrate, fecRatio: fecRatio, switchTo30fps: false)

        // Bitrate. Measured on Wi-Fi (iMac, 2026-11-17): isolated frame losses (one per second or two,
        // from burst loss, not congestion) drove x0.8 every second down to the 3 Mbit/s floor while
        // packet loss stayed ~1%. Back off only on loss in two consecutive evaluations, heavy packet
        // loss or bad jitter; a single lost frame just holds the bitrate.
        let sustained = framesLost && prevFramesLost
        prevFramesLost = framesLost
        if sustained || loss > Self.heavyLoss || jitter > Self.jitterBadMs || queueDelay > Self.queueDelayBadMs {
            bitrate = max(MSConstants.minBitrate, Int(Double(bitrate) * Self.backoffFactor))
        } else if !framesLost, jitter < Self.jitterGoodMs, queueDelay < Self.queueDelayGoodMs {
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
