import Foundation

/// All protocol and tuning constants (PLAN.md section 5).
public enum MSConstants {
    public static let protoVersion: UInt8 = 1
    public static let bonjourType = "_macscreen._tcp"
    public static let fragmentSize = 1200
    public static let maxDataFragsPerBlock = 64
    public static let maxParityFragsPerBlock = 32
    public static let fecRatioWiFi = 0.10
    public static let fecRatioWired = 0.0
    public static let fecRatioMax = 0.30
    public static let fecRatioStep = 0.05
    public static let packetHistoryMs = 500
    /// Was 8 ms (wired only). On Wi-Fi (RTT 15-60 ms) every burst loss became a lost frame and a
    /// ~500 KB keyframe, which caused more loss; a NACK round trip is far cheaper.
    public static let nackMaxRttMs = 100.0
    public static let reassemblyMaxFrames = 8
    public static let keyframeMinIntervalMs = 250
    /// Host: a sent keyframe counts as in flight (no new forced keyframe) for 2 x RTT + this.
    public static let keyframeInFlightMs = 400
    public static let feedbackIntervalMs = 100
    /// Was 30: Wi-Fi delivery pauses of 30+ ms declared frames lost whose fragments then arrived (hundreds
    /// of late "duplicate" fragments per 2 s with zero packet loss).
    public static let frameStallTimeoutMs = 60
    public static let nackWaitExtraMs = 20.0
    public static let pingIntervalMs = 250
    public static let controlKeepaliveS = 1.0
    public static let controlTimeoutS = 5.0
    public static let cursorPollHz = 120
    public static let cursorShapePollHz = 20
    public static let audioSampleRate = 48000
    public static let audioChannels = 2
    public static let audioFramesPerPacket = 240
    public static let audioTargetBufferMs = 25
    public static let bitsPerPixelHEVC = 0.06
    public static let bitsPerPixelH264 = 0.09
    /// Floor used by the setup test: a candidate only qualifies if its bitrate at this density fits the link.
    public static let minBitsPerPixelHEVC = 0.04
    public static let minBitsPerPixelH264 = 0.06
    public static let minBitrate = 3_000_000
    /// Video send pacing: a frame's packets are spread at no more than this rate (or 2.5x the current
    /// bitrate if higher), at least over 4 ms. Measured on the iMac Wi-Fi link (2026-11-17): keyframes of
    /// ~450 KB blasted within 4 ms (~1 Gbit/s bursts) lost 20-40 packets each and caused keyframe storms.
    public static let pacingRateBps = 60_000_000
    /// Host idle-screen recovery: force a keyframe when the Display reported no decode progress for this
    /// long. 200 ms fired on Wi-Fi feedback jitter (RTT spikes to 160 ms) and caused extra keyframes.
    public static let hostRecoveryStallMs = 400
    public static let linkBudgetShare = 0.6
    public static let vendorID: UInt32 = 0x4D53
    public static let productID: UInt32 = 0x0001
    public static let logSubsystem = "app.macscreen"
}
