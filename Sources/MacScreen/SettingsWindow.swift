import AppKit
import SwiftUI
import MSCore
import MSProtocol

/// Observable wrapper around `AppSettings`; saves on every change. Main thread only.
final class SettingsModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            settings.save()
            onChange?(settings)
        }
    }
    var onChange: ((AppSettings) -> Void)?
    /// True while the Host has a session (connecting or streaming). Set by the app from the Host controller.
    @Published var hostLive = false
    /// Set by the app to the Host controller's reconnect action; nil when not in the Host role.
    var onReconnect: (() -> Void)?
    /// This device's current name, and the action that renames it (set by the app). Empty = the Mac's own name.
    @Published var deviceName = ""
    var onRename: ((String) -> Void)?

    init() { settings = AppSettings.load() }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let role: Role
    @State private var nameDraft = ""

    private func heightLabel(_ h: Int) -> String {
        h == 0 ? "Display native (5K, static work)" : (h == 2160 ? "2160p (4K)" : "\(h)p")
    }

    var body: some View {
        Form {
            if role == .host {
                if model.hostLive {
                    Section {
                        Text("Changes apply after reconnecting")
                            .font(.caption).foregroundColor(.secondary)
                        Button("Apply & Reconnect") { model.onReconnect?() }
                    }
                }
                Section(header: Text("Video").font(.headline)) {
                    Picker("Resolution", selection: $model.settings.maxHeight) {
                        ForEach(AppSettings.heightOptions, id: \.self) { Text(heightLabel($0)).tag($0) }
                    }
                    Picker("Frame rate", selection: $model.settings.fps) {
                        ForEach(AppSettings.fpsOptions, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Picker("Codec", selection: $model.settings.codec) {
                        Text("HEVC").tag("hevc")
                        Text("H.264").tag("h264")
                    }
                    Picker("Bitrate cap", selection: $model.settings.bitrateCapMbps) {
                        ForEach(AppSettings.bitrateOptions, id: \.self) { Text($0 == 0 ? "Automatic" : "\($0) Mbit/s").tag($0) }
                    }
                    Toggle("HDR", isOn: .constant(false)).disabled(true)
                    Text("HDR is not supported yet.").font(.caption).foregroundColor(.secondary)
                    Text("Applies to the next connection. Values are limited to what the Display supports.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("Cursor").font(.headline)) {
                    Picker("Cursor mode", selection: $model.settings.cursorMode) {
                        Text("Embedded in video").tag("embedded")
                        Text("Overlay (lower latency)").tag("overlay")
                    }
                }
            }
            if role == .display {
                Section(header: Text("Picture").font(.headline)) {
                    Toggle("Smooth (vsync) mode", isOn: Binding(
                        get: { model.settings.smoothVsyncMode },
                        set: { model.settings.smoothVsync = $0 }))
                    Text("Removes tearing during fast motion; adds about 25 ms of latency. Applies immediately.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Section(header: Text("This Mac").font(.headline)) {
                HStack {
                    TextField("Name", text: $nameDraft)
                        .onSubmit { model.onRename?(nameDraft) }
                    Button("Rename") { model.onRename?(nameDraft) }
                        .disabled(DeviceName.sanitize(nameDraft) == model.deviceName)
                }
                Text(role == .display
                     ? "How this Display appears in the Host's list. Leave empty to use the Mac's own name."
                     : "How this Host appears in pairing dialogs on the Display. Leave empty to use the Mac's own name.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .onAppear { nameDraft = model.deviceName }
            Section(header: Text("General").font(.headline)) {
                Toggle("Show stats overlay", isOn: $model.settings.statsOverlay)
                Toggle("Launch at login", isOn: $model.settings.launchAtLogin)
                    .onChange(of: model.settings.launchAtLogin) { on in
                        guard role == .display else { return }
                        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
                        try? LoginItem.set(on, executablePath: exe, in: LoginItem.defaultDirectory)
                    }
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Hosts the SwiftUI settings view in an AppKit window.
final class SettingsWindowController {
    private var window: NSWindow?
    let model: SettingsModel

    init(model: SettingsModel) { self.model = model }

    func show(role: Role) {
        window?.close()
        let hosting = NSHostingController(rootView: SettingsView(model: model, role: role))
        let w = NSWindow(contentViewController: hosting)
        w.title = "MacScreen Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
