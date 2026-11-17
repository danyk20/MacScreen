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

/// A capture source whose stream can stall (ScreenCaptureKit) and be recovered by `HostSession`'s
/// capture watchdog. Methods are called one at a time.
public protocol RecoverableCaptureSource: FrameSource {
    /// Cumulative frames delivered by the capture system (complete + idle); nil before start. Any thread.
    var captureProgressCount: UInt64? { get }
    /// False once the capture system stopped the stream on its own (e.g. all displays asleep). Any thread.
    var isCaptureRunning: Bool { get }
    /// Stops and starts the capture stream, resolving the display again.
    func restartCapture() async throws
    /// Destroys and recreates the captured (virtual) display, then restarts the capture on it.
    func recreateDisplay() async throws
}
