import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "app.macscreen", category: "app")
    private let options: LaunchOptions
    private var role: Role?
    private var statusItem: NSStatusItem?
    private var host: HostController?
    private var display: DisplayController?

    init(options: LaunchOptions) {
        self.options = options
        self.role = options.role
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "MS"
        statusItem = item
        if role == nil {
            role = Dialogs.chooseRole()
            if let r = role { UserDefaults.standard.set(r.rawValue, forKey: LaunchOptions.roleDefaultsKey) }
        }
        startRole()
        rebuildMenu()
        log.info("Launched with role \(self.role?.rawValue ?? "none", privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        host?.stop()
        display?.stop()
    }

    private func startRole() {
        host?.stop(); host = nil
        display?.stop(); display = nil
        guard let role = role else { return }
        do {
            let store = try LocalIdentity.open(role: role, windowed: options.windowed)
            let caps = LocalCapabilities.make(role: role, windowed: options.windowed, deviceName: store.identity.deviceName)
            switch role {
            case .host:
                let h = HostController(store: store, caps: caps, stats: options.stats)
                h.onChange = { [weak self] in self?.rebuildMenu() }
                host = h
            case .display:
                display = try DisplayController(store: store, caps: caps, windowed: options.windowed, stats: options.stats)
            }
        } catch {
            log.error("Start failed: \(String(describing: error), privacy: .public)")
            _ = Dialogs.alert("MacScreen could not start", String(describing: error))
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let title: String
        switch role {
        case .host?: title = "MacScreen \u{2014} Host"
        case .display?: title = "MacScreen \u{2014} Display"
        case nil: title = "MacScreen \u{2014} choose a role"
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let hostItem = NSMenuItem(title: "Use as Host", action: #selector(chooseHost), keyEquivalent: "")
        hostItem.target = self
        hostItem.state = role == .host ? .on : .off
        menu.addItem(hostItem)

        let displayItem = NSMenuItem(title: "Use as Display", action: #selector(chooseDisplay), keyEquivalent: "")
        displayItem.target = self
        displayItem.state = role == .display ? .on : .off
        menu.addItem(displayItem)

        menu.addItem(.separator())
        host?.addMenuItems(to: menu)
        display?.addMenuItems(to: menu)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacScreen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func setRole(_ newRole: Role) {
        role = newRole
        UserDefaults.standard.set(newRole.rawValue, forKey: LaunchOptions.roleDefaultsKey)
        log.info("Role set to \(newRole.rawValue, privacy: .public)")
        startRole()
        rebuildMenu()
    }

    @objc private func chooseHost() { setRole(.host) }
    @objc private func chooseDisplay() { setRole(.display) }
}
