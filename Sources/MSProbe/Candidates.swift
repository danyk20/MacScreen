import Foundation
import MSCore
import MSCodec

public struct Candidate: Codable, Equatable {
    public var format: VideoFormat
    public var hiDPI: Bool
    public var bitrate: Int

    public init(format: VideoFormat, hiDPI: Bool, bitrate: Int) {
        self.format = format
        self.hiDPI = hiDPI
        self.bitrate = bitrate
    }
}

public enum CandidateLadder {
    public static func make(panelWidth: Int, panelHeight: Int) -> [Candidate] {
        let scales: [Double] = [1.0, 0.75, 0.625, 0.5]
        let codecs: [Codec] = [.hevc, .h264]
        var out: [Candidate] = []
        for fps in [60, 30] {
            for scale in scales {
                for codec in codecs {
                    let w = Int(Double(panelWidth) * scale) & ~1
                    let h = Int(Double(panelHeight) * scale) & ~1
                    let bpp = codec == .hevc ? MSConstants.bitsPerPixelHEVC : MSConstants.bitsPerPixelH264
                    let bitrate = Int(Double(w) * Double(h) * Double(fps) * bpp)
                    out.append(Candidate(
                        format: VideoFormat(codec: codec, width: w, height: h, fps: fps, bitDepth: 8),
                        hiDPI: scale >= 0.75, bitrate: bitrate))
                }
            }
        }
        return out
    }
}
