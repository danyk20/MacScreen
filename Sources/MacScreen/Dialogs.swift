import AppKit

/// Modal helpers (main thread only). The app is an accessory app, so activate before showing.
enum Dialogs {
    /// The informational alert currently on screen, if it may be closed automatically (see `dismissInformational`).
    private static var dismissible: NSWindow?

    /// `dismissOnConnect`: for read-only information (an address, a pairing code) that has no use once a Host is
    /// connected. A modal alert would otherwise sit above the full-screen picture until someone clicks it with the
    /// Display Mac's own mouse.
    static func alert(_ title: String, _ info: String, buttons: [String] = ["OK"],
                      dismissOnConnect: Bool = false) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        buttons.forEach { a.addButton(withTitle: $0) }
        if dismissOnConnect { dismissible = a.window }
        defer { if dismissOnConnect { dismissible = nil } }
        return a.runModal()
    }

    /// Closes an open informational alert (main thread). Does nothing for other dialogs, such as "Allow this Host?".
    static func dismissInformational() {
        guard let w = dismissible, NSApp.modalWindow === w else { return }
        NSApp.abortModal()
    }

    /// Returns the typed text, or nil when cancelled.
    static func prompt(_ title: String, _ info: String, placeholder: String, okTitle: String = "Pair",
                       initial: String = "", width: CGFloat = 200, fontSize: CGFloat = 20) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: okTitle)
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        field.placeholderString = placeholder
        field.stringValue = initial
        field.font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        a.accessoryView = field
        a.window.initialFirstResponder = field
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// First-launch role choice. nil when dismissed.
    static func chooseRole() -> Role? {
        let r = alert("How will this Mac be used?",
                      "Host shares its desktop to another Mac. Display is the Mac that shows it (for example an old iMac).",
                      buttons: ["Host", "Display"])
        return r == .alertFirstButtonReturn ? .host : (r == .alertSecondButtonReturn ? .display : nil)
    }

    static func screenRecordingGuidance() {
        let r = alert("Screen Recording permission needed",
                      "MacScreen captures a virtual display and needs Screen Recording access. Enable MacScreen in System Settings > Privacy & Security > Screen Recording, then quit and reopen the app.\n\nAlready switched on? After an update macOS can keep showing the old entry as enabled. Turn MacScreen off and on again, or remove it with the minus button and add it again.",
                      buttons: ["Open System Settings", "Cancel"])
        if r == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
