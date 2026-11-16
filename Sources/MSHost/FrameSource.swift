import CoreGraphics
import CoreVideo
import Foundation
import MSCodec
import MSProtocol

/// Identity of the Display a session talks to.
public struct PeerInfo: Equatable {
    public var deviceId: String
    public var deviceName: String
    public init(deviceId: String, deviceName: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

/// Produces NV12 frames for a `HostSession`. `onFrame` may be called from any thread.
public protocol FrameSource: AnyObject {
    func start(format: VideoFormat, hiDPI: Bool, display: CapabilitiesMessage,
               onFrame: @escaping (CVPixelBuffer, _ captureTimeMicros: UInt64) -> Void) async throws
    func stop() async
}

/// A source that can hide the system cursor in the capture and tell where the captured display lives,
/// so `HostSession` can run overlay cursor mode (PLAN.md section 6.8).
public protocol CursorAwareSource: FrameSource {
    /// Set before `start`. False in "overlay" mode.
    var showsCursor: Bool { get set }
    /// The captured (virtual) display, once it exists. Any thread.
    var capturedDisplayID: CGDirectDisplayID? { get }
}
