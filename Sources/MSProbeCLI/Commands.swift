import Foundation
import MSCore
import MSCodec
import MSProbe

enum CLIError: Error {
    case usage(String)
    case runtime(String)
}

enum Commands {
    static let usage = """
    usage:
      msprobe caps
      msprobe encode --width W --height H --fps F --codec hevc|h264 [--bits 8|10] [--bitrate BPS] [--frames N] --out FILE
      msprobe decode FILE
      msprobe candidates --panel WxH --out DIR [--frames N]
      msprobe decode-all DIR
    Every command prints one JSON document to stdout; progress goes to stderr.
    """

    static func progress(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    static func dispatch(_ args: [String]) -> Int32 {
        guard let cmd = args.first, cmd != "--help", cmd != "-h", cmd != "help" else {
            progress(usage)
            return 2
        }
        let rest = Array(args.dropFirst())
        do {
            let json: Data
            switch cmd {
            case "caps": json = try caps(rest)
            case "encode": json = try encode(rest)
            case "decode": json = try decode(rest)
            case "candidates": json = try candidates(rest)
            case "decode-all": json = try decodeAll(rest)
            default: throw CLIError.usage("unknown command '\(cmd)'")
            }
            print(String(decoding: json, as: UTF8.self))
            return 0
        } catch CLIError.usage(let m) {
            progress("error: \(m)\n\(usage)")
            return 2
        } catch CLIError.runtime(let m) {
            progress("error: \(m)")
            return 1
        } catch {
            progress("error: \(error)")
            return 1
        }
    }

    // MARK: helpers

    static func render<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(value)
    }

    /// Parses `--name value` pairs and positional arguments.
    static func parse(_ args: [String], options: Set<String>) throws -> (opts: [String: String], positional: [String]) {
        var opts: [String: String] = [:]
        var positional: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                guard options.contains(a) else { throw CLIError.usage("unknown option \(a)") }
                guard i + 1 < args.count else { throw CLIError.usage("missing value for \(a)") }
                opts[a] = args[i + 1]
                i += 2
            } else {
                positional.append(a)
                i += 1
            }
        }
        return (opts, positional)
    }

    static func intOption(_ opts: [String: String], _ name: String, default def: Int? = nil) throws -> Int {
        guard let s = opts[name] else {
            if let def { return def }
            throw CLIError.usage("missing \(name)")
        }
        guard let v = Int(s), v > 0 else { throw CLIError.usage("invalid value for \(name): \(s)") }
        return v
    }

    static func defaultBitrate(_ f: VideoFormat) -> Int {
        let bpp = f.codec == .hevc ? MSConstants.bitsPerPixelHEVC : MSConstants.bitsPerPixelH264
        return Int(Double(f.width) * Double(f.height) * Double(f.fps) * bpp)
    }

    static func label(_ f: VideoFormat) -> String {
        "\(f.codec.name) \(f.width)x\(f.height)@\(f.fps) \(f.bitDepth)-bit"
    }

    static func listMSV(_ dir: String) throws -> [URL] {
        let url = URL(fileURLWithPath: dir)
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            throw CLIError.runtime("cannot read directory \(dir)")
        }
        return items.filter { $0.pathExtension == "msv" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: commands

    static func caps(_ args: [String]) throws -> Data {
        guard args.isEmpty else { throw CLIError.usage("caps takes no arguments") }
        return try render(ProbeReport.gatherCaps())
    }

    static func encode(_ args: [String]) throws -> Data {
        let (o, pos) = try parse(args, options: ["--width", "--height", "--fps", "--codec", "--bits", "--bitrate", "--frames", "--out"])
        guard pos.isEmpty else { throw CLIError.usage("unexpected argument \(pos[0])") }
        let w = try intOption(o, "--width"), h = try intOption(o, "--height"), fps = try intOption(o, "--fps")
        let codec: Codec
        switch o["--codec"] {
        case "hevc": codec = .hevc
        case "h264": codec = .h264
        default: throw CLIError.usage("--codec must be hevc or h264")
        }
        let bits = try intOption(o, "--bits", default: 8)
        guard bits == 8 || bits == 10 else { throw CLIError.usage("--bits must be 8 or 10") }
        guard let out = o["--out"] else { throw CLIError.usage("missing --out") }
        let frames = try intOption(o, "--frames", default: 90)
        let format = VideoFormat(codec: codec, width: w, height: h, fps: fps, bitDepth: bits)
        let bitrate = try intOption(o, "--bitrate", default: defaultBitrate(format))
        progress("encoding \(label(format)) at \(bitrate) bit/s, \(frames) frames")
        let (result, sample) = EncodeBench.run(format: format, bitrate: bitrate, frameCount: frames)
        if let sample {
            do { try sample.write(to: URL(fileURLWithPath: out)) } catch {
                throw CLIError.runtime("cannot write \(out): \(error)")
            }
            progress("wrote \(out)")
        }
        return try render(result)
    }

    static func decode(_ args: [String]) throws -> Data {
        guard args.count == 1, !args[0].hasPrefix("--") else { throw CLIError.usage("decode takes exactly one FILE") }
        let sample: SampleFile
        do { sample = try SampleFile.read(from: URL(fileURLWithPath: args[0])) } catch {
            throw CLIError.runtime("cannot read \(args[0]): \(error)")
        }
        progress("decoding \(args[0]): \(label(sample.header.format))")
        return try render(DecodeBench.run(sample: sample))
    }

    struct CandidateRun: Codable {
        var candidate: Candidate
        var encode: BenchResult
        var file: String?
    }

    static func candidates(_ args: [String]) throws -> Data {
        let (o, pos) = try parse(args, options: ["--panel", "--out", "--frames"])
        guard pos.isEmpty else { throw CLIError.usage("unexpected argument \(pos[0])") }
        guard let panel = o["--panel"] else { throw CLIError.usage("missing --panel") }
        let parts = panel.lowercased().split(separator: "x")
        guard parts.count == 2, let pw = Int(parts[0]), let ph = Int(parts[1]), pw > 0, ph > 0 else {
            throw CLIError.usage("--panel must look like 5120x2880")
        }
        guard let dir = o["--out"] else { throw CLIError.usage("missing --out") }
        let frames = try intOption(o, "--frames", default: 90)
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw CLIError.runtime("cannot create \(dir): \(error)")
        }
        let ladder = CandidateLadder.make(panelWidth: pw, panelHeight: ph)
        var runs: [CandidateRun] = []
        for (i, c) in ladder.enumerated() {
            progress("[\(i + 1)/\(ladder.count)] \(label(c.format))")
            let (result, sample) = EncodeBench.run(format: c.format, bitrate: c.bitrate, frameCount: frames)
            var file: String?
            if let sample, !sample.frames.isEmpty {
                let f = c.format
                let name = String(format: "%02d_%@_%dx%d_%d.msv", i, f.codec == .hevc ? "hevc" : "h264", f.width, f.height, f.fps)
                let path = (dir as NSString).appendingPathComponent(name)
                do {
                    try sample.write(to: URL(fileURLWithPath: path))
                    file = name
                } catch {
                    throw CLIError.runtime("cannot write \(path): \(error)")
                }
            }
            progress("    passed=\(result.passed) p95=\(String(format: "%.2f", result.p95Ms)) ms" +
                     (result.failureReason.map { " (\($0))" } ?? ""))
            runs.append(CandidateRun(candidate: c, encode: result, file: file))
        }
        return try render(runs)
    }

    struct DecodeEntry: Codable {
        var file: String
        var decode: BenchResult
    }

    struct DecodeAllReport: Codable {
        var caps: CapsReport
        var results: [DecodeEntry]
    }

    static func decodeAll(_ args: [String]) throws -> Data {
        guard args.count == 1, !args[0].hasPrefix("--") else { throw CLIError.usage("decode-all takes exactly one DIR") }
        let files = try listMSV(args[0])
        guard !files.isEmpty else { throw CLIError.runtime("no .msv files in \(args[0])") }
        let caps = ProbeReport.gatherCaps()
        var results: [DecodeEntry] = []
        for (i, url) in files.enumerated() {
            progress("[\(i + 1)/\(files.count)] \(url.lastPathComponent)")
            let sample: SampleFile
            do { sample = try SampleFile.read(from: url) } catch {
                throw CLIError.runtime("cannot read \(url.path): \(error)")
            }
            let r = DecodeBench.run(sample: sample)
            progress("    passed=\(r.passed) p95=\(String(format: "%.2f", r.p95Ms)) ms fps=\(String(format: "%.0f", r.throughputFps))" +
                     (r.failureReason.map { " (\($0))" } ?? ""))
            results.append(DecodeEntry(file: url.lastPathComponent, decode: r))
        }
        return try render(DecodeAllReport(caps: caps, results: results))
    }
}
