import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "app.macscreen", category: "app")
    private let options: LaunchOptions
    private var role: Role?
    private var statusItem: NSStatusItem?

    init(options: LaunchOptions) {
        self.options = options
        self.role = options.role
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "MS"
        statusItem = item
        rebuildMenu()
        log.info("Launched with role \(self.role?.rawValue ?? "none", privacy: .public)")
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

        let quit = NSMenuItem(title: "Quit MacScreen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func setRole(_ newRole: Role) {
        role = newRole
        UserDefaults.standard.set(newRole.rawValue, forKey: LaunchOptions.roleDefaultsKey)
        log.info("Role set to \(newRole.rawValue, privacy: .public)")
        rebuildMenu()
    }

    @objc private func chooseHost() { setRole(.host) }
    @objc private func chooseDisplay() { setRole(.display) }
}
