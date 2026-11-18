import AppKit
import CoreVideo
import MSCodec
import MSCore
import MSHost
import MSProbe
import MSProtocol
import MSTransport
import Network

/// Placeholder for probe-only sessions, which never start a source.
private final class NoFrameSource: FrameSource {
    struct Unused: Error {}
    func start(format: VideoFormat, hiDPI: Bool, display: CapabilitiesMessage,
               onFrame: @escaping (CVPixelBuffer, UInt64) -> Void) async throws { throw Unused() }
    func stop() async {}
}

/// Host role: discovers Displays, connects, drives pairing UI. Main thread only except where noted.
final class HostController: NSObject {
    private static let log = Log.logger("host-app")
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
    /// Set by `reconnect()`: the session that ends next is followed by a new one to the same Display.
    private var reconnectRequested = false
    private var reconnectGeneration = 0
    private var sleepObservers: [NSObjectProtocol] = []
    private let mirror = MirrorController()
    private var asleep = false
    private let power = HostPowerController(assertions: IOKitSleepAssertions())
    private var probeSession: HostSession?
    private let audioSwitcher = AudioOutputSwitcher(control: SystemAudioDevices())
    private var sessionHasAudio = false
    private var probeWindow: ProbeProgressWindow?
    /// Automatic link check before streaming (Provisional decision P1). Off: `defaults write
    /// app.macscreen.MacScreen msAutoLinkProbe -bool NO` (or `-msAutoLinkProbe NO`).
    private let autoLinkProbe = UserDefaults.standard.object(forKey: "msAutoLinkProbe") == nil
        || UserDefaults.standard.bool(forKey: "msAutoLinkProbe")
    private var linkCheck: HostSession?
    private var linkCheckGeneration = 0
    private let pathMonitor = NWPathMonitor()
    private var currentInterface: LinkInterface = .other
    /// Default gateway of the current path; identifies the network for the link-check cache.
    private var currentNetworkId: String?
    /// Called on main with the outcome of a setup test that produced a recommendation.
    var onRecommendation: ((ProbeOutcome) -> Void)?
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
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let i: LinkInterface = path.usesInterfaceType(.wiredEthernet) ? .wired
                : path.usesInterfaceType(.wifi) ? .wifi : .other
            let gw = path.gateways.first.map { "\($0)" }
            DispatchQueue.main.async { self?.currentInterface = i; self?.currentNetworkId = gw }
        }
        pathMonitor.start(queue: DispatchQueue(label: "ms.path"))
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.session?.sendHostState(displayAsleep: true, mirroring: self.mirror.isMirroring)
            },
            nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.session?.sendHostState(displayAsleep: false, mirroring: self.mirror.isMirroring)
                self.pollWakeGate()
            },
            nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.pollWakeGate()
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
        // Sleeping again while the wake gate still waits keeps the pending resume target.
        resumeTargetAfterWake = policy.sleepResumeTarget ?? (wakeGate != nil ? resumeTargetAfterWake : nil)
        wakeGate = nil
        wakeGateGeneration += 1
        reconnectGeneration += 1  // cancel pending re-checks
        guard let s = session else { return }
        mirror.detach()
        s.stop()
        update("Sleeping")
    }

    private var wakeGate: WakeGate?
    private var wakeGateGeneration = 0

    /// Capture cannot start while the main display sleeps or the session is locked (SCShareableContent lists
    /// no displays), so the resume waits for both, bounded by `WakeGate.timeout`.
    private func hostDidWake() {
        asleep = false
        guard resumeTargetAfterWake != nil else { return }
        wakeGate = WakeGate(startedAt: now())
        wakeGateGeneration += 1
        update("Waiting for screen\u{2026}")
        pollWakeGate()
    }

    /// Main thread; also called on screensDidWake / sessionDidBecomeActive.
    private func pollWakeGate() {
        guard let gate = wakeGate, !asleep else { return }
        let asleepNow = ScreenState.mainDisplayAsleep, locked = ScreenState.sessionLocked
        switch gate.decide(now: now(), screenAsleep: asleepNow, locked: locked) {
        case .wait:
            wakeGateGeneration += 1
            let gen = wakeGateGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + WakeGate.pollInterval) { [weak self] in
                guard let self = self, gen == self.wakeGateGeneration else { return }
                self.pollWakeGate()
            }
        case .proceed, .timedOut:
            let waited = now() - gate.startedAt
            Self.log.notice("wake gate: \(asleepNow || locked ? "timed out" : "screen ready", privacy: .public) after \(String(format: "%.1f", waited), privacy: .public) s (asleep=\(asleepNow) locked=\(locked))")
            wakeGate = nil
            wakeGateGeneration += 1
            resumeAfterWake()
        }
    }

    /// Re-arm the policy; the Display must be seen again (browser restarted) and the settle delay must pass.
    private func resumeAfterWake() {
        guard let id = resumeTargetAfterWake, !asleep else { return }
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
        probeSession?.stop()
        linkCheck?.stop()
        pathMonitor.cancel()
        audioSwitcher.restore()
        audioSwitcher.restoreIfStranded()
        power.setStreaming(false)
        browser.stop()
    }

    /// Quit and signal path (AppDelegate): returns the default output to the user's device, whatever the sound setting.
    func restoreAudioOnQuit() {
        audioSwitcher.restore()
        audioSwitcher.restoreIfStranded()
    }

    // MARK: Menu

    /// Everyday items only: status, connect/disconnect, and the two toggles people flip often.
    /// Everything else lives in the Testing and Debugging submenus (see `testingItems`).
    func addMenuItems(to menu: NSMenu) {
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !ScreenCapturePermission.isGranted {
            let i = NSMenuItem(title: "Allow Screen Recording\u{2026}", action: #selector(showPermission), keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        menu.addItem(.separator())
        if displays.isEmpty {
            let none = NSMenuItem(title: "No Displays found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for d in displays {
            let connected = connectedTo == d && session != nil
            let item = NSMenuItem(title: connected ? "Disconnect from \(d.name)" : "Connect to \(d.name)",
                                  action: connected ? #selector(disconnect) : #selector(connect(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.id
            item.isEnabled = connected || (session == nil && probeSession == nil && linkCheck == nil)
            menu.addItem(item)
        }
        if isSessionActive {
            let reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "")
            reconnectItem.target = self
            reconnectItem.isEnabled = !reconnectRequested
            menu.addItem(reconnectItem)
        }

        menu.addItem(.separator())
        let m = NSMenuItem(title: "Mirror Main Display", action: #selector(toggleMirror), keyEquivalent: "")
        m.target = self
        m.state = mirror.wantsMirror ? .on : .off
        menu.addItem(m)
        let a = NSMenuItem(title: "Play Sound on Display", action: #selector(toggleSound), keyEquivalent: "")
        a.target = self
        a.state = AppSettings.load().playsSoundOnDisplay ? .on : .off
        menu.addItem(a)
    }

    /// Items for the Testing submenu: one setup test per discovered Display.
    func testingItems() -> [NSMenuItem] {
        let idle = session == nil && probeSession == nil
        if displays.isEmpty {
            let none = NSMenuItem(title: "Setup Test (no Display found)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            return [none]
        }
        return displays.map { d in
            let i = NSMenuItem(title: "Run Setup Test on \(d.name)", action: #selector(runSetupTest(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = d.id
            i.isEnabled = idle
            return i
        }
    }

    // MARK: Audio (T5.2)

    /// Takes effect at the next connection (the request is part of session setup).
    @objc private func toggleSound() {
        var s = AppSettings.load()
        if s.playsSoundOnDisplay {
            s.playSoundOnDisplay = false
            s.save()
            // Takes effect immediately, even mid-session: give the output back and stop capturing.
            audioSwitcher.restore()
            session?.stopAudio()
            sessionHasAudio = false
        } else {
            guard audioSwitcher.isDevicePresent else {
                _ = Dialogs.alert("Audio driver not installed",
                                  "Sound needs the MacScreen audio driver. Install it with Scripts/install-audio-driver.sh, then turn this option on again.")
                return
            }
            s.playSoundOnDisplay = true
            s.save()
        }
        onChange?()
    }

    /// Switches the default output when audio is active for this session; failures only cost the sound.
    private func startAudioOutput() {
        guard sessionHasAudio else { return }
        do { try audioSwitcher.enable() } catch {
            sessionHasAudio = false
            Log.logger("audio").error("output switch failed: \(String(describing: error), privacy: .public)")
        }
    }

    @objc private func showPermission() { Dialogs.screenRecordingGuidance() }

    @objc private func connect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let d = displays.first(where: { $0.id == id }) else { return }
        policy.userConnect(id: d.id)
        connect(to: d)
    }

    /// Auto-connects once to the first discovered Display whose name contains the `--connect` substring.
    private func tryAutoConnect() {
        guard let needle = pendingAutoConnect, session == nil, linkCheck == nil else { return }
        guard let d = displays.first(where: { $0.name.localizedCaseInsensitiveContains(needle) }) else { return }
        pendingAutoConnect = nil
        policy.userConnect(id: d.id)
        connect(to: d)
    }

    private func connect(to d: DiscoveredDisplay) {
        Self.log.notice("connecting to \(d.name, privacy: .public)")
        guard #available(macOS 12.3, *) else {
            _ = Dialogs.alert("macOS 12.3 or newer required", "Screen capture needs macOS 12.3 or newer on the Host.")
            return
        }
        guard ScreenCapturePermission.isGranted else {
            Dialogs.screenRecordingGuidance()
            return
        }
        guard session == nil, linkCheck == nil else { return }
        if !autoLinkProbe { startStream(to: d, link: nil); return }
        runLinkCheck(d)
    }

    // MARK: Automatic link check (Provisional decision P1, PLAN 6.10)

    /// Link trains only (~2-5 s, capped at 8 s after negotiation), cached per (Display, interface); then streams.
    private func runLinkCheck(_ d: DiscoveredDisplay) {
        var cfg = HostSessionConfig()
        var run = HostSessionConfig.linkCheckRun()
        let hevc = caps.hwEncodeHEVC
        run.onFinished = { [weak self] result in
            DispatchQueue.main.async { self?.linkCheckFinished(result, display: d, hevc: hevc) }
        }
        cfg.probe = run
        let s = HostSession(identityStore: store, capabilities: caps, config: cfg) { _ in NoFrameSource() }
        linkCheckGeneration += 1
        let gen = linkCheckGeneration
        var negotiated = false
        s.onStateChange = { [weak self, weak s] st in
            DispatchQueue.main.async {
                guard let self = self, let s = s, s === self.linkCheck, gen == self.linkCheckGeneration else { return }
                switch st {
                case .negotiating:
                    negotiated = true
                    self.update("Measuring link to \(d.name)\u{2026}")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak s] in
                        guard let self = self, gen == self.linkCheckGeneration, s === self.linkCheck else { return }
                        Self.log.notice("link check: timeout, using defaults")
                        s?.stop()
                    }
                case .ended(let why):
                    // Success and timeout both continue in linkCheckFinished; handle the rest here.
                    switch why {
                    case .stopped:
                        // Normally linkCheckFinished already ran (onFinished comes first). After a timeout it
                        // follows shortly; if the user cancelled pairing, nothing follows: go idle.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak s] in
                            guard let self = self, let s = s, s === self.linkCheck else { return }
                            if negotiated {
                                self.linkCheckFinished(.failure(ProbeFailure("stopped")), display: d, hevc: hevc)
                            } else {
                                self.linkCheck = nil
                                self.linkCheckGeneration += 1
                                self.update("Idle")
                            }
                        }
                    case .pairingCodeMismatch, .pairingDenied:
                        self.linkCheck = nil
                        self.linkCheckGeneration += 1
                        self.handleLinkCheckAbort(why, name: d.name)
                    default:
                        self.linkCheckFinished(.failure(ProbeFailure("\(why)")), display: d, hevc: hevc)
                    }
                default: break
                }
            }
        }
        s.onPairingCodeRequired = { [weak self, weak s] in
            DispatchQueue.main.async { if let s = s { self?.askForCode(s, displayName: d.name) } }
        }
        linkCheck = s
        s.connect(to: d.endpoint)
        update("Measuring link to \(d.name)\u{2026}")
    }

    private func linkCheckFinished(_ result: Result<ProbeOutcome, ProbeFailure>, display d: DiscoveredDisplay, hevc: Bool) {
        guard linkCheck != nil else { return }
        linkCheck = nil
        linkCheckGeneration += 1
        var measured: ProbeOutcome?
        switch result {
        case .success(let o) where o.link.usableThroughputBps > 0:
            var out = HostSessionConfig.linkOnlyOutcome(o, hevc: hevc)
            out.networkId = currentNetworkId
            ProbeCache.store(out)
            measured = out
        case .success:
            Self.log.notice("link check: no usable rate measured")
        case .failure(let f):
            Self.log.notice("link check failed (\(f.message, privacy: .public))")
        }
        let cached = ProbeCache.load(displayId: d.id, interface: currentInterface)
        let (link, fallback) = HostSessionConfig.resolveLink(measured: measured, cached: cached,
                                                             networkId: currentNetworkId)
        if let out = link {
            let f = out.recommendation.candidate?.format
            Self.log.notice("link check\(fallback ? " FALLBACK (cached x0.75)" : "", privacy: .public): \(out.link.usableThroughputBps) bit/s over \(out.interface.rawValue, privacy: .public) gw \(out.networkId ?? "?", privacy: .public) -> \(f.map { "\($0.width)x\($0.height)@\($0.fps)" } ?? "none", privacy: .public) trains=\(out.link.trains.map { "\($0.rateBps / 1_000_000):\($0.received)/\($0.sent):\(($0.deliveryBps ?? 0) / 1_000_000):\(Int($0.stretchMs ?? -1))ms" }.joined(separator: ","), privacy: .public)")
        } else {
            Self.log.notice("link check: no measurement and no cached result for this network, using G1 defaults")
        }
        // The Display needs a moment to finish the probe connection before the stream connects.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.session == nil, !self.asleep else { return }
            self.startStream(to: d, link: link)
        }
    }

    private func handleLinkCheckAbort(_ why: HostSessionEnd, name: String) {
        policy.userDisconnect()
        update("Disconnected")
        switch why {
        case .pairingCodeMismatch: _ = Dialogs.alert("MacScreen", "The pairing code did not match.")
        case .pairingDenied: _ = Dialogs.alert("MacScreen", "\(name) did not allow this Mac.")
        default: break
        }
    }

    private func startStream(to d: DiscoveredDisplay, link: ProbeOutcome?) {
        guard #available(macOS 12.3, *) else { return }
        let settings = AppSettings.load()
        var cfg = HostSessionConfig(settings: settings)
        if let o = link { cfg.applyLink(o, settings: settings) }
        sessionHasAudio = AppSettings.load().playsSoundOnDisplay && audioSwitcher.isDevicePresent
        cfg.audioEnabled = sessionHasAudio
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
        s.onCapturedDisplayChanged = { [weak self, weak s] id in
            DispatchQueue.main.async {
                guard let self = self, let s = s, s === self.session else { return }
                self.mirror.detach()
                self.mirror.attach(displayID: id)
            }
        }
        session = s
        connectedTo = d
        s.connect(to: d.endpoint)
        update("Connecting to \(d.name)\u{2026}")
    }

    @objc private func disconnect() {
        policy.userDisconnect()
        wakeGate = nil
        wakeGateGeneration += 1
        resumeTargetAfterWake = nil
        reconnectGeneration += 1
        mirror.detach()
        session?.stop()
    }

    /// True while a session object exists (connecting, negotiating or streaming).
    var isSessionActive: Bool { session != nil }

    /// Stops the current session the way Disconnect does, then connects to the same Display again with the
    /// current settings. Auto-reconnect stays armed and no backoff applies. Also used by Settings "Apply & Reconnect".
    @objc func reconnect() {
        guard let s = session, !reconnectRequested, !asleep else { return }
        Self.log.notice("reconnect requested")
        reconnectRequested = true
        reconnectGeneration += 1
        mirror.detach()
        update("Reconnecting\u{2026}")
        s.stop()
    }

    private func now() -> Double { Double(MonoClock.nowMicros()) / 1_000_000 }

    /// Reconnects when the Display is seen again and the backoff has elapsed; otherwise schedules a re-check.
    private func evaluateReconnect() {
        guard session == nil, linkCheck == nil, let wait = policy.waitTime(now: now()) else { return }
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
        Self.log.notice("session \(name, privacy: .public): \(String(describing: st), privacy: .public)")
        switch st {
        case .idle: update("Idle")
        case .connecting: update("Connecting to \(name)\u{2026}")
        case .awaitingPairingCode: update("Waiting for pairing code")
        case .awaitingPairingApproval: update("Waiting for \(name) to allow this Mac")
        case .negotiating: update("Negotiating with \(name)")
        case .streaming:
            policy.sessionStreaming()
            power.setStreaming(true)
            startAudioOutput()
            if let id = s.capturedDisplayID { mirror.attach(displayID: id) }
            s.sendHostState(displayAsleep: false, mirroring: mirror.isMirroring)
            update("Streaming to \(name)")
        case .ended(let why):
            power.setStreaming(false)
            mirror.detach()
            audioSwitcher.restore()
            sessionHasAudio = false
            let rejoin = reconnectRequested ? connectedTo : nil
            reconnectRequested = false
            session = nil
            connectedTo = nil
            if let d = rejoin, !asleep {
                // Reconnect: the old session's bye is already sent; start the new one right away.
                policy.userReconnect(id: d.id)
                connect(to: d)
                if session == nil && linkCheck == nil {
                    // Could not start (for example Screen Recording lost): fall back to the normal backoff path.
                    policy.sessionEnded(.failure("reconnect could not start"), now: now())
                    update("Reconnecting\u{2026}")
                    evaluateReconnect()
                }
                return
            }
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

    // MARK: Setup test (PLAN 6.10)

    @objc private func runSetupTest(_ sender: NSMenuItem) {
        guard session == nil, probeSession == nil,
              let id = sender.representedObject as? String, let d = displays.first(where: { $0.id == id }) else { return }
        if let cached = ProbeCache.latest(displayId: id) {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            let r = Dialogs.alert("Saved setup test for \(d.name)",
                                  "A test over \(cached.interface.rawValue) was run on \(f.string(from: cached.date)). Use it, or run the test again?",
                                  buttons: ["Run again", "Use saved result", "Cancel"])
            if r == .alertSecondButtonReturn { finishSetupTest(cached, reused: true); return }
            if r != .alertFirstButtonReturn { return }
        }
        var cfg = HostSessionConfig()
        var run = ProbeRunConfig()
        run.onProgress = { [weak self] p in DispatchQueue.main.async { self?.probeWindow?.update(p) } }
        run.onFinished = { [weak self] result in DispatchQueue.main.async { self?.setupTestEnded(result) } }
        cfg.probe = run
        let s = HostSession(identityStore: store, capabilities: caps, config: cfg) { _ in NoFrameSource() }
        s.onStateChange = { [weak self, weak s] st in
            DispatchQueue.main.async {
                guard let self = self, let s = s, s === self.probeSession else { return }
                if case .ended(let why) = st { self.probeSessionEnded(why, name: d.name) }
            }
        }
        s.onPairingCodeRequired = { [weak self, weak s] in
            DispatchQueue.main.async { if let s = s { self?.askForCode(s, displayName: d.name) } }
        }
        probeSession = s
        let w = ProbeProgressWindow(title: "Setup test: \(d.name)") { [weak self] in self?.probeSession?.stop() }
        probeWindow = w
        w.show()
        s.connect(to: d.endpoint)
        update("Setup test on \(d.name)\u{2026}")
    }

    private func setupTestEnded(_ result: Result<ProbeOutcome, ProbeFailure>) {
        probeWindow?.close()
        probeWindow = nil
        switch result {
        case .success(let o):
            ProbeCache.store(o)
            finishSetupTest(o, reused: false)
        case .failure(let f):
            if f.message != "Cancelled" { _ = Dialogs.alert("Setup test failed", f.message) }
        }
    }

    private func finishSetupTest(_ o: ProbeOutcome, reused: Bool) {
        let applied = o.recommendation.candidate != nil
        if applied { onRecommendation?(o) }
        let t = ProbeSummary.text(o, applied: applied)
        _ = Dialogs.alert(reused ? t.title + " (saved result)" : t.title, t.body)
    }

    private func probeSessionEnded(_ why: HostSessionEnd, name: String) {
        probeSession = nil
        probeWindow?.close()
        probeWindow = nil
        update(statusAfterProbe())
        switch why {
        case .stopped: break
        case .peerBye(let r): _ = Dialogs.alert("Setup test", "\(name) ended the session (\(r)).")
        case .pairingCodeMismatch: _ = Dialogs.alert("Setup test", "The pairing code did not match.")
        case .pairingDenied: _ = Dialogs.alert("Setup test", "\(name) did not allow this Mac.")
        case .failure(let r): _ = Dialogs.alert("Setup test failed", r)
        case .closed(let r): _ = Dialogs.alert("Setup test", "Connection closed: \(r)")
        }
    }

    private func statusAfterProbe() -> String { session == nil ? "Idle" : statusText }

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
