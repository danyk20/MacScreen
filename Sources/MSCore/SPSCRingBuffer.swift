import Foundation
import CMSAtomics

/// Lock-free single-producer single-consumer byte ring buffer.
/// Exactly one thread may call `write`, and exactly one (other) thread may call
/// `read`/`skip`. Safe for real-time threads: no locks, no allocation.
public final class SPSCRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutableRawPointer
    private let head: UnsafeMutablePointer<MSAtomicU64>  // total bytes written
    private let tail: UnsafeMutablePointer<MSAtomicU64>  // total bytes consumed
    private let size: Int
    private let mask: UInt64

    public init(capacity: Int) {
        var s = 1
        while s < max(capacity, 1) { s <<= 1 }
        size = s
        mask = UInt64(s - 1)
        storage = UnsafeMutableRawPointer.allocate(byteCount: s, alignment: 16)
        head = UnsafeMutablePointer<MSAtomicU64>.allocate(capacity: 1)
        tail = UnsafeMutablePointer<MSAtomicU64>.allocate(capacity: 1)
        ms_atomic_u64_init(head, 0)
        ms_atomic_u64_init(tail, 0)
    }

    deinit {
        storage.deallocate()
        head.deallocate()
        tail.deallocate()
    }

    public var availableToRead: Int {
        // Load tail first: head only grows, so head >= tail holds from any thread.
        let t = ms_atomic_u64_load_acquire(tail)
        let h = ms_atomic_u64_load_acquire(head)
        return Int(h &- t)
    }

    public var availableToWrite: Int { size - availableToRead }

    /// Producer side. Writes as many bytes as fit; returns the count written.
    public func write(_ src: UnsafeRawBufferPointer) -> Int {
        guard let base = src.baseAddress, src.count > 0 else { return 0 }
        let h = ms_atomic_u64_load_acquire(head)
        let t = ms_atomic_u64_load_acquire(tail)
        let free = size - Int(h &- t)
        let n = min(free, src.count)
        if n == 0 { return 0 }
        let off = Int(h & mask)
        let first = min(n, size - off)
        memcpy(storage + off, base, first)
        if n > first { memcpy(storage, base + first, n - first) }
        ms_atomic_u64_store_release(head, h &+ UInt64(n))
        return n
    }

    /// Consumer side. Reads up to `dst.count` bytes; returns the count read.
    public func read(into dst: UnsafeMutableRawBufferPointer) -> Int {
        guard let base = dst.baseAddress, dst.count > 0 else { return 0 }
        let t = ms_atomic_u64_load_acquire(tail)
        let h = ms_atomic_u64_load_acquire(head)
        let n = min(Int(h &- t), dst.count)
        if n == 0 { return 0 }
        let off = Int(t & mask)
        let first = min(n, size - off)
        memcpy(base, storage + off, first)
        if n > first { memcpy(base + first, storage, n - first) }
        ms_atomic_u64_store_release(tail, t &+ UInt64(n))
        return n
    }

    /// Consumer side. Discards up to `count` bytes; returns the count discarded.
    public func skip(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let t = ms_atomic_u64_load_acquire(tail)
        let h = ms_atomic_u64_load_acquire(head)
        let n = min(Int(h &- t), count)
        if n > 0 { ms_atomic_u64_store_release(tail, t &+ UInt64(n)) }
        return n
    }

    /// Empties the buffer. Only call when both producer and consumer are stopped.
    public func reset() {
        ms_atomic_u64_store_release(head, 0)
        ms_atomic_u64_store_release(tail, 0)
    }
}
