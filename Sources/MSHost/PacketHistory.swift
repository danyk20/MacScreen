import Foundation
import MSCore
import MSProtocol

/// Ring of recently sent video data fragments, used to answer NACKs (PLAN.md section 6.6, Host rules).
///
/// Entries older than `MSConstants.packetHistoryMs` are dropped. Only data fragments are kept: a NACK names
/// missing data fragments, and a retransmitted data fragment is worth more than parity. Thread-safe.
public final class PacketHistory {
    private struct Entry {
        let frameId: UInt32
        let storedAtMicros: UInt64
        /// `blocks[blockIndex][fragIndex]` = encoded `VideoFragment` (data fragments only).
        let blocks: [[Data]]
    }

    private let lock = NSLock()
    private var entries: [Entry] = []   // oldest first
    private let windowMicros: UInt64

    public init(windowMs: Int = MSConstants.packetHistoryMs) {
        windowMicros = UInt64(max(windowMs, 0)) * 1000
    }

    public var frameCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// Remembers the data fragments of one frame and drops entries older than the window.
    public func record(frameId: UInt32, fragments: [OutgoingFragment], nowMicros: UInt64) {
        var blocks: [[Data]] = []
        for f in fragments where f.type == .videoData {
            let b = Int(f.fragment.blockIndex)
            let i = Int(f.fragment.fragIndex)
            while blocks.count <= b { blocks.append([]) }
            // Fragmenter emits data fragments of a block in index order.
            if blocks[b].count == i { blocks[b].append(f.fragment.encode()) }
        }
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(frameId: frameId, storedAtMicros: nowMicros, blocks: blocks))
        prune(nowMicros: nowMicros)
    }

    /// Packets to resend for a NACK, in order. Unknown or expired frames give an empty list.
    /// An empty index list means the whole block; block 0 with no indices also covers frames the
    /// Display has not seen at all, so then every block of the frame is resent.
    public func retransmissions(for nack: NackPacket, nowMicros: UInt64) -> [(PacketType, Data)] {
        lock.lock()
        defer { lock.unlock() }
        prune(nowMicros: nowMicros)
        guard let e = entries.last(where: { $0.frameId == nack.frameId }) else { return [] }
        var out: [(PacketType, Data)] = []
        let b = Int(nack.blockIndex)
        if nack.fragIndices.isEmpty {
            if b == 0 {
                for block in e.blocks { for d in block { out.append((.videoData, d)) } }
            } else if b < e.blocks.count {
                for d in e.blocks[b] { out.append((.videoData, d)) }
            }
            return out
        }
        guard b < e.blocks.count else { return [] }
        var seen = Set<UInt16>()
        for i in nack.fragIndices where Int(i) < e.blocks[b].count && seen.insert(i).inserted {
            out.append((.videoData, e.blocks[b][Int(i)]))
        }
        return out
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    private func prune(nowMicros: UInt64) {
        var n = 0
        while n < entries.count, nowMicros >= entries[n].storedAtMicros,
              nowMicros - entries[n].storedAtMicros > windowMicros { n += 1 }
        if n > 0 { entries.removeFirst(n) }
    }
}
