import AppKit
import QuartzCore

private final class DisplayContentView: NSView {
    var onLayout: (() -> Void)?
    override var wantsUpdateLayer: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onLayout?()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayout?()
    }
}

private final class DisplayNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Main-thread only.
public final class DisplayWindow {
    public let metalLayer = CAMetalLayer()
    public var overlayRootLayer: CALayer { rootLayer }
    public var onResize: ((CGSize) -> Void)?
    public var isVisible: Bool { window.isVisible }
    /// Window frame in screen coordinates (the screen frame in full-screen mode).
    public var frame: NSRect { window.frame }

    public var drawablePixelSize: CGSize {
        let b = view.bounds
        let s = backingScale
        return CGSize(width: (b.width * s).rounded(), height: (b.height * s).rounded())
    }

    private let windowed: Bool
    private let window: NSWindow
    private let view = DisplayContentView()
    private let rootLayer = CALayer()
    private let messageLayer = CATextLayer()
    private var lastSize = CGSize.zero
    private var savedPresentation: NSApplication.PresentationOptions?

    private var backingScale: CGFloat {
        window.backingScaleFactor > 0 ? window.backingScaleFactor : (NSScreen.main?.backingScaleFactor ?? 1)
    }

    public init(windowed: Bool) {
        self.windowed = windowed
        if windowed {
            let w = DisplayNSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
            w.title = "MacScreen"
            w.center()
            window = w
        } else {
            let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
            let w = DisplayNSWindow(contentRect: frame, styleMask: [.borderless],
                                    backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            w.backgroundColor = .black
            w.collectionBehavior = [.fullScreenNone, .canJoinAllSpaces, .stationary]
            w.setFrame(frame, display: false)
            window = w
        }
        window.isReleasedWhenClosed = false

        view.wantsLayer = true
        rootLayer.backgroundColor = NSColor.black.cgColor
        view.layer = rootLayer
        rootLayer.addSublayer(metalLayer)
        metalLayer.contentsScale = backingScale
        metalLayer.backgroundColor = NSColor.black.cgColor

        messageLayer.alignmentMode = .center
        messageLayer.foregroundColor = NSColor.white.cgColor
        messageLayer.fontSize = 28
        messageLayer.contentsScale = backingScale
        messageLayer.isHidden = true
        rootLayer.addSublayer(messageLayer)

        window.contentView = view
        view.onLayout = { [weak self] in self?.relayout() }
        relayout()
    }

    public func show() {
        if !windowed {
            if savedPresentation == nil { savedPresentation = NSApp.presentationOptions }
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }
        window.makeKeyAndOrderFront(nil)
        relayout()
    }

    public func hide() {
        window.orderOut(nil)
        if let saved = savedPresentation {
            NSApp.presentationOptions = saved
            savedPresentation = nil
        }
    }

    /// Hides the video layer (black screen) while true; the message layer stays independent.
    public func setBlank(_ blank: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.isHidden = blank
        CATransaction.commit()
    }

    public func showMessage(_ text: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let text = text {
            messageLayer.string = text
            messageLayer.isHidden = false
        } else {
            messageLayer.isHidden = true
        }
        layoutMessage()
        CATransaction.commit()
    }

    private func layoutMessage() {
        let b = rootLayer.bounds
        let h: CGFloat = 80
        messageLayer.frame = CGRect(x: 0, y: (b.height - h) / 2, width: b.width, height: h)
    }

    private func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = backingScale
        rootLayer.frame = view.bounds
        metalLayer.contentsScale = scale
        messageLayer.contentsScale = scale
        metalLayer.frame = rootLayer.bounds
        layoutMessage()
        CATransaction.commit()
        let size = drawablePixelSize
        if size != lastSize && size.width > 0 && size.height > 0 {
            lastSize = size
            onResize?(size)
        }
    }
}
