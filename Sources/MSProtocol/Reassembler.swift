import Foundation
import MSCore

/// Reassembles video frames from fragments, recovers losses with FEC, and decides when to
/// NACK, drop a frame or ask for a keyframe (PLAN.md section 6.6, receiver rules).
///
/// Pure logic: no clocks, no queues. Time (`nowMicros`, any monotonic origin) and RTT are passed in.
/// NOT thread-safe: use it from a single serial queue.
public final class Reassembler {
    public enum Event: Equatable {
        case frame(frameId: UInt32, payload: Data, isKeyframe: Bool, captureTimeMicros: UInt64)
        case nack(NackPacket)
        case frameLost(frameId: UInt32)
        case requestKeyframe
    }

    public struct Counters {
        /// Valid fragments accepted (stored), including parity that was not needed.
        public var fragsReceived: UInt64 = 0
        /// Duplicates, fragments of already delivered/abandoned frames.
        public var fragsDuplicate: UInt64 = 0
        public var fragsInvalid: UInt64 = 0
        /// Data fragments rebuilt by Reed-Solomon.
        public var fragsRecovered: UInt64 = 0
        public var fragsLostEstimate: UInt64 = 0
        public var framesDelivered: UInt64 = 0
        public var framesLost: UInt64 = 0
        public init() {}
    }

    // MARK: State

    private final class Block {
        let k: Int
        let m: Int
        var data: [Data?]
        var parity: [Data?]
        var dataCount = 0
        var parityCount = 0
        var isComplete: Bool { dataCount + parityCount >= k }
        init(k: Int, m: Int) {
            self.k = k
            self.m = m
            data = [Data?](repeating: nil, count: k)
            parity = [Data?](repeating: nil, count: m)
        }
    }

    private final class Frame {
        let id: UInt32
        let blockCount: Int
        let frameLength: Int
        let isKeyframe: Bool
        let captureTime: UInt64
        let firstSeenMicros: UInt64
        var lastFragmentMicros: UInt64
        var blocks: [Block?]
        var completeBlocks = 0
        var received = 0
        var payload: Data?
        var complete: Bool { payload != nil }
        var nackSent = false
        var nackDeadlineMicros: UInt64?
        init(id: UInt32, blockCount: Int, frameLength: Int, isKeyframe: Bool, captureTime: UInt64, now: UInt64) {
            self.id = id
            self.blockCount = blockCount
            self.frameLength = frameLength
            self.isKeyframe = isKeyframe
            self.captureTime = captureTime
            self.firstSeenMicros = now
            self.lastFragmentMicros = now
            blocks = [Block?](repeating: nil, count: blockCount)
        }
    }

    private var frames: [UInt32: Frame] = [:]
    private var nextFrameId: UInt32?
    /// NACK state for a frame next in line that has not produced any fragment yet.
    private var absentNack: (id: UInt32, deadline: UInt64)?
    private var lastKeyframeRequestMicros: UInt64?
    private var sawNonKeyframeFragment = false
    private var stats = Counters()

    public private(set) var awaitingKeyframe: Bool = true
    public var counters: Counters { stats }
    public var framesInAssembly: Int { frames.count }

    public init() {}

    public func reset() {
        frames.removeAll()
        nextFrameId = nil
        absentNack = nil
        lastKeyframeRequestMicros = nil
        sawNonKeyframeFragment = false
        stats = Counters()
        awaitingKeyframe = true
    }

    // MARK: Public API

    /// `rttMs == nil` means unknown (treated as too slow for NACK).
    public func ingest(type: PacketType, fragment f: VideoFragment, nowMicros: UInt64, rttMs: Double?) -> [Event] {
        var events: [Event] = []
        accept(type: type, fragment: f, now: nowMicros, events: &events)
        settle(now: nowMicros, rtt: rttMs, checkStall: false, events: &events)
        return events
    }

    /// Call about every 5 ms. Drives stall, NACK deadline and keyframe-request timers.
    public func tick(nowMicros: UInt64, rttMs: Double?) -> [Event] {
        var events: [Event] = []
        settle(now: nowMicros, rtt: rttMs, checkStall: true, events: &events)
        if awaitingKeyframe, nextFrameId != nil || sawNonKeyframeFragment {
            let interval = UInt64(MSConstants.feedbackIntervalMs) * 1000
            if let last = lastKeyframeRequestMicros {
                if nowMicros >= last, nowMicros - last >= interval {
                    lastKeyframeRequestMicros = nowMicros
                    events.append(.requestKeyframe)
                }
            } else {
                lastKeyframeRequestMicros = nowMicros
                events.append(.requestKeyframe)
            }
        }
        return events
    }

    // MARK: Fragment intake

    private func accept(type: PacketType, fragment f: VideoFragment, now: UInt64, events: inout [Event]) {
        let size = MSConstants.fragmentSize
        let perBlock = MSConstants.maxDataFragsPerBlock
        let isData: Bool
        switch type {
        case .videoData: isData = true
        case .videoParity: isData = false
        default:
            stats.fragsInvalid += 1
            return
        }

        // Stateless validation. Everything about the frame geometry follows from frameLength.
        let length = Int(f.frameLength)
        let blockCount = Int(f.blockCount)
        let blockIndex = Int(f.blockIndex)
        let k = Int(f.k)
        let m = Int(f.m)
        let idx = Int(f.fragIndex)
        let totalFrags = (length + size - 1) / size
        guard length >= 1, blockCount >= 1, blockIndex < blockCount,
              blockCount == (totalFrags + perBlock - 1) / perBlock else {
            stats.fragsInvalid += 1
            return
        }
        let isLastBlock = blockIndex == blockCount - 1
        let expectedK = isLastBlock ? totalFrags - perBlock * (blockCount - 1) : perBlock
        guard k == expectedK, m <= MSConstants.maxParityFragsPerBlock else {
            stats.fragsInvalid += 1
            return
        }
        if isData {
            guard idx < k else { stats.fragsInvalid += 1; return }
            let isLastFragment = isLastBlock && idx == k - 1
            let expectedLen = isLastFragment ? length - size * (totalFrags - 1) : size
            guard f.payload.count == expectedLen else { stats.fragsInvalid += 1; return }
        } else {
            guard idx < m, f.payload.count == size else { stats.fragsInvalid += 1; return }
        }

        // Already delivered or abandoned.
        if let next = nextFrameId, f.frameId < next {
            stats.fragsDuplicate += 1
            return
        }

        var frame = frames[f.frameId]
        if let existing = frame {
            guard existing.blockCount == blockCount, existing.frameLength == length,
                  existing.isKeyframe == f.isKeyframe else {
                stats.fragsInvalid += 1
                return
            }
            if let b = existing.blocks[blockIndex], b.m != m {
                stats.fragsInvalid += 1
                return
            }
        } else {
            guard makeRoom(forId: f.frameId, now: now, events: &events) else { return }
            let created = Frame(id: f.frameId, blockCount: blockCount, frameLength: length,
                                isKeyframe: f.isKeyframe, captureTime: f.captureTimeMicros, now: now)
            if let a = absentNack, a.id == f.frameId {
                created.nackSent = true
                created.nackDeadlineMicros = a.deadline
                absentNack = nil
            }
            frames[f.frameId] = created
            frame = created
        }
        guard let frame else { return }

        let block: Block
        if let b = frame.blocks[blockIndex] {
            block = b
        } else {
            block = Block(k: k, m: m)
            frame.blocks[blockIndex] = block
        }
        if isData {
            guard block.data[idx] == nil else { stats.fragsDuplicate += 1; return }
            block.data[idx] = f.payload
            block.dataCount += 1
        } else {
            guard block.parity[idx] == nil else { stats.fragsDuplicate += 1; return }
            block.parity[idx] = f.payload
            block.parityCount += 1
        }
        stats.fragsReceived += 1
        frame.received += 1
        frame.lastFragmentMicros = now
        if !f.isKeyframe { sawNonKeyframeFragment = true }

        if !frame.complete, block.dataCount + block.parityCount == block.k { // this fragment completed the block
            frame.completeBlocks += 1
            if frame.completeBlocks == frame.blockCount, !assemble(frame) {
                frames[frame.id] = nil
                stats.fragsInvalid += 1
            }
        }
    }

    /// Builds the frame payload; returns false if reconstruction failed (cannot happen with validated input).
    private func assemble(_ frame: Frame) -> Bool {
        let size = MSConstants.fragmentSize
        var out = Data()
        out.reserveCapacity(frame.blockCount * MSConstants.maxDataFragsPerBlock * size)
        var recovered: UInt64 = 0
        for blockOpt in frame.blocks {
            guard let block = blockOpt else { return false }
            if block.dataCount == block.k {
                for d in block.data { if let d { out.append(d) } }
            } else {
                let shards: [Data?] = block.data + block.parity
                guard let rebuilt = try? ReedSolomon.reconstruct(shards: shards, dataCount: block.k,
                                                                 parityCount: block.m, shardSize: size) else {
                    return false
                }
                recovered += UInt64(block.k - block.dataCount)
                for d in rebuilt { out.append(d) }
            }
        }
        guard out.count >= frame.frameLength else { return false }
        if out.count > frame.frameLength { out = out.prefix(frame.frameLength) }
        frame.payload = out
        stats.fragsRecovered += recovered
        return true
    }

    // MARK: Capacity

    /// Ensures room for one more frame. Returns false if the new frame is older than everything held.
    private func makeRoom(forId id: UInt32, now: UInt64, events: inout [Event]) -> Bool {
        guard frames.count >= MSConstants.reassemblyMaxFrames else { return true }
        guard let oldestId = frames.keys.min(), let oldest = frames[oldestId] else { return true }
        if id < oldestId { return false }
        frames[oldestId] = nil
        if !awaitingKeyframe, nextFrameId.map({ oldestId >= $0 }) ?? true {
            declareLost(id: oldestId, frame: oldest, now: now, events: &events)
        }
        return true
    }

    // MARK: Delivery, gaps, loss

    private func expectedFragments(_ frame: Frame) -> Int {
        var n = 0
        for b in frame.blocks { if let b { n += b.k + b.m } }
        return n
    }

    private func addLostEstimate(_ frame: Frame?) {
        guard let frame else { return }
        let missing = expectedFragments(frame) - frame.received
        if missing > 0 { stats.fragsLostEstimate += UInt64(missing) }
    }

    private func deliver(_ frame: Frame, events: inout [Event]) {
        guard let payload = frame.payload else { return }
        frames[frame.id] = nil
        addLostEstimate(frame)
        stats.framesDelivered += 1
        nextFrameId = frame.id &+ 1
        absentNack = nil
        if frame.isKeyframe {
            awaitingKeyframe = false
            lastKeyframeRequestMicros = nil
        }
        events.append(.frame(frameId: frame.id, payload: payload, isKeyframe: frame.isKeyframe,
                             captureTimeMicros: frame.captureTime))
    }

    /// Rule 9. `frame` is the lost frame if it is known.
    private func declareLost(id: UInt32, frame: Frame?, now: UInt64, events: inout [Event]) {
        events.append(.frameLost(frameId: id))
        stats.framesLost += 1
        addLostEstimate(frame)
        frames[id] = nil
        for (key, f) in frames where !f.isKeyframe { frames[key] = nil }
        awaitingKeyframe = true
        nextFrameId = id &+ 1
        absentNack = nil
        lastKeyframeRequestMicros = now
        events.append(.requestKeyframe)
    }

    private func nackDeadline(now: UInt64, rtt: Double) -> UInt64 {
        now + UInt64(((2 * rtt + MSConstants.nackWaitExtraMs) * 1000).rounded())
    }

    private func canNack(_ rtt: Double?) -> Double? {
        if let rtt, rtt >= 0, rtt < MSConstants.nackMaxRttMs { return rtt }
        return nil
    }

    private func sendNacks(for n: UInt32, frame: Frame?, now: UInt64, rtt: Double, events: inout [Event]) {
        let deadline = nackDeadline(now: now, rtt: rtt)
        guard let frame else {
            events.append(.nack(NackPacket(frameId: n, blockIndex: 0, fragIndices: [])))
            absentNack = (n, deadline)
            return
        }
        for (b, blockOpt) in frame.blocks.enumerated() {
            if let block = blockOpt {
                if block.isComplete { continue }
                var missing: [UInt16] = []
                for i in 0..<block.k where block.data[i] == nil { missing.append(UInt16(i)) }
                events.append(.nack(NackPacket(frameId: n, blockIndex: UInt8(b), fragIndices: missing)))
            } else {
                events.append(.nack(NackPacket(frameId: n, blockIndex: UInt8(b), fragIndices: [])))
            }
        }
        frame.nackSent = true
        frame.nackDeadlineMicros = deadline
    }

    private func settle(now: UInt64, rtt: Double?, checkStall: Bool, events: inout [Event]) {
        while true {
            // Sequential delivery.
            if let n = nextFrameId, let f = frames[n], f.complete, !awaitingKeyframe || f.isKeyframe {
                deliver(f, events: &events)
                continue
            }
            // Keyframe jump.
            var jump: Frame?
            for f in frames.values where f.complete && f.isKeyframe {
                if let n = nextFrameId, f.id < n { continue }
                if jump == nil || f.id < jump!.id { jump = f }
            }
            if let kf = jump {
                for id in frames.keys.sorted() where id < kf.id {
                    guard let old = frames[id] else { continue }
                    frames[id] = nil
                    if !awaitingKeyframe {
                        stats.framesLost += 1
                        addLostEstimate(old)
                        events.append(.frameLost(frameId: id))
                    }
                }
                deliver(kf, events: &events)
                continue
            }
            guard !awaitingKeyframe, let n = nextFrameId else { return }

            // Gap, deadline and stall handling for frame n.
            let frame = frames[n]
            let deadline = frame?.nackDeadlineMicros ?? (absentNack?.id == n ? absentNack?.deadline : nil)
            if let deadline {
                if now >= deadline {
                    declareLost(id: n, frame: frame, now: now, events: &events)
                    continue
                }
                return // NACK already sent; waiting.
            }
            let gap = frames.values.contains { $0.complete && $0.id > n }
            var stalled = false
            if checkStall, let frame, !frame.complete, now >= frame.lastFragmentMicros,
               now - frame.lastFragmentMicros > UInt64(MSConstants.frameStallTimeoutMs) * 1000 {
                stalled = true
            }
            guard gap || stalled else { return }
            if let r = canNack(rtt) {
                sendNacks(for: n, frame: frame, now: now, rtt: r, events: &events)
                return
            }
            declareLost(id: n, frame: frame, now: now, events: &events)
        }
    }
}
