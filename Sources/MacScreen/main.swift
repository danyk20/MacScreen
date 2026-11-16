import AppKit

let launchOptions = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()), defaults: .standard)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = AppDelegate(options: launchOptions)
app.delegate = appDelegate
app.run()
