import CoreGraphics
import CoreVideo
import Foundation
import MSCodec
import MSCore
import MSProtocol

/// Virtual display plus `ScreenCapturer` (PLAN.md sections 6.2 and 6.3). Needs Screen Recording permission.
@available(macOS 12.3, *)
public final class DisplayCaptureSource: CursorAwareSource {
    public enum SourceError: Error { case virtualDisplay(String) }

    private struct Box<T>: @unchecked Sendable { let value: T }

    private let peer: PeerInfo
    public var showsCursor: Bool
    private let idLock = NSLock()
    private var displayIDValue: CGDirectDisplayID?
    public var capturedDisplayID: CGDirectDisplayID? { idLock.lock(); defer { idLock.unlock() }; return displayIDValue }
    private func setDisplayID(_ id: CGDirectDisplayID?) { idLock.lock(); displayIDValue = id; idLock.unlock() }
    private var virtualDisplay: VirtualDisplay?
    private var capturer: ScreenCapturer?

    public init(peer: PeerInfo, showsCursor: Bool = true) {
        self.peer = peer
        self.showsCursor = showsCursor
    }

    public func start(format: VideoFormat, hiDPI: Bool, display: CapabilitiesMessage,
                      onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) async throws {
        let colour = ColourPlan(panelIsP3: display.wideColor)
        let serial = VirtualDisplay.serial(forDeviceId: peer.deviceId)  // stable per Display: macOS restores arrangement
        // The virtual display is always the Display's panel size with HiDPI (PLAN 6.2); ScreenCaptureKit scales the
        // capture to the encode size (`format`).
        let cfg = VirtualDisplayConfig(
            name: peer.deviceName, pixelWidth: display.panelPixelWidth, pixelHeight: display.panelPixelHeight,
            hiDPI: hiDPI && display.backingScale > 1,
            refreshRate: 60, sizeMM: CGSize(width: display.panelWidthMM, height: display.panelHeightMM),
            serial: serial, colour: colour)
        let boxedCfg = Box(value: cfg)
        let vdBox: Box<VirtualDisplay> = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                do { cont.resume(returning: Box(value: try VirtualDisplay.create(boxedCfg.value))) } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        let vd = vdBox.value
        virtualDisplay = vd
        setDisplayID(vd.displayID)
        let cap = ScreenCapturer(
            config: ScreenCapturer.Config(displayID: vd.displayID, pixelWidth: format.width,
                                          pixelHeight: format.height, fps: format.fps,
                                          showsCursor: showsCursor, tenBit: format.bitDepth == 10, colour: colour),
            onFrame: onFrame)
        capturer = cap
        try await cap.start()
    }

    public func stop() async {
        if let c = capturer { await c.stop() }
        capturer = nil
        setDisplayID(nil)
        let vdBox = virtualDisplay.map { Box(value: $0) }
        virtualDisplay = nil
        if let vdBox = vdBox {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { vdBox.value.destroy(); cont.resume() }
            }
        }
    }
}
