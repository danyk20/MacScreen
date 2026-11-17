import CoreGraphics
import CoreVideo
import Foundation
import MSCodec
import MSCore
import MSProtocol

/// Virtual display plus `ScreenCapturer` (PLAN.md sections 6.2 and 6.3). Needs Screen Recording permission.
@available(macOS 12.3, *)
public final class DisplayCaptureSource: CursorAwareSource, RecoverableCaptureSource {
    public enum SourceError: Error { case virtualDisplay(String) }

    private struct Box<T>: @unchecked Sendable { let value: T }

    private let peer: PeerInfo
    public var showsCursor: Bool
    private let idLock = NSLock()
    private var displayIDValue: CGDirectDisplayID?
    public var capturedDisplayID: CGDirectDisplayID? { idLock.lock(); defer { idLock.unlock() }; return displayIDValue }
    private func setDisplayID(_ id: CGDirectDisplayID?) { idLock.lock(); displayIDValue = id; idLock.unlock() }
    private var virtualDisplay: VirtualDisplay?
    private var vdConfig: VirtualDisplayConfig?
    private var stopped = false   // guarded by idLock
    private var capturer: ScreenCapturer? {
        get { idLock.lock(); defer { idLock.unlock() }; return capturerValue }
        set { idLock.lock(); capturerValue = newValue; idLock.unlock() }
    }
    private var capturerValue: ScreenCapturer?
    /// SCK frame status counters (stats logging); nil before the capture started. Any thread.
    public var captureCounters: ScreenCapturer.Counters? { capturer?.counters }
    public var isCaptureRunning: Bool { capturer?.isRunning ?? false }
    public var captureProgressCount: UInt64? {
        captureCounters.map { $0.framesDelivered &+ $0.framesIdle }
    }

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
        vdConfig = cfg
        let vd = try await Self.createDisplay(cfg)
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

    private static func createDisplay(_ cfg: VirtualDisplayConfig) async throws -> VirtualDisplay {
        let boxedCfg = Box(value: cfg)
        let vdBox: Box<VirtualDisplay> = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                do { cont.resume(returning: Box(value: try VirtualDisplay.create(boxedCfg.value))) } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        return vdBox.value
    }

    private static func destroyDisplay(_ vd: VirtualDisplay) async {
        let vdBox = Box(value: vd)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { vdBox.value.destroy(); cont.resume() }
        }
    }

    private var isStopped: Bool { idLock.lock(); defer { idLock.unlock() }; return stopped }

    public func restartCapture() async throws {
        guard let c = capturer, !isStopped else { return }
        try await c.restart()
    }

    public func recreateDisplay() async throws {
        guard let c = capturer, let cfg = vdConfig, !isStopped else { return }
        await c.stop()
        if let old = virtualDisplay {
            virtualDisplay = nil
            await Self.destroyDisplay(old)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)   // let WindowServer drop the old display
        let vd = try await Self.createDisplay(cfg)
        if isStopped { await Self.destroyDisplay(vd); return }   // session ended meanwhile: no leak
        virtualDisplay = vd
        setDisplayID(vd.displayID)
        var cc = c.config
        cc.displayID = vd.displayID
        try await c.restart(cc)
        if isStopped { await c.stop() }
    }

    public func stop() async {
        idLock.withLock { stopped = true }
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
