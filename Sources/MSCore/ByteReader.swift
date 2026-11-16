import Foundation

public enum ByteReaderError: Error, Equatable {
    case underflow(needed: Int, remaining: Int)
}

/// Big-endian binary reader. Works with Data slices (non-zero startIndex).
public struct ByteReader {
    private let data: Data
    private var pos: Int

    public init(_ data: Data) {
        self.data = data
        self.pos = data.startIndex
    }

    public var remaining: Int { data.endIndex - pos }

    private mutating func take(_ n: Int) throws -> Range<Int> {
        guard n >= 0, n <= remaining else {
            throw ByteReaderError.underflow(needed: n, remaining: remaining)
        }
        let r = pos..<(pos + n)
        pos += n
        return r
    }

    public mutating func u8() throws -> UInt8 {
        let r = try take(1)
        return data[r.lowerBound]
    }

    public mutating func u16() throws -> UInt16 {
        let r = try take(2)
        var v: UInt16 = 0
        for i in r { v = (v << 8) | UInt16(data[i]) }
        return v
    }

    public mutating func u32() throws -> UInt32 {
        let r = try take(4)
        var v: UInt32 = 0
        for i in r { v = (v << 8) | UInt32(data[i]) }
        return v
    }

    public mutating func u64() throws -> UInt64 {
        let r = try take(8)
        var v: UInt64 = 0
        for i in r { v = (v << 8) | UInt64(data[i]) }
        return v
    }

    public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    public mutating func bytes(_ count: Int) throws -> Data {
        let r = try take(count)
        return Data(data[r])
    }

    public mutating func skip(_ count: Int) throws {
        _ = try take(count)
    }

    public mutating func rest() -> Data {
        let d = Data(data[pos..<data.endIndex])
        pos = data.endIndex
        return d
    }
}
