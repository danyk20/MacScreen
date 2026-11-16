import CoreVideo
import Foundation

/// `DisplaySink` backed by `MetalRenderer` and `DisplayWindow`. Create on the main thread; the owner must
/// have called `renderer.attach(layer:...)` with `window.metalLayer`.
public final class RendererSink: DisplaySink {
    private let renderer: MetalRenderer
    private let window: DisplayWindow
    /// Set by the app to show an "Allow?" prompt. Without it pairing is denied.
    public var onAskAllow: ((String, @escaping (Bool) -> Void) -> Void)?

    public init(renderer: MetalRenderer, window: DisplayWindow) {
        self.renderer = renderer
        self.window = window
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
        DispatchQueue.main.async { [window] in
            window.showMessage(nil)
            window.show()
        }
    }

    public func sessionEnded() {
        DispatchQueue.main.async { [window] in window.hide() }
    }
}
