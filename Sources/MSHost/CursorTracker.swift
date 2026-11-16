import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import MSCore
import MSProtocol

/// One cursor bitmap as read from the system.
public struct CursorShape: Equatable {
    public var png: Data
    public var hotX: Double
    public var hotY: Double
    public var widthPt: Double
    public var heightPt: Double
    public init(png: Data, hotX: Double, hotY: Double, widthPt: Double, heightPt: Double) {
        self.png = png
        self.hotX = hotX
        self.hotY = hotY
        self.widthPt = widthPt
        self.heightPt = heightPt
    }
}

/// Where the cursor data comes from. The real one reads CoreGraphics/AppKit; tests inject a fake.
public protocol CursorSampling: AnyObject {
    /// Global cursor location (top-left origin, same space as `CGDisplayBounds`), nil if unavailable.
    func location() -> CGPoint?
    func isCursorVisible() -> Bool
    func currentShape() -> CursorShape?
    /// Bounds of the virtual display in global coordinates, nil while it does not exist.
    func displayBounds() -> CGRect?
}

/// Pure position mapping (PLAN.md section 6.8).
public enum CursorMapping {
    /// Normalises `point` into 0...1 inside `bounds`. `inside` is false when the point is outside.
    public static func normalize(_ point: CGPoint, in bounds: CGRect) -> (x: Float, y: Float, inside: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0, false) }
        let inside = point.x >= bounds.minX && point.x < bounds.maxX
            && point.y >= bounds.minY && point.y < bounds.maxY
        let nx = min(max((point.x - bounds.minX) / bounds.width, 0), 1)
        let ny = min(max((point.y - bounds.minY) / bounds.height, 0), 1)
        return (Float(nx), Float(ny), inside)
    }
}

/// Assigns `imageId`s: a new id whenever hotspot, size or bitmap hash changes; a shape seen before keeps its id.
public struct CursorImageRegistry {
    private var ids: [String: UInt16] = [:]
    private var next: UInt16 = 1

    public init() {}

    static func key(_ s: CursorShape) -> String {
        let h = SHA256.hash(data: s.png).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(s.hotX),\(s.hotY),\(s.widthPt),\(s.heightPt),\(h)"
    }

    /// Returns the id and whether it is new (the image must be sent).
    public mutating func id(for shape: CursorShape) -> (id: UInt16, isNew: Bool) {
        let k = Self.key(shape)
        if let id = ids[k] { return (id, false) }
        let id = next
        next = next == .max ? 1 : next + 1
        ids[k] = id
        return (id, true)
    }
}

/// Reads the real cursor.
public final class SystemCursorSampler: CursorSampling {
    private let displayIDProvider: () -> CGDirectDisplayID?
    public init(displayID: @escaping () -> CGDirectDisplayID?) { displayIDProvider = displayID }

    public func location() -> CGPoint? { CGEvent(source: nil)?.location }
    /// `CGCursorIsVisible` is unavailable; use the CGS equivalent when present, else assume visible.
    private static let cgsVisible: (() -> Bool)? = {
        guard let h = dlopen(nil, RTLD_NOW),
              let c = dlsym(h, "CGSMainConnectionID"), let v = dlsym(h, "CGSCursorIsVisible") else { return nil }
        typealias ConnFn = @convention(c) () -> UInt32
        typealias VisFn = @convention(c) (UInt32) -> Bool
        let conn = unsafeBitCast(c, to: ConnFn.self)
        let vis = unsafeBitCast(v, to: VisFn.self)
        return { vis(conn()) }
    }()

    public func isCursorVisible() -> Bool { Self.cgsVisible?() ?? true }

    public func displayBounds() -> CGRect? {
        guard let id = displayIDProvider() else { return nil }
        return CGDisplayBounds(id)
    }

    public func currentShape() -> CursorShape? {
        guard let c = NSCursor.currentSystem else { return nil }
        let img = c.image
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return CursorShape(png: png, hotX: Double(c.hotSpot.x), hotY: Double(c.hotSpot.y),
                           widthPt: Double(img.size.width), heightPt: Double(img.size.height))
    }
}

/// Samples the cursor at `cursorPollHz` and sends position packets (only on change, plus a repeat every
/// 250 ms) and `cursorImage` messages on shape change (PLAN.md section 6.8). All work runs on `queue`.
public final class CursorTracker {
    private let sampler: CursorSampling
    private let queue: DispatchQueue
    private let sendPosition: (CursorPacket) -> Void
    private let sendImage: (CursorImageMessage) -> Void
    private var timer: DispatchSourceTimer?

    private var registry = CursorImageRegistry()
    private var seq: UInt32 = 0
    private var imageId: UInt16 = 0
    private var last: CursorPacket?
    private var lastSentMicros: UInt64 = 0
    private var tickCount = 0
    private let shapeEvery = max(1, MSConstants.cursorPollHz / MSConstants.cursorShapePollHz)
    private let repeatMicros: UInt64 = 250_000

    public init(sampler: CursorSampling, queue: DispatchQueue,
                sendPosition: @escaping (CursorPacket) -> Void,
                sendImage: @escaping (CursorImageMessage) -> Void) {
        self.sampler = sampler
        self.queue = queue
        self.sendPosition = sendPosition
        self.sendImage = sendImage
    }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            let ns = 1_000_000_000 / max(MSConstants.cursorPollHz, 1)
            t.schedule(deadline: .now(), repeating: .nanoseconds(ns), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick(nowMicros: MonoClock.nowMicros()) }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// One sampling step; internal timer calls it, tests call it directly (on any thread, not concurrently).
    public func tick(nowMicros: UInt64) {
        if tickCount % shapeEvery == 0 { pollShape() }
        tickCount &+= 1
        guard let bounds = sampler.displayBounds(), let loc = sampler.location() else { return }
        let m = CursorMapping.normalize(loc, in: bounds)
        let visible = m.inside && sampler.isCursorVisible()
        let p = CursorPacket(seq: seq &+ 1, x: m.x, y: m.y, visible: visible, imageId: imageId)
        if let l = last, l.x == p.x, l.y == p.y, l.visible == p.visible, l.imageId == p.imageId,
           nowMicros &- lastSentMicros < repeatMicros {
            return
        }
        seq = p.seq
        last = p
        lastSentMicros = nowMicros
        sendPosition(p)
    }

    private func pollShape() {
        guard let s = sampler.currentShape() else { return }
        let r = registry.id(for: s)
        imageId = r.id
        if r.isNew {
            sendImage(CursorImageMessage(id: r.id, png: s.png, hotX: s.hotX, hotY: s.hotY,
                                         widthPt: s.widthPt, heightPt: s.heightPt))
        }
    }
}
