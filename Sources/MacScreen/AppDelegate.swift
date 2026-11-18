import AppKit
import MSHost
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "app.macscreen", category: "app")
    private let options: LaunchOptions
    private var role: Role?
    private var statusItem: NSStatusItem?
    private var host: HostController?
    private var display: DisplayController?
    /// Role-independent guard for the default output: a previous run may have quit while our device was default.
    private let outputGuard = AudioOutputSwitcher(control: SystemAudioDevices())
    private var signalSources: [DispatchSourceSignal] = []
    private let settingsModel = SettingsModel()
    private lazy var settingsWindow = SettingsWindowController(model: settingsModel)

    init(options: LaunchOptions) {
        self.options = options
        self.role = options.role
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        outputGuard.restoreIfStranded()
        installTerminationSignalHandlers()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.main.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            item.button?.image = img
        } else {
            item.button?.title = "MS"
        }
        statusItem = item
        if role == nil {
            role = Dialogs.chooseRole()
            if let r = role { UserDefaults.standard.set(r.rawValue, forKey: LaunchOptions.roleDefaultsKey) }
        }
        settingsModel.onChange = { [weak self] s in
            self?.host?.setStatsOverlay(s.statsOverlay)
            self?.display?.setStatsOverlay(s.statsOverlay)
            self?.display?.setSmoothVsync(s.smoothVsyncMode)
        }
        startRole()
        if role != nil { NSApp.activate(ignoringOtherApps: true) }
        rebuildMenu()
        log.info("Launched with role \(self.role?.rawValue ?? "none", privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreAudioOutputOnQuit()
        host?.stop()
        display?.stop()
    }

    /// SIGTERM/SIGINT/SIGHUP: restore the output synchronously, then exit. SIGKILL and crashes cannot be caught;
    /// the launch-time restoreIfStranded covers those.
    private func installTerminationSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.restoreAudioOutputOnQuit()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    private func restoreAudioOutputOnQuit() {
        host?.restoreAudioOnQuit()
        outputGuard.restoreIfStranded()
    }

    private func startRole() {
        host?.stop(); host = nil
        display?.stop(); display = nil
        settingsModel.onReconnect = nil
        settingsModel.hostLive = false
        guard let role = role else { return }
        do {
            let store = try LocalIdentity.open(role: role, windowed: options.windowed)
            let caps = LocalCapabilities.make(role: role, windowed: options.windowed, deviceName: store.identity.deviceName)
            switch role {
            case .host:
                let h = HostController(store: store, caps: caps, stats: options.stats || settingsModel.settings.statsOverlay, autoConnect: options.connect,
                                   cursorMode: options.cursorMode)
                h.onChange = { [weak self, weak h] in
                    guard let self = self else { return }
                    self.settingsModel.hostLive = h?.isSessionActive ?? false
                    self.rebuildMenu()
                }
                settingsModel.onReconnect = { [weak h] in h?.reconnect() }
                h.onRecommendation = { [weak self] o in
                    guard let self = self else { return }
                    self.settingsModel.settings = o.recommendation.apply(to: self.settingsModel.settings,
                                                                          panelHeight: o.panelHeight)
                }
                host = h
            case .display:
                display = try DisplayController(store: store, caps: caps, windowed: options.windowed,
                                           stats: options.stats || settingsModel.settings.statsOverlay,
                                           latencyCSV: options.latencyCSV,
                                           smoothVsync: settingsModel.settings.smoothVsyncMode)
            }
        } catch {
            log.error("Start failed: \(String(describing: error), privacy: .public)")
            _ = Dialogs.alert("MacScreen could not start", String(describing: error))
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if role == nil {
            // First launch: the only thing to do is pick a role.
            let header = NSMenuItem(title: "Choose how to use this Mac", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(roleItem("Use as Host (shares its screen)", .host))
            menu.addItem(roleItem("Use as Display (shows another Mac)", .display))
        } else {
            host?.addMenuItems(to: menu)
            display?.addMenuItems(to: menu)
        }
        menu.addItem(.separator())

        if role != nil {
            let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
            settings.keyEquivalentModifierMask = .command
            settings.target = self
            menu.addItem(settings)

            // Rarely used items live in submenus so the top level stays short.
            let testing = host?.testingItems() ?? []
            if !testing.isEmpty { menu.addItem(submenu("Testing", testing)) }

            var debug = display?.debugItems() ?? []
            let console = NSMenuItem(title: "Open Logs in Console", action: #selector(openConsole), keyEquivalent: "")
            console.target = self
            debug.append(console)
            menu.addItem(submenu("Debugging", debug))

            menu.addItem(submenu("Mode", [roleItem("Host", .host), roleItem("Display", .display)]))
            menu.addItem(.separator())
        }

        let about = NSMenuItem(title: "About MacScreen", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit MacScreen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func roleItem(_ title: String, _ r: Role) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: r == .host ? #selector(chooseHost) : #selector(chooseDisplay), keyEquivalent: "")
        item.target = self
        item.state = role == r ? .on : .off
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        items.forEach { sub.addItem($0) }
        parent.submenu = sub
        return parent
    }

    @objc private func openConsole() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
    }

    private func setRole(_ newRole: Role) {
        role = newRole
        UserDefaults.standard.set(newRole.rawValue, forKey: LaunchOptions.roleDefaultsKey)
        log.info("Role set to \(newRole.rawValue, privacy: .public)")
        startRole()
        rebuildMenu()
    }

    @objc private func openSettings() {
        guard let role = role else { return }
        settingsWindow.show(role: role)
    }

    @objc private func chooseHost() { setRole(.host) }
    @objc private func chooseDisplay() { setRole(.display) }
}
