import CoreVideo
import Foundation
import MSCore
import MSProtocol

/// `DisplaySink` backed by `MetalRenderer` and `DisplayWindow`. Create on the main thread; the owner must
/// have called `renderer.attach(layer:...)` with `window.metalLayer`.
public final class RendererSink: DisplaySink {
    private let renderer: MetalRenderer
    private let window: DisplayWindow
    /// Set by the app to show an "Allow?" prompt. Without it pairing is denied.
    private let cursor = CursorLayer()
    public var onAskAllow: ((String, @escaping (Bool) -> Void) -> Void)?

    public let audio: AudioPlayer
    private let signalLock = NSLock()
    private var signal = NoSignalMonitor()   // guarded by signalLock
    private var signalTimer: Timer?           // main thread
    private var badgeShown = false            // main thread

    public init(renderer: MetalRenderer, window: DisplayWindow, audioOutput: AudioOutput = EngineAudioOutput()) {
        self.renderer = renderer
        self.window = window
        audio = AudioPlayer(output: audioOutput)
        cursor.attach(to: window.overlayRootLayer)
    }

    public func audioPacket(_ packet: AudioPacket) { audio.enqueue(packet) }

    public func hostClockOffset(_ micros: Int64) { audio.setClockOffset(micros) }

    public func cursorImage(_ image: CursorImageMessage) {
        DispatchQueue.main.async { [cursor] in cursor.add(image: image) }
    }

    public func cursorPosition(_ packet: CursorPacket) {
        DispatchQueue.main.async { [cursor] in cursor.update(packet) }
    }

    public func hostState(_ state: HostStateMessage) {
        signalLock.withLock { signal.setHostAsleep(state.displayAsleep) }
        DispatchQueue.main.async { [window] in
            window.setBlank(state.displayAsleep)
            window.showMessage(state.displayAsleep ? "Waiting for Host" : nil)
        }
    }

    public func present(_ pixelBuffer: CVPixelBuffer, captureTimeMicros: UInt64) {
        signalLock.withLock { signal.frame(now: Self.now()) }
        renderer.submit(pixelBuffer, captureTimeMicros: captureTimeMicros)
    }

    private static func now() -> Double { Double(MonoClock.nowMicros()) / 1e6 }

    /// Main thread, every 0.5 s while a session is active: "No signal" badge when frames stopped (the last
    /// picture stays visible), cleared as soon as frames resume.
    private func checkSignal() {
        let show = signalLock.withLock { signal.showsNoSignal(now: Self.now()) }
        guard show != badgeShown else { return }
        badgeShown = show
        window.showStatusBadge(show ? "No signal \u{2013} waiting for Host" : nil)
    }

    public func showPairingCode(_ code: String, hostName: String) {
        DispatchQueue.main.async { [window] in
            window.show()
            window.showMessage("Pairing code for \(hostName): \(code)")
        }
    }

    public func hidePairingCode() {
        DispatchQueue.main.async { [window] in window.showMessage(nil) }
    }

    public func askAllow(hostName: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let h = self?.onAskAllow { h(hostName, completion) } else { completion(false) }
        }
    }

    public func sessionStarted(hostName: String) {
        do { try audio.start() } catch { /* no audio output; video continues */ }
        signalLock.withLock { signal.sessionStarted(now: Self.now()) }
        DispatchQueue.main.async { [weak self, window] in
            window.setBlank(false)
            window.showMessage(nil)
            window.show()
            guard let self = self else { return }
            self.signalTimer?.invalidate()
            self.signalTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkSignal()
            }
        }
    }

    public func sessionEnded() {
        audio.stop()
        signalLock.withLock { signal.sessionEnded() }
        DispatchQueue.main.async { [weak self, window, cursor] in
            self?.signalTimer?.invalidate()
            self?.signalTimer = nil
            self?.badgeShown = false
            window.showStatusBadge(nil)
            cursor.reset()
            window.setBlank(false)
            window.hide()
        }
    }
}

/// Display-side "no signal" detection: a session is active but no frame was presented for `threshold`
/// seconds (and the Host did not announce its display asleep, which has its own message). Pure.
public struct NoSignalMonitor: Equatable {
    public static let threshold: Double = 3

    public private(set) var sessionActive = false
    private var lastFrameAt: Double = 0
    private var hostAsleep = false

    public init() {}

    public mutating func sessionStarted(now: Double) {
        sessionActive = true
        lastFrameAt = now
        hostAsleep = false
    }

    public mutating func sessionEnded() { sessionActive = false }
    public mutating func frame(now: Double) { lastFrameAt = now }
    public mutating func setHostAsleep(_ asleep: Bool) { hostAsleep = asleep }

    public func showsNoSignal(now: Double) -> Bool {
        sessionActive && !hostAsleep && now - lastFrameAt > Self.threshold
    }
}
