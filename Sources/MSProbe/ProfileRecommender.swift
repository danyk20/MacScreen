import Foundation
import MSCore
import MSCodec

/// Interface type of the control connection (decides the FEC default).
public enum LinkInterface: String, Codable, CaseIterable {
    case wired, wifi, other
}

public struct LinkTrainResult: Codable, Equatable {
    public var rateBps: Int
    public var sent: Int
    public var received: Int
    public var jitterMs: Double

    public init(rateBps: Int, sent: Int, received: Int, jitterMs: Double) {
        self.rateBps = rateBps
        self.sent = sent
        self.received = received
        self.jitterMs = jitterMs
    }

    public var loss: Double {
        guard sent > 0 else { return 1 }
        return Swift.max(0, 1 - Double(received) / Double(sent))
    }
}

/// Outcome of the UDP trains (PLAN section 6.10 step 3).
public struct LinkResult: Codable, Equatable {
    public static let maxUsableLoss = 0.01

    public var trains: [LinkTrainResult]

    public init(trains: [LinkTrainResult]) { self.trains = trains }

    /// Highest train rate with loss below 1 %; 0 if none.
    public var usableThroughputBps: Int {
        trains.filter { $0.loss < Self.maxUsableLoss }.map { $0.rateBps }.max() ?? 0
    }

    /// Loss of the train that defines `usableThroughputBps` (0 if there is none).
    public var lossAtUsableRate: Double {
        trains.filter { $0.loss < Self.maxUsableLoss }.max { $0.rateBps < $1.rateBps }?.loss ?? 0
    }

    public var maxJitterMs: Double { trains.map { $0.jitterMs }.max() ?? 0 }
}

/// Everything measured for one candidate. `encode`/`decode` are nil when that step was not run.
public struct CandidateOutcome: Codable {
    public var candidate: Candidate
    public var encode: BenchResult?
    public var decode: BenchResult?
    /// Set when the candidate was not benchmarked at all (for example no hardware decoder on the Display).
    public var skipReason: String?

    public init(candidate: Candidate, encode: BenchResult? = nil, decode: BenchResult? = nil, skipReason: String? = nil) {
        self.candidate = candidate
        self.encode = encode
        self.decode = decode
        self.skipReason = skipReason
    }
}

public struct Rejection: Codable, Equatable {
    public var candidate: Candidate
    public var reason: String
}

public struct Recommendation: Codable {
    /// nil when no candidate passed.
    public var candidate: Candidate?
    public var bitrate: Int
    public var fecRatio: Double
    public var throughputBps: Int
    public var rejections: [Rejection]
}

/// Pure decision function of PLAN section 6.10 step 4.
public enum ProfileRecommender {
    public static func recommend(outcomes: [CandidateOutcome], link: LinkResult?,
                                 interface: LinkInterface) -> Recommendation {
        let throughput = link?.usableThroughputBps ?? 0
        var rejections: [Rejection] = []
        var chosen: Candidate?
        for o in outcomes {
            if let reason = rejectionReason(o, link: link) {
                rejections.append(Rejection(candidate: o.candidate, reason: reason))
            } else if chosen == nil {
                chosen = o.candidate
            }
        }
        return Recommendation(
            candidate: chosen,
            bitrate: chosen.map { Swift.max(MSConstants.minBitrate, $0.bitrate) } ?? 0,
            fecRatio: fecRatio(interface: interface, link: link),
            throughputBps: throughput,
            rejections: rejections)
    }

    /// FEC default: wired and lossless gets the wired default; anything else the Wi-Fi default,
    /// plus one step per 0.5 % of loss measured at the usable rate (capped).
    public static func fecRatio(interface: LinkInterface, link: LinkResult?) -> Double {
        let loss = link?.lossAtUsableRate ?? 0
        var fec = interface == .wired ? MSConstants.fecRatioWired : MSConstants.fecRatioWiFi
        if loss > 0 { fec = Swift.max(fec, MSConstants.fecRatioWiFi) }
        if loss >= 0.005 { fec += MSConstants.fecRatioStep * Double(Int(loss / 0.005)) }
        return Swift.min(fec, MSConstants.fecRatioMax)
    }

    /// nil = the candidate passes every rule.
    static func rejectionReason(_ o: CandidateOutcome, link: LinkResult?) -> String? {
        let f = o.candidate.format
        let interval = 1000.0 / Double(Swift.max(f.fps, 1))
        if let s = o.skipReason { return s }
        if f.codec == .h264 && (f.width > 4096 || f.height > 2304) {
            return "H.264 is not supported above 4096x2304"
        }
        if let link {
            let budget = MSConstants.linkBudgetShare * Double(link.usableThroughputBps)
            if Double(o.candidate.bitrate) > budget {
                return String(format: "bitrate %.1f Mbit/s exceeds link budget %.1f Mbit/s",
                              Double(o.candidate.bitrate) / 1e6, budget / 1e6)
            }
        }
        guard let enc = o.encode else { return "encode benchmark not run" }
        if enc.frames == 0 || !enc.passed {
            return "encode failed: \(enc.failureReason ?? "no frames")"
        }
        if enc.p95Ms >= BenchRules.encodeP95Share * interval {
            return String(format: "encode p95 %.2f ms is not below %.2f ms", enc.p95Ms,
                          BenchRules.encodeP95Share * interval)
        }
        guard let dec = o.decode else { return "decode benchmark not run" }
        if !dec.passed { return "decode failed: \(dec.failureReason ?? "unknown")" }
        if !dec.hardware { return "Display decoder is not hardware accelerated" }
        if dec.p95Ms >= BenchRules.decodeP95Share * interval {
            return String(format: "decode p95 %.2f ms is not below %.2f ms", dec.p95Ms,
                          BenchRules.decodeP95Share * interval)
        }
        if dec.throughputFps < BenchRules.decodeThroughputFactor * Double(f.fps) {
            return String(format: "decode throughput %.1f fps is below %.1f fps", dec.throughputFps,
                          BenchRules.decodeThroughputFactor * Double(f.fps))
        }
        return nil
    }
}

public extension Recommendation {
    /// Stores the recommendation as AppSettings defaults. `panelHeight` is the Display's panel height;
    /// the height is snapped to the settings options (0 = native). No-op when nothing was recommended.
    func apply(to settings: AppSettings, panelHeight: Int) -> AppSettings {
        guard let c = candidate else { return settings }
        var s = settings
        let h = c.format.height
        if h >= panelHeight {
            s.maxHeight = 0
        } else {
            let options = AppSettings.heightOptions.filter { $0 > 0 }.sorted()
            s.maxHeight = options.last { $0 <= h } ?? options.first ?? 0
        }
        s.fps = c.format.fps
        s.codec = c.format.codec == .h264 ? "h264" : "hevc"
        s.bitrateCapMbps = 0     // automatic = the profile bitrate of the chosen format
        s.fecRatio = fecRatio
        return s.sanitized()
    }
}
