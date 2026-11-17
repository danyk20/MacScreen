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
    public static let nackMaxRttMs = 8.0
    public static let reassemblyMaxFrames = 8
    public static let keyframeMinIntervalMs = 250
    public static let feedbackIntervalMs = 100
    public static let frameStallTimeoutMs = 30
    public static let nackWaitExtraMs = 2.0
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
    public static let linkBudgetShare = 0.6
    public static let vendorID: UInt32 = 0x4D53
    public static let productID: UInt32 = 0x0001
    public static let logSubsystem = "app.macscreen"
}
