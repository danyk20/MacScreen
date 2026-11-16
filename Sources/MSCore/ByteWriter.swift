import Foundation

/// Big-endian binary writer. All wire data must be built with this type.
public struct ByteWriter {
    public private(set) var data: Data

    public init(capacity: Int = 0) {
        data = Data()
        if capacity > 0 { data.reserveCapacity(capacity) }
    }

    public var count: Int { data.count }

    public mutating func u8(_ v: UInt8) { data.append(v) }

    public mutating func u16(_ v: UInt16) {
        data.append(UInt8(truncatingIfNeeded: v >> 8))
        data.append(UInt8(truncatingIfNeeded: v))
    }

    public mutating func u32(_ v: UInt32) {
        var shift = 24
        while shift >= 0 {
            data.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
            shift -= 8
        }
    }

    public mutating func u64(_ v: UInt64) {
        var shift = 56
        while shift >= 0 {
            data.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
            shift -= 8
        }
    }

    public mutating func f32(_ v: Float) { u32(v.bitPattern) }

    public mutating func bytes(_ d: Data) { data.append(d) }

    public mutating func zeros(_ count: Int) {
        guard count > 0 else { return }
        data.append(Data(count: count))
    }
}
