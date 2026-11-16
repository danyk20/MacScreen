import Foundation
import CoreMedia
import MSCore

public enum ParameterSets {
    public static func extract(from desc: CMFormatDescription, codec: Codec) throws -> [Data] {
        var count = 0
        var headerLength: Int32 = 0
        var status: OSStatus
        switch codec {
        case .hevc:
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                desc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        case .h264:
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        }
        guard status == noErr, count > 0 else { throw CodecError.missingParameterSets }

        var sets: [Data] = []
        sets.reserveCapacity(count)
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            switch codec {
            case .hevc:
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    desc, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            case .h264:
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    desc, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let p = ptr, size > 0 else { throw CodecError.missingParameterSets }
            sets.append(Data(bytes: p, count: size))
        }
        return sets
    }

    public static func makeFormatDescription(codec: Codec, parameterSets: [Data]) throws -> CMVideoFormatDescription {
        guard !parameterSets.isEmpty else { throw CodecError.missingParameterSets }
        let n = parameterSets.count
        let pointers = UnsafeMutablePointer<UnsafePointer<UInt8>>.allocate(capacity: n)
        let sizes = UnsafeMutablePointer<Int>.allocate(capacity: n)
        var allocated: [UnsafeMutablePointer<UInt8>] = []
        defer {
            for a in allocated { a.deallocate() }
            pointers.deallocate()
            sizes.deallocate()
        }
        for (i, set) in parameterSets.enumerated() {
            let mem = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            allocated.append(mem)
            set.copyBytes(to: mem, count: set.count)
            (pointers + i).initialize(to: UnsafePointer(mem))
            sizes[i] = set.count
        }
        var desc: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: n,
                parameterSetPointers: UnsafePointer(pointers), parameterSetSizes: UnsafePointer(sizes),
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: n,
                parameterSetPointers: UnsafePointer(pointers), parameterSetSizes: UnsafePointer(sizes),
                nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
        }
        guard status == noErr, let d = desc else { throw CodecError.decodeFailed(status) }
        return d
    }

    /// `u8 count`, then per set `u16 length | bytes`.
    public static func encodeConfig(_ sets: [Data]) -> Data {
        var w = ByteWriter(capacity: 1 + sets.reduce(0) { $0 + 2 + $1.count })
        w.u8(UInt8(truncatingIfNeeded: sets.count))
        for s in sets {
            w.u16(UInt16(truncatingIfNeeded: s.count))
            w.bytes(s)
        }
        return w.data
    }

    public static func decodeConfig(_ d: Data) throws -> [Data] {
        var r = ByteReader(d)
        do {
            let count = Int(try r.u8())
            var sets: [Data] = []
            sets.reserveCapacity(count)
            for _ in 0..<count {
                let len = Int(try r.u16())
                sets.append(try r.bytes(len))
            }
            return sets
        } catch {
            throw CodecError.malformedPayload("truncated parameter-set config")
        }
    }
}

public enum FramePayload {
    /// `u16 configLength | config | sample data`.
    public static func encode(_ f: EncodedFrame) -> Data {
        let config = f.parameterSets.map { ParameterSets.encodeConfig($0) } ?? Data()
        var w = ByteWriter(capacity: 2 + config.count + f.data.count)
        w.u16(UInt16(truncatingIfNeeded: config.count))
        w.bytes(config)
        w.bytes(f.data)
        return w.data
    }

    public static func decode(_ payload: Data, isKeyframe: Bool, captureTimeMicros: UInt64) throws -> EncodedFrame {
        var r = ByteReader(payload)
        do {
            let configLength = Int(try r.u16())
            let sets: [Data]?
            if configLength > 0 {
                sets = try ParameterSets.decodeConfig(try r.bytes(configLength))
            } else {
                sets = nil
            }
            return EncodedFrame(data: r.rest(), parameterSets: sets, isKeyframe: isKeyframe,
                                captureTimeMicros: captureTimeMicros)
        } catch let e as CodecError {
            throw e
        } catch {
            throw CodecError.malformedPayload("truncated frame payload")
        }
    }
}
