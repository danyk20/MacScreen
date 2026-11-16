import Foundation
import MSCore

public struct OutgoingFragment {
    /// `.videoData` or `.videoParity`.
    public let type: PacketType
    public let fragment: VideoFragment

    public init(type: PacketType, fragment: VideoFragment) {
        self.type = type
        self.fragment = fragment
    }
}

public enum FragmenterError: Error, Equatable {
    case emptyPayload
    case payloadTooLarge
}

/// Splits a frame payload into FEC-protected fragments (PLAN.md section 6.6). Pure and stateless.
public enum Fragmenter {
    /// `m = 0` if `fecRatio <= 0`, else `min(32, max(1, ceil(k * fecRatio)))`.
    public static func parityCount(k: Int, fecRatio: Double) -> Int {
        guard fecRatio > 0, k > 0 else { return 0 }
        let v = (Double(k) * fecRatio).rounded(.up)
        if !(v < Double(MSConstants.maxParityFragsPerBlock)) { return MSConstants.maxParityFragsPerBlock }
        return max(1, Int(v))
    }

    /// Output order: for each block, its data fragments then its parity fragments.
    public static func fragment(payload: Data, frameId: UInt32, isKeyframe: Bool,
                                captureTimeMicros: UInt64, fecRatio: Double) throws -> [OutgoingFragment] {
        guard !payload.isEmpty else { throw FragmenterError.emptyPayload }
        let size = MSConstants.fragmentSize
        let perBlock = MSConstants.maxDataFragsPerBlock
        let totalFrags = (payload.count + size - 1) / size
        let blockCount = (totalFrags + perBlock - 1) / perBlock
        guard blockCount <= Int(UInt8.max), payload.count <= Int(UInt32.max) else {
            throw FragmenterError.payloadTooLarge
        }

        var out: [OutgoingFragment] = []
        let m0 = parityCount(k: min(perBlock, totalFrags), fecRatio: fecRatio)
        out.reserveCapacity(totalFrags + blockCount * m0)

        for b in 0..<blockCount {
            let k = min(perBlock, totalFrags - perBlock * b)
            let m = parityCount(k: k, fecRatio: fecRatio)
            var shards: [Data] = []
            shards.reserveCapacity(k)
            for i in 0..<k {
                let start = (b * perBlock + i) * size
                let end = min(start + size, payload.count)
                shards.append(payload.subdata(in: (payload.startIndex + start)..<(payload.startIndex + end)))
            }
            let parity = try encodeParity(shards, m: m, size: size)

            func make(_ idx: Int, _ data: Data) -> VideoFragment {
                VideoFragment(frameId: frameId, isKeyframe: isKeyframe, blockIndex: UInt8(b),
                              blockCount: UInt8(blockCount), fragIndex: UInt16(idx), k: UInt16(k),
                              m: UInt16(m), frameLength: UInt32(payload.count),
                              captureTimeMicros: captureTimeMicros, payload: data)
            }
            for (i, s) in shards.enumerated() {
                out.append(OutgoingFragment(type: .videoData, fragment: make(i, s)))
            }
            for (i, p) in parity.enumerated() {
                out.append(OutgoingFragment(type: .videoParity, fragment: make(i, p)))
            }
        }
        return out
    }

    private static func encodeParity(_ shards: [Data], m: Int, size: Int) throws -> [Data] {
        do {
            return try ReedSolomon.encode(data: shards, parityCount: m, shardSize: size)
        } catch {
            // Parameters are validated above; reaching this means an internal invariant broke.
            throw FragmenterError.payloadTooLarge
        }
    }
}
