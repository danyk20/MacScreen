import Foundation
import os

/// Thread-safe monotonically accumulating counter.
public final class Counter: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var v: UInt64 = 0

    public init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    public func add(_ n: UInt64 = 1) {
        os_unfair_lock_lock(lock)
        v &+= n
        os_unfair_lock_unlock(lock)
    }

    public var value: UInt64 {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return v
    }

    public func takeAndReset() -> UInt64 {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let r = v
        v = 0
        return r
    }
}

/// Rolling statistics over a fixed window. NOT thread-safe: use from one queue.
public struct RollingStats {
    private var buf: [Double]
    private var next = 0
    public private(set) var count = 0

    public init(window: Int) {
        buf = [Double](repeating: 0, count: Swift.max(window, 1))
    }

    public mutating func add(_ v: Double) {
        buf[next] = v
        next = (next + 1) % buf.count
        if count < buf.count { count += 1 }
    }

    public var mean: Double {
        guard count > 0 else { return 0 }
        var s = 0.0
        for i in 0..<count { s += buf[i] }
        return s / Double(count)
    }

    /// Nearest-rank 95th percentile; 0 when empty.
    public var p95: Double {
        guard count > 0 else { return 0 }
        let sorted = buf[0..<count].sorted()
        let idx = Int((0.95 * Double(count)).rounded(.up)) - 1
        return sorted[Swift.min(Swift.max(idx, 0), count - 1)]
    }

    public var max: Double {
        guard count > 0 else { return 0 }
        return buf[0..<count].max() ?? 0
    }

    public mutating func reset() {
        next = 0
        count = 0
    }
}
