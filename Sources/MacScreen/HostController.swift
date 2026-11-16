import AppKit
import MSCore
import MSHost
import MSProtocol
import MSTransport

/// Host role: discovers Displays, connects, drives pairing UI. Main thread only except where noted.
final class HostController: NSObject {
    private let store: IdentityStore
    private let caps: CapabilitiesMessage
    private let browser = DisplayBrowser(queue: DispatchQueue(label: "ms.browse"))
    private var displays: [DiscoveredDisplay] = []
    private var session: HostSession?
    private var connectedTo: DiscoveredDisplay?
    private var statusText = "Idle"
    private var bytesMeter = RateMeter()
    private var framesMeter = RateMeter()
    private var overlay: StatsOverlay?
    /// Substring from `--connect`; consumed on first match so auto-connect never retries.
    private var pendingAutoConnect: String?
    var onChange: (() -> Void)?

    init(store: IdentityStore, caps: CapabilitiesMessage, stats: Bool, autoConnect: String? = nil) {
        self.store = store
        self.caps = caps
        self.pendingAutoConnect = autoConnect
        super.init()
        browser.onChange = { [weak self] list in
            DispatchQueue.main.async {
                // Do not offer ourselves (windowed loopback uses a distinct id, so this only matters for shared stores).
                self?.displays = list.filter { $0.id != store.identity.deviceId }
                self?.tryAutoConnect()
                self?.onChange?()
            }
        }
        browser.start()
        if stats {
            overlay = StatsOverlay { [weak self] in self?.statsText() ?? "" }
            overlay?.show()
        }
        if !ScreenCapturePermission.isGranted { _ = ScreenCapturePermission.request() }
    }

    func stop() {
        session?.stop()
        browser.stop()
    }

    // MARK: Menu

    func addMenuItems(to menu: NSMenu) {
        let status = NSMenuItem(title: "Status: \(statusText)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !ScreenCapturePermission.isGranted {
            let i = NSMenuItem(title: "Screen Recording permission missing\u{2026}", action: #selector(showPermission), keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let header = NSMenuItem(title: displays.isEmpty ? "No Displays found" : "Displays", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for d in displays {
            let connected = connectedTo == d && session != nil
            let item = NSMenuItem(title: connected ? "Disconnect from \(d.name)" : "Connect to \(d.name)",
                                  action: connected ? #selector(disconnect) : #selector(connect(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.id
            item.isEnabled = connected || session == nil
            menu.addItem(item)
        }
    }

    @objc private func showPermission() { Dialogs.screenRecordingGuidance() }

    @objc private func connect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let d = displays.first(where: { $0.id == id }) else { return }
        connect(to: d)
    }

    /// Auto-connects once to the first discovered Display whose name contains the `--connect` substring.
    private func tryAutoConnect() {
        guard let needle = pendingAutoConnect, session == nil else { return }
        guard let d = displays.first(where: { $0.name.localizedCaseInsensitiveContains(needle) }) else { return }
        pendingAutoConnect = nil
        connect(to: d)
    }

    private func connect(to d: DiscoveredDisplay) {
        guard #available(macOS 12.3, *) else {
            _ = Dialogs.alert("macOS 12.3 or newer required", "Screen capture needs macOS 12.3 or newer on the Host.")
            return
        }
        guard ScreenCapturePermission.isGranted else {
            Dialogs.screenRecordingGuidance()
            return
        }
        let s = HostSession(identityStore: store, capabilities: caps) { peer in
            DisplayCaptureSource(peer: peer, showsCursor: true)
        }
        s.onStateChange = { [weak self, weak s] st in
            DispatchQueue.main.async { if let s = s { self?.handle(st, from: s) } }
        }
        s.onPairingCodeRequired = { [weak self, weak s] in
            DispatchQueue.main.async { if let s = s { self?.askForCode(s, displayName: d.name) } }
        }
        session = s
        connectedTo = d
        s.connect(to: d.endpoint)
        update("Connecting to \(d.name)\u{2026}")
    }

    @objc private func disconnect() {
        session?.stop()
    }

    private func askForCode(_ s: HostSession, displayName: String) {
        update("Waiting for pairing code")
        let code = Dialogs.prompt("Pair with \(displayName)",
                                  "Enter the 6-digit code shown on \(displayName).", placeholder: "000000")
        if let code = code { s.submitPairingCode(code) } else { s.stop() }
    }

    private func handle(_ st: HostSessionState, from s: HostSession) {
        guard s === session else { return }
        let name = connectedTo?.name ?? "Display"
        switch st {
        case .idle: update("Idle")
        case .connecting: update("Connecting to \(name)\u{2026}")
        case .awaitingPairingCode: update("Waiting for pairing code")
        case .awaitingPairingApproval: update("Waiting for \(name) to allow this Mac")
        case .negotiating: update("Negotiating with \(name)")
        case .streaming: update("Streaming to \(name)")
        case .ended(let why):
            session = nil
            connectedTo = nil
            update("Disconnected")
            let msg: String?
            switch why {
            case .stopped: msg = nil
            case .peerBye(let r): msg = "\(name) ended the session (\(r))."
            case .pairingCodeMismatch: msg = "The pairing code did not match."
            case .pairingDenied: msg = "\(name) did not allow this Mac."
            case .failure(let r): msg = "Failed: \(r)"
            case .closed(let r): msg = "Connection closed: \(r)"
            }
            if let m = msg { _ = Dialogs.alert("MacScreen", m) }
        }
    }

    private func update(_ text: String) {
        statusText = text
        onChange?()
    }

    private func statsText() -> String {
        guard let s = session else { return "Host: not streaming" }
        let fps = framesMeter.rate(s.framesSent)
        let mbps = bytesMeter.rate(s.bytesSent) * 8 / 1_000_000
        return String(format: "Host  %.0f fps  %.1f Mbit/s\nframes sent %llu", fps, mbps, s.framesSent)
    }
}
