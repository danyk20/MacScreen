import Foundation
import MSCore

/// Runs a decoding body, mapping reader underflow to `PacketError.truncated`.
@inline(__always)
private func wrapDecode<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch is ByteReaderError {
        throw PacketError.truncated
    }
}

// MARK: - Video

/// Payload of videoData / videoParity packets.
public struct VideoFragment: Equatable {
    public static let headerSize = 28

    public var frameId: UInt32
    public var isKeyframe: Bool
    public var blockIndex: UInt8
    public var blockCount: UInt8
    public var fragIndex: UInt16
    public var k: UInt16
    public var m: UInt16
    public var frameLength: UInt32
    public var captureTimeMicros: UInt64
    public var payload: Data

    public init(frameId: UInt32, isKeyframe: Bool, blockIndex: UInt8, blockCount: UInt8,
                fragIndex: UInt16, k: UInt16, m: UInt16, frameLength: UInt32,
                captureTimeMicros: UInt64, payload: Data) {
        self.frameId = frameId
        self.isKeyframe = isKeyframe
        self.blockIndex = blockIndex
        self.blockCount = blockCount
        self.fragIndex = fragIndex
        self.k = k
        self.m = m
        self.frameLength = frameLength
        self.captureTimeMicros = captureTimeMicros
        self.payload = payload
    }

    public func encode() -> Data {
        var w = ByteWriter(capacity: VideoFragment.headerSize + payload.count)
        w.u32(frameId)
        w.u8(isKeyframe ? 1 : 0)
        w.u8(blockIndex)
        w.u8(blockCount)
        w.u8(0)
        w.u16(fragIndex)
        w.u16(k)
        w.u16(m)
        w.u16(0)
        w.u32(frameLength)
        w.u64(captureTimeMicros)
        w.bytes(payload)
        return w.data
    }

    public static func decode(_ d: Data) throws -> VideoFragment {
        try wrapDecode {
            var r = ByteReader(d)
            let frameId = try r.u32()
            let flags = try r.u8()
            let blockIndex = try r.u8()
            let blockCount = try r.u8()
            try r.skip(1)
            let fragIndex = try r.u16()
            let k = try r.u16()
            let m = try r.u16()
            try r.skip(2)
            let frameLength = try r.u32()
            let capture = try r.u64()
            let payload = r.rest()
            guard k >= 1 else { throw PacketError.invalidField("k") }
            guard Int(k) <= MSConstants.maxDataFragsPerBlock else { throw PacketError.invalidField("k") }
            guard Int(m) <= MSConstants.maxParityFragsPerBlock else { throw PacketError.invalidField("m") }
            guard blockCount >= 1 else { throw PacketError.invalidField("blockCount") }
            guard blockIndex < blockCount else { throw PacketError.invalidField("blockIndex") }
            guard !payload.isEmpty else { throw PacketError.invalidField("payload") }
            guard payload.count <= MSConstants.fragmentSize else { throw PacketError.invalidField("payload") }
            return VideoFragment(frameId: frameId, isKeyframe: flags & 1 != 0, blockIndex: blockIndex,
                                 blockCount: blockCount, fragIndex: fragIndex, k: k, m: m,
                                 frameLength: frameLength, captureTimeMicros: capture, payload: payload)
        }
    }
}

// MARK: - Audio

public struct AudioPacket: Equatable {
    public static let pcmSize = MSConstants.audioFramesPerPacket * MSConstants.audioChannels * 2

    public var seq: UInt32
    public var hostTimeMicros: UInt64
    public var pcm: Data

    public init(seq: UInt32, hostTimeMicros: UInt64, pcm: Data) {
        self.seq = seq
        self.hostTimeMicros = hostTimeMicros
        self.pcm = pcm
    }

    public func encode() -> Data {
        var w = ByteWriter(capacity: 12 + pcm.count)
        w.u32(seq)
        w.u64(hostTimeMicros)
        w.bytes(pcm)
        return w.data
    }

    public static func decode(_ d: Data) throws -> AudioPacket {
        try wrapDecode {
            var r = ByteReader(d)
            let seq = try r.u32()
            let t = try r.u64()
            let pcm = r.rest()
            guard pcm.count == pcmSize else { throw PacketError.invalidField("pcm") }
            return AudioPacket(seq: seq, hostTimeMicros: t, pcm: pcm)
        }
    }
}

// MARK: - Cursor

public struct CursorPacket: Equatable {
    public var seq: UInt32
    public var x: Float
    public var y: Float
    public var visible: Bool
    public var imageId: UInt16

    public init(seq: UInt32, x: Float, y: Float, visible: Bool, imageId: UInt16) {
        self.seq = seq
        self.x = x
        self.y = y
        self.visible = visible
        self.imageId = imageId
    }

    public func encode() -> Data {
        var w = ByteWriter(capacity: 15)
        w.u32(seq)
        w.f32(x)
        w.f32(y)
        w.u8(visible ? 1 : 0)
        w.u16(imageId)
        return w.data
    }

    public static func decode(_ d: Data) throws -> CursorPacket {
        try wrapDecode {
            var r = ByteReader(d)
            let seq = try r.u32()
            let x = try r.f32()
            let y = try r.f32()
            let v = try r.u8()
            let img = try r.u16()
            return CursorPacket(seq: seq, x: x, y: y, visible: v != 0, imageId: img)
        }
    }
}

// MARK: - Ping / Pong

public struct PingPacket: Equatable {
    public var id: UInt32
    public var t0: UInt64

    public init(id: UInt32, t0: UInt64) {
        self.id = id
        self.t0 = t0
    }

    public func encode() -> Data {
        var w = ByteWriter(capacity: 12)
        w.u32(id)
        w.u64(t0)
        return w.data
    }

    public static func decode(_ d: Data) throws -> PingPacket {
        try wrapDecode {
            var r = ByteReader(d)
            return PingPacket(id: try r.u32(), t0: try r.u64())
        }
    }
}

public struct PongPacket: Equatable {
    public var id: UInt32
    public var t0: UInt64
    public var t1: UInt64
    public var t2: UInt64

    public init(id: UInt32, t0: UInt64, t1: UInt64, t2: UInt64) {
        self.id = id
        self.t0 = t0
        self.t1 = t1
        self.t2 = t2
    }

    public func encode() -> Data {
        var w = ByteWriter(capacity: 28)
        w.u32(id)
        w.u64(t0)
        w.u64(t1)
        w.u64(t2)
        return w.data
    }

    public static func decode(_ d: Data) throws -> PongPacket {
        try wrapDecode {
            var r = ByteReader(d)
            return PongPacket(id: try r.u32(), t0: try r.u64(), t1: try r.u64(), t2: try r.u64())
        }
    }
}

// MARK: - Feedback

public struct FeedbackPacket: Equatable {
    public var highestDecodedFrame: UInt32
    public var framesDecoded: UInt32
    public var framesDropped: UInt32
    public var fragsReceived: UInt32
    public var fragsLost: UInt32
    public var fragsRecovered: UInt32
    public var avgDecodeMsX10: UInt16
    public var jitterMsX10: UInt16
    public var requestKeyframe: Bool

    public init(highestDecodedFrame: UInt32, framesDecoded: UInt32, framesDropped: UInt32,
                fragsReceived: UInt32, fragsLost: UInt32, fragsRecovered: UInt32,
                avgDecodeMsX10: UInt16, jitterMsX10: UInt16, requestKeyframe: Bool) {
        self.highestDecodedFrame = highestDecodedFrame
        self.framesDecoded = framesDecoded
        self.framesDropped = framesDropped
        self.fragsReceived = fragsReceived
        self.fragsLost = fragsLost
        self.fragsRecovered = fragsRecovered
        self.avgDecodeMsX10 = avgDecodeMsX10
        self.jitterMsX10 = jitterMsX10
        self.requestKeyframe = requestKeyframe
    }

    /// Convenience init taking milliseconds as Doubles; clamped to 0...6553.5.
    public init(highestDecodedFrame: UInt32, framesDecoded: UInt32, framesDropped: UInt32,
                fragsReceived: UInt32, fragsLost: UInt32, fragsRecovered: UInt32,
                avgDecodeMs: Double, jitterMs: Double, requestKeyframe: Bool) {
        self.init(highestDecodedFrame: highestDecodedFrame, framesDecoded: framesDecoded,
                  framesDropped: framesDropped, fragsReceived: fragsReceived, fragsLost: fragsLost,
                  fragsRecovered: fragsRecovered,
                  avgDecodeMsX10: FeedbackPacket.toX10(avgDecodeMs),
                  jitterMsX10: FeedbackPacket.toX10(jitterMs), requestKeyframe: requestKeyframe)
    }

    private static func toX10(_ ms: Double) -> UInt16 {
        guard ms.isFinite else { return ms > 0 ? UInt16.max : 0 }
        let v = (min(max(ms, 0), 6553.5) * 10).rounded()
        return UInt16(min(max(v, 0), 65535))
    }

    public var avgDecodeMs: Double { Double(avgDecodeMsX10) / 10 }
    public var jitterMs: Double { Double(jitterMsX10) / 10 }

    public func encode() -> Data {
        var w = ByteWriter(capacity: 29)
        w.u32(highestDecodedFrame)
        w.u32(framesDecoded)
        w.u32(framesDropped)
        w.u32(fragsReceived)
        w.u32(fragsLost)
        w.u32(fragsRecovered)
        w.u16(avgDecodeMsX10)
        w.u16(jitterMsX10)
        w.u8(requestKeyframe ? 1 : 0)
        return w.data
    }

    public static func decode(_ d: Data) throws -> FeedbackPacket {
        try wrapDecode {
            var r = ByteReader(d)
            let a = try r.u32(), b = try r.u32(), c = try r.u32()
            let e = try r.u32(), f = try r.u32(), g = try r.u32()
            let dec = try r.u16(), jit = try r.u16()
            let flags = try r.u8()
            return FeedbackPacket(highestDecodedFrame: a, framesDecoded: b, framesDropped: c,
                                  fragsReceived: e, fragsLost: f, fragsRecovered: g,
                                  avgDecodeMsX10: dec, jitterMsX10: jit,
                                  requestKeyframe: flags & 1 != 0)
        }
    }
}

// MARK: - Nack

public struct NackPacket: Equatable {
    public var frameId: UInt32
    public var blockIndex: UInt8
    public var fragIndices: [UInt16]

    public init(frameId: UInt32, blockIndex: UInt8, fragIndices: [UInt16]) {
        self.frameId = frameId
        self.blockIndex = blockIndex
        self.fragIndices = fragIndices
    }

    /// Writes at most 255 indices.
    public func encode() -> Data {
        let n = min(fragIndices.count, 255)
        var w = ByteWriter(capacity: 6 + 2 * n)
        w.u32(frameId)
        w.u8(blockIndex)
        w.u8(UInt8(n))
        for i in 0..<n { w.u16(fragIndices[i]) }
        return w.data
    }

    public static func decode(_ d: Data) throws -> NackPacket {
        try wrapDecode {
            var r = ByteReader(d)
            let frameId = try r.u32()
            let block = try r.u8()
            let count = Int(try r.u8())
            guard r.remaining >= count * 2 else { throw PacketError.truncated }
            var idx = [UInt16]()
            idx.reserveCapacity(count)
            for _ in 0..<count { idx.append(try r.u16()) }
            return NackPacket(frameId: frameId, blockIndex: block, fragIndices: idx)
        }
    }
}

// MARK: - Link probe

public struct LinkProbePacket: Equatable {
    public var trainId: UInt32
    public var seq: UInt32

    public init(trainId: UInt32, seq: UInt32) {
        self.trainId = trainId
        self.seq = seq
    }

    /// Always exactly `MSConstants.fragmentSize` bytes.
    public func encode() -> Data {
        var w = ByteWriter(capacity: MSConstants.fragmentSize)
        w.u32(trainId)
        w.u32(seq)
        w.zeros(MSConstants.fragmentSize - 8)
        return w.data
    }

    public static func decode(_ d: Data) throws -> LinkProbePacket {
        try wrapDecode {
            var r = ByteReader(d)
            return LinkProbePacket(trainId: try r.u32(), seq: try r.u32())
        }
    }
}
