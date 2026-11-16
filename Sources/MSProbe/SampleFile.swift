import Foundation
import MSCore
import MSCodec

public enum SampleFileError: Error { case badMagic, truncated, badHeader }

public struct SampleFile {
    public struct Header: Codable, Equatable {
        public var format: VideoFormat
        public var frameCount: Int
        public var bitrate: Int
        public init(format: VideoFormat, frameCount: Int, bitrate: Int) {
            self.format = format
            self.frameCount = frameCount
            self.bitrate = bitrate
        }
    }

    private static let magic = Data("MSV1".utf8)

    public var header: Header
    public var frames: [EncodedFrame]

    public init(header: Header, frames: [EncodedFrame]) {
        self.header = header
        self.frames = frames
    }

    public func serialize() -> Data {
        let json = (try? JSONEncoder().encode(header)) ?? Data()
        var w = ByteWriter(capacity: 8 + json.count + frames.reduce(0) { $0 + 5 + $1.data.count + 64 })
        w.bytes(Self.magic)
        w.u32(UInt32(truncatingIfNeeded: json.count))
        w.bytes(json)
        for f in frames {
            let payload = FramePayload.encode(f)
            w.u8(f.isKeyframe ? 1 : 0)
            w.u32(UInt32(truncatingIfNeeded: payload.count))
            w.bytes(payload)
        }
        return w.data
    }

    public static func parse(_ data: Data) throws -> SampleFile {
        var r = ByteReader(data)
        do {
            guard try r.bytes(4) == magic else { throw SampleFileError.badMagic }
            let jsonLength = Int(try r.u32())
            let json = try r.bytes(jsonLength)
            guard let header = try? JSONDecoder().decode(Header.self, from: json),
                  header.format.fps > 0, header.frameCount >= 0 else { throw SampleFileError.badHeader }
            var frames: [EncodedFrame] = []
            for i in 0..<header.frameCount {
                let key = try r.u8() != 0
                let length = Int(try r.u32())
                let payload = try r.bytes(length)
                let t = UInt64(i) * 1_000_000 / UInt64(header.format.fps)
                do {
                    frames.append(try FramePayload.decode(payload, isKeyframe: key, captureTimeMicros: t))
                } catch {
                    throw SampleFileError.truncated
                }
            }
            return SampleFile(header: header, frames: frames)
        } catch is ByteReaderError {
            throw SampleFileError.truncated
        }
    }

    public func write(to url: URL) throws {
        try serialize().write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> SampleFile {
        try parse(try Data(contentsOf: url))
    }
}
