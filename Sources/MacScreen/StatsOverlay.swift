import AppKit

/// Small always-on-top text panel, refreshed once a second (`--stats`).
final class StatsOverlay {
    enum Corner { case topLeft, bottomLeft }

    private let corner: Corner
    /// Rectangle (screen coordinates) the overlay sits inside; nil means the main screen.
    private let anchor: (() -> NSRect)?
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private let text: () -> String

    init(corner: Corner = .topLeft, anchor: (() -> NSRect)? = nil, text: @escaping () -> String) {
        self.text = text
        self.corner = corner
        self.anchor = anchor
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

    private func reposition() {
        let area = anchor?() ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let size = panel.frame.size
        let x = area.minX + 20
        let y = corner == .topLeft ? area.maxY - size.height - 20 : area.minY + 20
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() {
        reposition()
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

    private func refresh() {
        reposition()
        label.stringValue = text()
    }
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
