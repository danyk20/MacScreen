import AppKit
import UniformTypeIdentifiers
import MSCore
import MSCodec
import MSDisplay
import MSProtocol
import MSTransport

/// Display side sink: delegates to `RendererSink` and remembers the pairing code for "Show pairing code".
final class AppSink: DisplaySink {
    private let inner: RendererSink
    private let lock = NSLock()
    private var code: (String, String)?
    init(_ inner: RendererSink) { self.inner = inner }

    var audio: AudioPlayer { inner.audio }

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
    /// Lifecycle hooks for power management; called from internal queues.
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onHostState: ((HostStateMessage) -> Void)?
    func sessionStarted(hostName: String) { inner.sessionStarted(hostName: hostName); onConnected?() }
    func sessionEnded() { inner.sessionEnded(); onDisconnected?() }
    func hostState(_ state: HostStateMessage) { inner.hostState(state); onHostState?(state) }
    func audioPacket(_ packet: AudioPacket) { inner.audioPacket(packet) }
    func hostClockOffset(_ micros: Int64) { inner.hostClockOffset(micros) }
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

    private let power = DisplayPowerController(assertions: IOKitPowerAssertions())
    private let latencyCSVPath: String?
    private static let log = Log.logger("display-app")

    init(store: IdentityStore, caps: CapabilitiesMessage, windowed: Bool, stats: Bool,
         latencyCSV: String? = nil, smoothVsync: Bool = false) throws {
        latencyCSVPath = latencyCSV
        window = DisplayWindow(windowed: windowed)
        renderer = try MetalRenderer()
        renderer.attach(layer: window.metalLayer, drawableSize: window.drawablePixelSize,
                        colour: ColourPlan(panelIsP3: caps.wideColor), options: PresentOptions.fromDefaults(settingsVsync: smoothVsync))
        window.onResize = { [renderer] size in renderer.updateDrawableSize(size) }
        let rs = RendererSink(renderer: renderer, window: window)
        rs.onAskAllow = { [window] host, done in
            Self.log.notice("asking to allow \(host, privacy: .public)")
            // The full-screen window sits above modal panels; lower it or the alert opens hidden behind it.
            let r = window.runningDialog {
                Dialogs.alert("Allow \(host)?", "\(host) wants to use this Mac as a display.",
                              buttons: ["Allow", "Deny"])
            }
            Self.log.notice("allow \(host, privacy: .public): \(r == .alertFirstButtonReturn ? "allowed" : "denied", privacy: .public)")
            done(r == .alertFirstButtonReturn)
        }
        sink = AppSink(rs)
        let p = power
        sink.onConnected = { DispatchQueue.main.async { p.hostConnected() } }
        sink.onDisconnected = { DispatchQueue.main.async { p.hostDisconnected() } }
        sink.onHostState = { s in DispatchQueue.main.async { p.hostStateChanged(displayAsleep: s.displayAsleep) } }
        session = DisplaySession(identityStore: store, capabilities: caps, sink: sink,
                                 preferredPort: MSConstants.defaultControlPort)
        let rec = session.latency
        renderer.onPresented = { capture, at in rec.presented(captureMicros: capture, atMicros: at) }
        try session.start()
        if stats {
            overlay = StatsOverlay(corner: .bottomLeft, anchor: { [window] in window.frame }) { [weak self] in self?.statsText() ?? "" }
            overlay?.show()
        }
    }

    /// Settings "Smooth (vsync) mode"; applies immediately. The `msRenderVsync` developer override still wins.
    func setSmoothVsync(_ on: Bool) {
        let v = PresentOptions.fromDefaults(settingsVsync: on).vsync
        if v != renderer.presentOptions.vsync { renderer.setVsync(v) }
    }

    func setStatsOverlay(_ on: Bool) {
        if on {
            if overlay == nil {
                overlay = StatsOverlay(corner: .bottomLeft, anchor: { [window] in window.frame }) { [weak self] in self?.statsText() ?? "" }
            }
            overlay?.show()
        } else {
            overlay?.hide()
        }
    }

    func stop() {
        power.hostDisconnected()
        session.stop()
        if let p = latencyCSVPath { try? session.latency.writeCSV(to: URL(fileURLWithPath: p)) }
    }

    func addMenuItems(to menu: NSMenu) {
        let i = NSMenuItem(title: "Show Pairing Code", action: #selector(showCode), keyEquivalent: "")
        i.target = self
        menu.addItem(i)
        let a = NSMenuItem(title: "Show Address\u{2026}", action: #selector(showAddress), keyEquivalent: "")
        a.target = self
        menu.addItem(a)
    }

    @objc private func showAddress() {
        let port = session.port ?? MSConstants.defaultControlPort
        let entries = LocalAddresses.ipv4()
        let lines = entries.isEmpty
            ? "This Mac has no network address right now."
            : entries.map { e in
                let shown = port == MSConstants.defaultControlPort ? e.address : "\(e.address):\(port)"
                return "\(shown)  (\(e.interface == "en0" ? "Wi-Fi or Ethernet" : e.interface))"
            }.joined(separator: "\n")
        window.runningDialog {
            _ = Dialogs.alert("Address of this Display",
                              "On the Host choose Connect to Address\u{2026} and enter:\n\n\(lines)")
        }
    }

    /// Items for the Debugging submenu.
    func debugItems() -> [NSMenuItem] {
        let e = NSMenuItem(title: "Export Latency CSV\u{2026}", action: #selector(exportLatency), keyEquivalent: "")
        e.target = self
        return [e]
    }

    @objc private func exportLatency() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macscreen-latency.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        window.runningDialog {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try session.latency.writeCSV(to: url) } catch {
                _ = Dialogs.alert("Export failed", String(describing: error))
            }
        }
    }

    @objc private func showCode() {
        window.runningDialog {
            if let c = sink.currentCode {
                _ = Dialogs.alert("Pairing code for \(c.host)", c.code)
            } else {
                _ = Dialogs.alert("No pairing in progress",
                                  "A code appears here when a Host that this Mac does not know connects.")
            }
        }
    }

    private func statsText() -> String {
        let c = renderer.counters
        let fps = framesMeter.rate(c.framesDrawn)
        let l = session.latency.snapshot
        return String(format: "Display  %.0f fps\nframes received %llu  drawn %llu  skipped %llu\nlatency p50 %.1f  p95 %.1f  max %.1f ms\naudio delay %@  fill %.0f ms  underruns %d",
                      fps, c.framesSubmitted, c.framesDrawn, c.framesSkipped, l.p50, l.p95, l.max,
                      sink.audio.audioDelayMs.map { String(format: "%.0f ms", $0) } ?? "-",
                      sink.audio.fillMs, sink.audio.underruns)
    }
}
