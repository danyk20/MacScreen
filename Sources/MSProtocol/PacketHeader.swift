import Foundation
import MSCore

public enum PacketType: UInt8, CaseIterable {
    case videoData = 1, videoParity = 2, audio = 3, cursor = 4, ping = 5, pong = 6
    case feedback = 7, nack = 8, linkProbe = 9
}

public enum PacketError: Error, Equatable {
    case truncated
    case unknownType(UInt8)
    case invalidField(String)
}

/// 12-byte media channel header: `u8 type | u8 0 | u16 0 | u64 counter`.
public struct PacketHeader: Equatable {
    public static let size = 12

    public var type: PacketType
    public var counter: UInt64

    public init(type: PacketType, counter: UInt64) {
        self.type = type
        self.counter = counter
    }

    public func encode() -> Data {
        var w = ByteWriter(capacity: PacketHeader.size)
        w.u8(type.rawValue)
        w.u8(0)
        w.u16(0)
        w.u64(counter)
        return w.data
    }

    /// Reads the first 12 bytes; reserved bytes are ignored.
    public static func decode(_ d: Data) throws -> PacketHeader {
        do {
            var r = ByteReader(d)
            let raw = try r.u8()
            try r.skip(3)
            let counter = try r.u64()
            guard let type = PacketType(rawValue: raw) else { throw PacketError.unknownType(raw) }
            return PacketHeader(type: type, counter: counter)
        } catch is ByteReaderError {
            throw PacketError.truncated
        }
    }
}
