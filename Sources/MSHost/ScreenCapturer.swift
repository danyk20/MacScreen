import CoreGraphics
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import MSCodec
import MSCore
import ScreenCaptureKit

/// Minimal FIFO async mutex so start/stop/update can never interleave.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        let mustWait: Bool = lock.withLock {
            if locked { return true }
            locked = true
            return false
        }
        if !mustWait { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if locked { waiters.append(c); return false }
                locked = true
                return true
            }
            if resumeNow { c.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty { locked = false; return nil }
            return waiters.removeFirst()   // ownership handed over, stays locked
        }
        next?.resume()
    }
}

@available(macOS 12.3, *)
public final class ScreenCapturer: NSObject {
    public struct Config: Equatable {
        public var displayID: CGDirectDisplayID
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var fps: Int
        public var showsCursor: Bool
        public var tenBit: Bool
        public var colour: ColourPlan

        public init(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, fps: Int,
                    showsCursor: Bool, tenBit: Bool = false, colour: ColourPlan = .srgb) {
            self.displayID = displayID
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.fps = fps
            self.showsCursor = showsCursor
            self.tenBit = tenBit
            self.colour = colour
        }
    }

    public enum CaptureError: Error {
        case permissionDenied
        case displayNotFound(CGDirectDisplayID)
        case startFailed(String)
    }

    public struct Counters {
        public var framesDelivered: UInt64 = 0
        public var framesIdle: UInt64 = 0
        public var framesOther: UInt64 = 0
    }

    public var onStopped: ((Error?) -> Void)? {
        get { lock.withLock { _onStopped } }
        set { lock.withLock { _onStopped = newValue } }
    }

    public var counters: Counters { lock.withLock { _counters } }
    public var isRunning: Bool { lock.withLock { _isRunning } }

    private let log = Log.logger("capture")
    private let captureQueue = DispatchQueue(label: "ms.capture", qos: .userInteractive)
    private let onFrame: (CVPixelBuffer, UInt64) -> Void
    private let gate = AsyncGate()
    private let lock = NSLock()

    // Protected by `lock`.
    private var _onStopped: ((Error?) -> Void)?
    private var _counters = Counters()
    private var _isRunning = false
    private var stream: SCStream?
    private var currentConfig: Config
    /// Incremented on every stream start/stop so late delegate callbacks from old streams are ignored.
    private var generation: UInt64 = 0

    public init(config: Config, onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) {
        self.currentConfig = config
        self.onFrame = onFrame
        super.init()
    }

    // MARK: Public API

    public func start() async throws {
        await gate.acquire()
        defer { gate.release() }
        try await startLocked(lock.withLock { currentConfig })
    }

    public func update(_ config: Config) async throws {
        await gate.acquire()
        defer { gate.release() }
        let (old, current): (Config, SCStream?) = lock.withLock { (currentConfig, stream) }
        lock.withLock { currentConfig = config }
        guard let current, isRunning else { return }   // not running: new config used on next start
        if old.displayID == config.displayID {
            do {
                try await current.updateConfiguration(Self.makeStreamConfiguration(config))
            } catch {
                throw CaptureError.startFailed("updateConfiguration: \(error.localizedDescription)")
            }
        } else {
            await stopLocked()
            try await startLocked(config)
        }
    }

    public func stop() async {
        await gate.acquire()
        defer { gate.release() }
        await stopLocked()
    }

    /// Stops the stream (if any) and starts a new one, resolving the display again through
    /// `SCShareableContent`. `config` replaces the current one (e.g. a recreated virtual display).
    public func restart(_ config: Config? = nil) async throws {
        await gate.acquire()
        defer { gate.release() }
        await stopLocked()
        if let config { lock.withLock { currentConfig = config } }
        try await startLocked(lock.withLock { currentConfig })
    }

    public var config: Config { lock.withLock { currentConfig } }

    // MARK: Internals (call with gate held)

    private func startLocked(_ config: Config) async throws {
        if isRunning { return }
        guard ScreenCapturePermission.isGranted else { throw CaptureError.permissionDenied }
        let display = try await findDisplay(config.displayID)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.makeStreamConfiguration(config), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            lock.withLock {
                self.stream = stream
                generation &+= 1
                _isRunning = true
            }
            try await stream.startCapture()
        } catch {
            lock.withLock {
                self.stream = nil
                generation &+= 1
                _isRunning = false
            }
            log.error("startCapture failed: \(error.localizedDescription, privacy: .public)")
            throw CaptureError.startFailed(error.localizedDescription)
        }
    }

    private func stopLocked() async {
        let s: SCStream? = lock.withLock {
            let s = stream
            stream = nil
            generation &+= 1
            _isRunning = false
            return s
        }
        guard let s else { return }
        try? await s.stopCapture()
        try? s.removeStreamOutput(self, type: .screen)
    }

    private func findDisplay(_ id: CGDirectDisplayID) async throws -> SCDisplay {
        let deadline = Date().addingTimeInterval(3.0)
        while true {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
               let d = content.displays.first(where: { $0.displayID == id }) {
                return d
            }
            if Date() >= deadline { throw CaptureError.displayNotFound(id) }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private static func makeStreamConfiguration(_ c: Config) -> SCStreamConfiguration {
        let sc = SCStreamConfiguration()
        sc.width = c.pixelWidth
        sc.height = c.pixelHeight
        sc.pixelFormat = c.tenBit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        sc.colorSpaceName = c.colour.captureColourSpaceName
        sc.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // A minimum interval of exactly 1/fps loses frames whose vsync timestamps jitter a little under
        // 16.7 ms: measured 56 fps (capture interval p50 17.4 ms) on a 60 Hz virtual display. 90 % of the
        // interval still caps at the refresh rate (or every 2nd vsync for 30 fps on 60 Hz) and gave a
        // steady 60 fps (p50 16.7 ms). Test override: `-msCapFps N` (0 = no limit).
        let d = UserDefaults.standard
        let capFps = d.object(forKey: "msCapFps") != nil ? d.integer(forKey: "msCapFps") : 0
        let fps = max(1, c.fps)
        sc.minimumFrameInterval = d.object(forKey: "msCapFps") == nil
            ? CMTime(value: 9, timescale: CMTimeScale(fps * 10))
            : (capFps <= 0 ? .zero : CMTime(value: 1, timescale: CMTimeScale(capFps)))
        sc.queueDepth = 3
        sc.showsCursor = c.showsCursor
        sc.scalesToFit = true   // same 16:9 aspect; capture size = encode size <= display pixel size
        if #available(macOS 13.0, *) { sc.capturesAudio = false }
        return sc
    }
}

@available(macOS 12.3, *)
extension ScreenCapturer: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        if SimulatedStall.shared.dropsFrame() { return }

        var status: SCFrameStatus = .complete
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let first = atts.first,
           let raw = first[.status] as? Int,
           let s = SCFrameStatus(rawValue: raw) {
            status = s
        } else {
            status = .blank   // no/unknown status: not a deliverable frame
        }

        switch status {
        case .complete:
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                lock.withLock { _counters.framesOther &+= 1 }
                return
            }
            let first: Bool = lock.withLock { _counters.framesDelivered &+= 1; return _counters.framesDelivered == 1 }
            if first {
                let atts = CVBufferCopyAttachments(pb, .shouldPropagate) as? [String: Any] ?? [:]
                let desc = "fmt=\(CVPixelBufferGetPixelFormatType(pb)) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) bpr=\(CVPixelBufferGetBytesPerRowOfPlane(pb, 0)) iosurf=\(CVPixelBufferGetIOSurface(pb) != nil) atts=\(atts.filter { !$0.key.contains("ICC") })"
                log.notice("first capture buffer: \(desc, privacy: .public)")
            }
            var age = 0.0
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.isValid {
                let a = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), pts))
                if a.isFinite { age = min(max(a, 0), 0.1) }
            }
            let now = MonoClock.nowMicros()
            let ageUs = UInt64(age * 1_000_000)
            onFrame(pb, now >= ageUs ? now - ageUs : now)
        case .idle:
            lock.withLock { _counters.framesIdle &+= 1 }
        default:
            lock.withLock { _counters.framesOther &+= 1 }
        }
    }
}

@available(macOS 12.3, *)
extension ScreenCapturer: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let handler: ((Error?) -> Void)? = lock.withLock {
            guard self.stream === stream else { return nil }   // stale or intentional stop
            self.stream = nil
            generation &+= 1
            _isRunning = false
            return _onStopped
        }
        log.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        if let handler { captureQueue.async { handler(error) } }
    }
}

/// Test hook `-msSimulateCaptureStall N`: 5 s after the first delivered frame, every SCK callback is
/// dropped for N seconds (process-wide, once), as if the stream had silently died.
final class SimulatedStall: @unchecked Sendable {
    static let shared = SimulatedStall()
    private let lock = NSLock()
    private let seconds = UserDefaults.standard.double(forKey: "msSimulateCaptureStall")
    private var window: (start: UInt64, end: UInt64)?

    func dropsFrame() -> Bool {
        guard seconds > 0 else { return false }
        let now = MonoClock.nowMicros()
        return lock.withLock {
            if window == nil {
                let start = now + 5_000_000
                window = (start, start + UInt64(seconds * 1_000_000))
                Log.logger("capture").notice("simulated capture stall armed: \(self.seconds, privacy: .public) s in 5 s")
            }
            guard let w = window else { return false }
            return now >= w.start && now < w.end
        }
    }
}
