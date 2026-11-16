import CoreVideo
import Foundation
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
        DispatchQueue.main.async { [window] in
            window.setBlank(state.displayAsleep)
            window.showMessage(state.displayAsleep ? "Waiting for Host" : nil)
        }
    }

    public func present(_ pixelBuffer: CVPixelBuffer, captureTimeMicros: UInt64) {
        renderer.submit(pixelBuffer, captureTimeMicros: captureTimeMicros)
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
        DispatchQueue.main.async { [window] in
            window.setBlank(false)
            window.showMessage(nil)
            window.show()
        }
    }

    public func sessionEnded() {
        audio.stop()
        DispatchQueue.main.async { [window, cursor] in
            cursor.reset()
            window.setBlank(false)
            window.hide()
        }
    }
}
