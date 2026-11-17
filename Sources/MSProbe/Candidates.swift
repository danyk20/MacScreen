import Foundation
import MSCore
import MSCodec

public struct Candidate: Codable, Equatable {
    public var format: VideoFormat
    /// The virtual display is always the panel size with HiDPI (PLAN 6.10); kept for the report format.
    public var hiDPI: Bool
    /// Profile bitrate (bitsPerPixel of the codec).
    public var bitrate: Int
    /// Generated and benchmarked, but never chosen automatically (HEVC 1.0 x P at 30 fps).
    public var manualOnly: Bool

    public init(format: VideoFormat, hiDPI: Bool, bitrate: Int, manualOnly: Bool = false) {
        self.format = format
        self.hiDPI = hiDPI
        self.bitrate = bitrate
        self.manualOnly = manualOnly
    }

    private enum CodingKeys: String, CodingKey { case format, hiDPI, bitrate, manualOnly }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(VideoFormat.self, forKey: .format)
        hiDPI = try c.decode(Bool.self, forKey: .hiDPI)
        bitrate = try c.decode(Int.self, forKey: .bitrate)
        manualOnly = try c.decodeIfPresent(Bool.self, forKey: .manualOnly) ?? false
    }

    /// Bitrate at the minimum bits per pixel of the codec (PLAN 6.10 step 4 link check).
    public var minBitrate: Int {
        let bpp = format.codec == .hevc ? MSConstants.minBitsPerPixelHEVC : MSConstants.minBitsPerPixelH264
        return Int(Double(format.width) * Double(format.height) * Double(format.fps) * bpp)
    }
}

public enum CandidateLadder {
    /// PLAN 6.10: encode scales {1.0, 0.75, 0.625, 0.5} x P. All HEVC 60 fps (not 1.0 x P: 5K60 is beyond the
    /// M2 encoder), then HEVC 30 fps at scales <= 0.75, then H.264 60 fps, then H.264 30 fps. HEVC 1.0 x P at
    /// 30 fps is appended last and manual-only. The virtual display is always P with HiDPI.
    public static func make(panelWidth: Int, panelHeight: Int) -> [Candidate] {
        let scales: [Double] = [1.0, 0.75, 0.625, 0.5]
        var out: [Candidate] = []

        func add(_ codec: Codec, _ scale: Double, _ fps: Int, manualOnly: Bool = false) {
            let w = Int(Double(panelWidth) * scale) & ~1
            let h = Int(Double(panelHeight) * scale) & ~1
            // Hardware H.264 cannot go beyond 4096x2304 (the M2 encoder returns no frames at 5K).
            if codec == .h264 && (w > 4096 || h > 2304) { return }
            let bpp = codec == .hevc ? MSConstants.bitsPerPixelHEVC : MSConstants.bitsPerPixelH264
            let bitrate = Int(Double(w) * Double(h) * Double(fps) * bpp)
            out.append(Candidate(
                format: VideoFormat(codec: codec, width: w, height: h, fps: fps, bitDepth: 8),
                hiDPI: true, bitrate: bitrate, manualOnly: manualOnly))
        }

        for s in scales where s < 1.0 { add(.hevc, s, 60) }
        for s in scales where s < 1.0 { add(.hevc, s, 30) }
        for s in scales { add(.h264, s, 60) }
        for s in scales { add(.h264, s, 30) }
        add(.hevc, 1.0, 30, manualOnly: true)
        return out
    }
}
