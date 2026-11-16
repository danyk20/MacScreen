import Foundation
import CoreMedia

public enum Codec: UInt8, Codable, CaseIterable {
    case h264 = 1
    case hevc = 2

    public var cmType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    public var name: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

public struct VideoFormat: Codable, Equatable {
    public var codec: Codec
    public var width: Int
    public var height: Int
    public var fps: Int
    /// 8 or 10.
    public var bitDepth: Int

    public init(codec: Codec, width: Int, height: Int, fps: Int, bitDepth: Int) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitDepth = bitDepth
    }
}

public struct EncodedFrame {
    /// Sample bytes exactly as VideoToolbox emits them (4-byte length-prefixed NAL units).
    public var data: Data
    /// Non-nil only on keyframes (HEVC: VPS, SPS, PPS; H.264: SPS, PPS).
    public var parameterSets: [Data]?
    public var isKeyframe: Bool
    public var captureTimeMicros: UInt64

    public init(data: Data, parameterSets: [Data]?, isKeyframe: Bool, captureTimeMicros: UInt64) {
        self.data = data
        self.parameterSets = parameterSets
        self.isKeyframe = isKeyframe
        self.captureTimeMicros = captureTimeMicros
    }
}

public enum CodecError: Error {
    case sessionCreationFailed(OSStatus)
    case unsupportedFormat(String)
    case encodeFailed(OSStatus)
    case decodeFailed(OSStatus)
    case missingParameterSets
    case malformedPayload(String)
}
