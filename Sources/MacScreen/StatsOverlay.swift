import AppKit

/// Small always-on-top text panel, refreshed once a second (`--stats`).
final class StatsOverlay {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private let text: () -> String

    init(text: @escaping () -> String) {
        self.text = text
        panel = NSPanel(contentRect: NSRect(x: 20, y: 20, width: 300, height: 90),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue)
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.maximumNumberOfLines = 0
        label.frame = NSRect(x: 8, y: 6, width: 284, height: 78)
        panel.contentView?.addSubview(label)
    }

    func show() {
        refresh()
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func refresh() { label.stringValue = text() }
}

/// Turns monotonically growing counters into per-second rates.
struct RateMeter {
    private var lastValue: UInt64 = 0
    private var lastTime = Date()
    mutating func rate(_ value: UInt64) -> Double {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastTime), 0.001)
        let r = Double(value &- lastValue) / dt
        lastValue = value
        lastTime = now
        return r
    }
}
