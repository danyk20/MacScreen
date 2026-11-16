import AppKit
import MSProbe

/// Small non-modal window with a progress bar and a Cancel button for the setup test. Main thread only.
final class ProbeProgressWindow: NSObject {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "Starting\u{2026}")
    private let bar = NSProgressIndicator()
    private let onCancel: () -> Void

    init(title: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = title
        panel.isReleasedWhenClosed = false
        label.frame = NSRect(x: 20, y: 80, width: 340, height: 20)
        bar.frame = NSRect(x: 20, y: 52, width: 340, height: 16)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.frame = NSRect(x: 280, y: 12, width: 80, height: 28)
        [label, bar, cancel].forEach { panel.contentView?.addSubview($0) }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func update(_ p: ProbeProgress) {
        label.stringValue = p.message
        bar.doubleValue = p.fraction
    }

    func close() { panel.orderOut(nil) }

    @objc private func cancelTapped() { onCancel() }
}

enum ProbeSummary {
    static func mbps(_ bps: Int) -> String { String(format: "%.0f Mbit/s", Double(bps) / 1e6) }

    static func text(_ o: ProbeOutcome, applied: Bool) -> (title: String, body: String) {
        let r = o.recommendation
        var lines: [String] = []
        let title: String
        if let c = r.candidate {
            let f = c.format
            title = "Setup test finished"
            lines.append("Recommended: \(f.codec.name) \(f.width)\u{00D7}\(f.height) at \(f.fps) fps, \(mbps(r.bitrate)), FEC \(Int((r.fecRatio * 100).rounded())) %.")
            lines.append(applied ? "These values are now the defaults in Settings." : "Settings were not changed.")
        } else {
            title = "No profile passed the setup test"
            lines.append("Settings were not changed.")
        }
        lines.append("Link (\(o.interface.rawValue)): \(mbps(r.throughputBps)) usable, jitter up to \(String(format: "%.1f", o.link.maxJitterMs)) ms.")
        let rej = r.rejections.prefix(5).map { "\u{2022} \($0.candidate.format.codec.name) \($0.candidate.format.width)\u{00D7}\($0.candidate.format.height)@\($0.candidate.format.fps): \($0.reason)" }
        if !rej.isEmpty {
            lines.append("")
            lines.append("Rejected:")
            lines.append(contentsOf: rej)
            if r.rejections.count > 5 { lines.append("\u{2026} and \(r.rejections.count - 5) more") }
        }
        return (title, lines.joined(separator: "\n"))
    }
}
