import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MSProtocol
import QuartzCore

/// A decoded cursor image ready to draw.
public struct CursorImageEntry {
    public let id: UInt16
    public let image: CGImage
    public let hotX: Double
    public let hotY: Double
    public let widthPt: Double
    public let heightPt: Double
}

/// Cursor images by `imageId`; bounded, oldest insertion evicted first.
public struct CursorImageCache {
    public let capacity: Int
    private var entries: [UInt16: CursorImageEntry] = [:]
    private var order: [UInt16] = []

    public init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    public var count: Int { entries.count }
    public subscript(id: UInt16) -> CursorImageEntry? { entries[id] }

    /// Decodes and stores the image. Returns false when the PNG cannot be decoded or has a bad size.
    @discardableResult
    public mutating func insert(_ m: CursorImageMessage) -> Bool {
        guard m.widthPt > 0, m.heightPt > 0,
              let src = CGImageSourceCreateWithData(m.png as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
        if entries[m.id] == nil {
            order.append(m.id)
            if order.count > capacity { entries[order.removeFirst()] = nil }
        }
        entries[m.id] = CursorImageEntry(id: m.id, image: img, hotX: m.hotX, hotY: m.hotY,
                                         widthPt: m.widthPt, heightPt: m.heightPt)
        return true
    }
}

/// Pure geometry for placing the cursor.
public enum CursorGeometry {
    /// Rectangle (top-left origin) of the cursor image inside `bounds` for a 0...1 position.
    public static func frame(x: Float, y: Float, entry: CursorImageEntry, in bounds: CGSize) -> CGRect {
        let px = CGFloat(min(max(x, 0), 1)) * bounds.width
        let py = CGFloat(min(max(y, 0), 1)) * bounds.height
        return CGRect(x: px - CGFloat(entry.hotX), y: py - CGFloat(entry.hotY),
                      width: CGFloat(entry.widthPt), height: CGFloat(entry.heightPt))
    }

    /// True when `seq` is newer than `last` (wrapping UInt32 compare).
    public static func isNewer(_ seq: UInt32, than last: UInt32) -> Bool {
        Int32(bitPattern: seq &- last) > 0
    }
}

/// What to draw right now, or nil to hide.
public struct CursorDrawState {
    public let entry: CursorImageEntry
    public let frame: CGRect      // top-left origin
}

/// Latest position plus the image cache; no UI. Not thread-safe (use from one queue).
public struct CursorModel {
    public private(set) var cache = CursorImageCache()
    public private(set) var latest: CursorPacket?

    public init(cacheCapacity: Int = 64) { cache = CursorImageCache(capacity: cacheCapacity) }

    public mutating func ingest(image m: CursorImageMessage) { cache.insert(m) }

    /// Drops packets older than the newest seen (UDP reordering). Returns whether it was applied.
    @discardableResult
    public mutating func ingest(position p: CursorPacket) -> Bool {
        if let l = latest, !CursorGeometry.isNewer(p.seq, than: l.seq) { return false }
        latest = p
        return true
    }

    public mutating func reset() { latest = nil }

    public func drawState(in bounds: CGSize) -> CursorDrawState? {
        guard let p = latest, p.visible, let e = cache[p.imageId] else { return nil }
        return CursorDrawState(entry: e, frame: CursorGeometry.frame(x: p.x, y: p.y, entry: e, in: bounds))
    }
}

/// A `CALayer` drawn above the Metal layer. Main thread only (PLAN.md section 6.7).
public final class CursorLayer {
    public let layer = CALayer()
    private var model = CursorModel()
    private var shownImageId: UInt16?

    public init() {
        layer.isHidden = true
        layer.contentsGravity = .resize
        layer.zPosition = 100
    }

    public func attach(to root: CALayer) { root.addSublayer(layer) }

    public func add(image m: CursorImageMessage) {
        model.ingest(image: m)
        refresh()
    }

    public func update(_ p: CursorPacket) {
        if model.ingest(position: p) { refresh() }
    }

    public func reset() {
        model.reset()
        refresh()
    }

    /// Call when the parent layer's bounds change.
    public func refresh() {
        guard let root = layer.superlayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let s = model.drawState(in: root.bounds.size) {
            if shownImageId != s.entry.id {
                layer.contents = s.entry.image
                shownImageId = s.entry.id
            }
            layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            // Parent is not flipped: convert the top-left rect to bottom-left.
            layer.frame = CGRect(x: s.frame.minX, y: root.bounds.height - s.frame.maxY,
                                 width: s.frame.width, height: s.frame.height)
            layer.isHidden = false
        } else {
            layer.isHidden = true
        }
        CATransaction.commit()
    }
}
