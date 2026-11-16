import Foundation
import VideoToolbox
import MSCore

public enum CodecCapabilities {
    public struct EncoderInfo: Codable {
        public var codecName: String
        public var encoderID: String
        public var isHardware: Bool
        public init(codecName: String, encoderID: String, isHardware: Bool) {
            self.codecName = codecName
            self.encoderID = encoderID
            self.isHardware = isHardware
        }
    }

    public struct Report: Codable {
        public var osVersion: String
        public var cpu: String
        public var arch: String
        public var encoders: [EncoderInfo]
        public var hwDecodeH264: Bool
        public var hwDecodeHEVC: Bool
    }

    public static func encoders() -> [EncoderInfo] {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let arr = list as? [[String: Any]] else { return [] }
        var out: [EncoderInfo] = []
        for d in arr {
            guard let type = (d[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value else { continue }
            guard type == kCMVideoCodecType_H264 || type == kCMVideoCodecType_HEVC else { continue }
            let name = (d[kVTVideoEncoderList_CodecName as String] as? String)
                ?? (type == kCMVideoCodecType_HEVC ? Codec.hevc.name : Codec.h264.name)
            let id = d[kVTVideoEncoderList_EncoderID as String] as? String ?? ""
            let hw = (d[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue ?? false
            out.append(EncoderInfo(codecName: name, encoderID: id, isHardware: hw))
        }
        return out
    }

    public static func hardwareDecodeSupported(_ codec: Codec) -> Bool {
        VTIsHardwareDecodeSupported(codec.cmType)
    }

    public static func canHardwareEncode(_ format: VideoFormat) -> Bool {
        let spec: [String: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(format.width), height: Int32(format.height),
            codecType: format.codec.cmType, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let s = session else { return false }
        VTCompressionSessionInvalidate(s)
        return true
    }

    public static func report() -> Report {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        return Report(
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            cpu: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            arch: arch,
            encoders: encoders(),
            hwDecodeH264: hardwareDecodeSupported(.h264),
            hwDecodeHEVC: hardwareDecodeSupported(.hevc))
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
