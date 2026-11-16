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
    private let cursorMode: String
    private var policy = ReconnectPolicy()
    private var reconnectGeneration = 0
    private var sleepObservers: [NSObjectProtocol] = []
    private let mirror = MirrorController()
    private var asleep = false
    var onChange: (() -> Void)?

    init(store: IdentityStore, caps: CapabilitiesMessage, stats: Bool, autoConnect: String? = nil,
         cursorMode: String = "embedded") {
        self.cursorMode = cursorMode
        self.store = store
        self.caps = caps
        self.pendingAutoConnect = autoConnect
        super.init()
        browser.onChange = { [weak self] list in
            DispatchQueue.main.async {
                // Do not offer ourselves (windowed loopback uses a distinct id, so this only matters for shared stores).
                self?.displays = list.filter { $0.id != store.identity.deviceId }
                self?.tryAutoConnect()
                self?.evaluateReconnect()
                self?.onChange?()
            }
        }
        browser.start()
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.session?.sendHostState(displayAsleep: true, mirroring: self.mirror.isMirroring)
            },
            nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.session?.sendHostState(displayAsleep: false, mirroring: self.mirror.isMirroring)
            },
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hostWillSleep()
            },
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hostDidWake()
            },
        ]
        if stats {
            overlay = StatsOverlay { [weak self] in self?.statsText() ?? "" }
            overlay?.show()
        }
        if !ScreenCapturePermission.isGranted { _ = ScreenCapturePermission.request() }
    }

    func setStatsOverlay(_ on: Bool) {
        if on {
            if overlay == nil { overlay = StatsOverlay { [weak self] in self?.statsText() ?? "" } }
            overlay?.show()
        } else {
            overlay?.hide()
        }
    }

    // MARK: Sleep / wake

    private var resumeTargetAfterWake: String?

    /// `bye` + teardown (ControlChannel.close sends bye; the source destroys the virtual display).
    private func hostWillSleep() {
        asleep = true
        resumeTargetAfterWake = policy.sleepResumeTarget
        reconnectGeneration += 1  // cancel pending re-checks
        guard let s = session else { return }
        mirror.detach()
        s.stop()
        update("Sleeping")
    }

    /// Re-arm the policy; the Display must be seen again (browser restarted) and the settle delay must pass.
    private func hostDidWake() {
        asleep = false
        guard let id = resumeTargetAfterWake else { return }
        resumeTargetAfterWake = nil
        displays = []
        browser.stop()
        browser.start()
        policy.resumeAfterWake(id: id, now: now())
        update("Reconnecting\u{2026}")
        evaluateReconnect()
    }

    // MARK: Mirror

    @objc private func toggleMirror() {
        mirror.setMirror(!mirror.wantsMirror)
        session?.sendHostState(displayAsleep: false, mirroring: mirror.isMirroring)
        onChange?()
    }

    func stop() {
        mirror.detach()
        sleepObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        sleepObservers = []
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
        menu.addItem(.separator())
        let m = NSMenuItem(title: "Mirror Main Display", action: #selector(toggleMirror), keyEquivalent: "")
        m.target = self
        m.state = mirror.wantsMirror ? .on : .off
        menu.addItem(m)
    }

    @objc private func showPermission() { Dialogs.screenRecordingGuidance() }

    @objc private func connect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let d = displays.first(where: { $0.id == id }) else { return }
        policy.userConnect(id: d.id)
        connect(to: d)
    }

    /// Auto-connects once to the first discovered Display whose name contains the `--connect` substring.
    private func tryAutoConnect() {
        guard let needle = pendingAutoConnect, session == nil else { return }
        guard let d = displays.first(where: { $0.name.localizedCaseInsensitiveContains(needle) }) else { return }
        pendingAutoConnect = nil
        policy.userConnect(id: d.id)
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
        var cfg = HostSessionConfig(settings: AppSettings.load())
        if cursorMode == "overlay" { cfg.cursorMode = "overlay" }  // `--cursor overlay` wins over the stored setting
        let s = HostSession(identityStore: store, capabilities: caps, config: cfg) { peer in
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
        policy.userDisconnect()
        reconnectGeneration += 1
        mirror.detach()
        session?.stop()
    }

    private func now() -> Double { Double(MonoClock.nowMicros()) / 1_000_000 }

    /// Reconnects when the Display is seen again and the backoff has elapsed; otherwise schedules a re-check.
    private func evaluateReconnect() {
        guard session == nil, let wait = policy.waitTime(now: now()) else { return }
        guard let id = policy.targetId, displays.contains(where: { $0.id == id }) else { return }
        if policy.shouldReconnect(seenIds: displays.map { $0.id }, now: now()),
           let d = displays.first(where: { $0.id == id }) {
            policy.reconnectStarted()
            connect(to: d)
        } else {
            reconnectGeneration += 1
            let gen = reconnectGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05) { [weak self] in
                guard let self = self, gen == self.reconnectGeneration else { return }
                self.evaluateReconnect()
            }
        }
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
        case .streaming:
            policy.sessionStreaming()
            if let id = s.capturedDisplayID { mirror.attach(displayID: id) }
            s.sendHostState(displayAsleep: false, mirroring: mirror.isMirroring)
            update("Streaming to \(name)")
        case .ended(let why):
            mirror.detach()
            session = nil
            connectedTo = nil
            policy.sessionEnded(why, now: now())
            let willRetry = policy.enabled
            update(willRetry ? "Reconnecting\u{2026}" : "Disconnected")
            if willRetry { evaluateReconnect() }
            let msg: String?
            switch why {
            case .stopped: msg = nil
            case .peerBye(let r): msg = "\(name) ended the session (\(r))."
            case .pairingCodeMismatch: msg = "The pairing code did not match."
            case .pairingDenied: msg = "\(name) did not allow this Mac."
            case .failure(let r): msg = "Failed: \(r)"
            case .closed(let r): msg = "Connection closed: \(r)"
            }
            if let m = msg, !willRetry, !asleep { _ = Dialogs.alert("MacScreen", m) }
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
