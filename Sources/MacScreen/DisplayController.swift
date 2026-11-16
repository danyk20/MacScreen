import AppKit
import MSCore
import MSDisplay
import MSProtocol

/// Display side sink: delegates to `RendererSink` and remembers the pairing code for "Show pairing code".
final class AppSink: DisplaySink {
    private let inner: RendererSink
    private let lock = NSLock()
    private var code: (String, String)?
    init(_ inner: RendererSink) { self.inner = inner }

    var currentCode: (code: String, host: String)? { lock.lock(); defer { lock.unlock() }; return code.map { ($0.0, $0.1) } }

    func present(_ pixelBuffer: CVPixelBuffer, captureTimeMicros: UInt64) { inner.present(pixelBuffer, captureTimeMicros: captureTimeMicros) }
    func showPairingCode(_ code: String, hostName: String) {
        lock.lock(); self.code = (code, hostName); lock.unlock()
        inner.showPairingCode(code, hostName: hostName)
    }
    func hidePairingCode() {
        lock.lock(); code = nil; lock.unlock()
        inner.hidePairingCode()
    }
    func askAllow(hostName: String, completion: @escaping (Bool) -> Void) { inner.askAllow(hostName: hostName, completion: completion) }
    func sessionStarted(hostName: String) { inner.sessionStarted(hostName: hostName) }
    func sessionEnded() { inner.sessionEnded() }
    func cursorImage(_ image: CursorImageMessage) { inner.cursorImage(image) }
    func cursorPosition(_ packet: CursorPacket) { inner.cursorPosition(packet) }
}

/// Display role: owns window, renderer and `DisplaySession`. Main thread only.
final class DisplayController {
    private let window: DisplayWindow
    private let renderer: MetalRenderer
    private let sink: AppSink
    private let session: DisplaySession
    private var overlay: StatsOverlay?
    private var framesMeter = RateMeter()

    init(store: IdentityStore, caps: CapabilitiesMessage, windowed: Bool, stats: Bool) throws {
        window = DisplayWindow(windowed: windowed)
        renderer = try MetalRenderer()
        renderer.attach(layer: window.metalLayer, drawableSize: window.drawablePixelSize)
        window.onResize = { [renderer] size in renderer.updateDrawableSize(size) }
        let rs = RendererSink(renderer: renderer, window: window)
        rs.onAskAllow = { host, done in
            let r = Dialogs.alert("Allow \(host)?", "\(host) wants to use this Mac as a display.",
                                  buttons: ["Allow", "Deny"])
            done(r == .alertFirstButtonReturn)
        }
        sink = AppSink(rs)
        session = DisplaySession(identityStore: store, capabilities: caps, sink: sink)
        try session.start()
        if stats {
            overlay = StatsOverlay { [weak self] in self?.statsText() ?? "" }
            overlay?.show()
        }
    }

    func stop() { session.stop() }

    func addMenuItems(to menu: NSMenu) {
        let i = NSMenuItem(title: "Show pairing code", action: #selector(showCode), keyEquivalent: "")
        i.target = self
        menu.addItem(i)
    }

    @objc private func showCode() {
        if let c = sink.currentCode {
            _ = Dialogs.alert("Pairing code for \(c.host)", c.code)
        } else {
            _ = Dialogs.alert("No pairing in progress",
                              "A code appears here when a Host that this Mac does not know connects.")
        }
    }

    private func statsText() -> String {
        let c = renderer.counters
        let fps = framesMeter.rate(c.framesDrawn)
        return String(format: "Display  %.0f fps\nframes received %llu  drawn %llu  skipped %llu",
                      fps, c.framesSubmitted, c.framesDrawn, c.framesSkipped)
    }
}
