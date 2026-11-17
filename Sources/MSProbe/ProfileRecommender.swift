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
    /// Rate at which the train actually arrived (bytes received / arrival span), if measured.
    /// Provisional decision P1: on a deep-buffered link (hotspot) a train above capacity is queued, not
    /// dropped, so loss alone over-states throughput; the arrival rate does not.
    public var deliveryBps: Int?
    /// How much longer the train took to arrive than to send (ms): queueing in the path. nil = not measured.
    public var stretchMs: Double?

    public init(rateBps: Int, sent: Int, received: Int, jitterMs: Double, deliveryBps: Int? = nil,
                stretchMs: Double? = nil) {
        self.rateBps = rateBps
        self.sent = sent
        self.received = received
        self.jitterMs = jitterMs
        self.deliveryBps = deliveryBps
        self.stretchMs = stretchMs
    }

    /// Arrival span minus the send span of the packets received (ms).
    public static func stretchMs(received: Int, sent: Int, durationMs: Int, firstArrivalMicros: UInt64,
                                 lastArrivalMicros: UInt64) -> Double? {
        guard received >= 8, sent > 1, lastArrivalMicros > firstArrivalMicros else { return nil }
        let span = Double(lastArrivalMicros - firstArrivalMicros) / 1000
        return span - Double(durationMs) * Double(received - 1) / Double(sent)
    }

    /// Arrival rate from the Display's first/last arrival stamps; nil when too few packets for a span.
    public static func deliveryBps(received: Int, firstArrivalMicros: UInt64, lastArrivalMicros: UInt64,
                                   packetBytes: Int) -> Int? {
        guard received >= 8, lastArrivalMicros > firstArrivalMicros else { return nil }
        let span = Double(lastArrivalMicros - firstArrivalMicros) / 1e6
        // `received` and the stamps come from the peer: do the arithmetic in Double and clamp
        // (Int multiplication or Int(Double) of an absurd value would trap).
        let bps = Double(received - 1) * Double(packetBytes) * 8 / span
        guard bps.isFinite else { return nil }
        return Int(Swift.min(bps, Double(Int.max / 2)))
    }

    /// The rate this train shows the link can carry: the offered rate, or less if it arrived slower.
    public var effectiveBps: Int {
        guard let d = deliveryBps, d > 0 else { return rateBps }
        return Swift.min(rateBps, d)
    }

    /// The link could not keep up with this train (loss, or it arrived clearly slower than offered).
    public var saturated: Bool {
        loss >= LinkResult.maxUsableLoss || Double(effectiveBps) < LinkResult.saturationShare * Double(rateBps)
            || (stretchMs ?? 0) > LinkResult.maxStretchMs
    }

    public var loss: Double {
        guard sent > 0 else { return 1 }
        return Swift.max(0, 1 - Double(received) / Double(sent))
    }
}

/// Outcome of the UDP trains (PLAN section 6.10 step 3).
public struct LinkResult: Codable, Equatable {
    public static let maxUsableLoss = 0.01
    /// A train delivered below this share of its offered rate counts as saturated.
    public static let saturationShare = 0.8
    /// A train that arrives this much later than it was sent has hit a queue (RTT inflation).
    public static let maxStretchMs = 80.0

    public var trains: [LinkTrainResult]

    public init(trains: [LinkTrainResult]) { self.trains = trains }

    /// Highest usable rate over the trains with loss below 1 %; 0 if none. The lowest train counts at its
    /// offered rate (a short Wi-Fi stall stretches its arrival span without meaning anything); each faster
    /// train counts at its measured arrival rate (`effectiveBps`), but never below the next slower train's rate.
    public var usableThroughputBps: Int {
        let sorted = trains.sorted { $0.rateBps < $1.rateBps }
        var best = 0
        for (i, t) in sorted.enumerated() where t.loss < Self.maxUsableLoss {
            best = Swift.max(best, i == 0 ? t.rateBps : Swift.max(sorted[i - 1].rateBps, t.effectiveBps))
        }
        return best
    }

    /// The automatic link check stops here: loss, or (after the first train) clearly slower arrival than offered.
    public static func shouldStop(after t: LinkTrainResult, index: Int) -> Bool {
        t.loss >= maxUsableLoss || (index > 0 && t.saturated)
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
                                 interface: LinkInterface, requireBenchmarks: Bool = true) -> Recommendation {
        let throughput = link?.usableThroughputBps ?? 0
        var rejections: [Rejection] = []
        var chosen: Candidate?
        for o in outcomes {
            if let reason = rejectionReason(o, link: link, requireBenchmarks: requireBenchmarks) {
                rejections.append(Rejection(candidate: o.candidate, reason: reason))
            } else if chosen == nil {
                chosen = o.candidate
            }
        }
        return Recommendation(
            candidate: chosen,
            bitrate: chosen.map { startBitrate($0, throughputBps: throughput, hasLink: link != nil) } ?? 0,
            fecRatio: fecRatio(interface: interface, link: link),
            throughputBps: throughput,
            rejections: rejections)
    }

    /// start bitrate = min(profile bitrate, 0.6 x throughput) (PLAN 6.10 step 4), never below `minBitrate`.
    static func startBitrate(_ c: Candidate, throughputBps: Int, hasLink: Bool) -> Int {
        var b = c.bitrate
        if hasLink { b = Swift.min(b, Int(MSConstants.linkBudgetShare * Double(throughputBps))) }
        return Swift.max(MSConstants.minBitrate, b)
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
    static func rejectionReason(_ o: CandidateOutcome, link: LinkResult?, requireBenchmarks: Bool = true) -> String? {
        let f = o.candidate.format
        let interval = 1000.0 / Double(Swift.max(f.fps, 1))
        if let s = o.skipReason { return s }
        if o.candidate.manualOnly { return "manual selection only" }
        if f.codec == .h264 && (f.width > 4096 || f.height > 2304) {
            return "H.264 is not supported above 4096x2304"
        }
        if let link {
            let budget = MSConstants.linkBudgetShare * Double(link.usableThroughputBps)
            if Double(o.candidate.minBitrate) > budget {
                return String(format: "minimum bitrate %.1f Mbit/s exceeds link budget %.1f Mbit/s",
                              Double(o.candidate.minBitrate) / 1e6, budget / 1e6)
            }
        }
        if !requireBenchmarks && o.encode == nil && o.decode == nil { return nil }
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

/// Provisional decision P1 (PLAN 6.10): link-only recommendation used automatically at connect time.
/// Encode/decode benchmarks are not run (G1 measured that every HEVC ladder step passes on M2 -> iMac 5K);
/// only the link budget decides the step. HEVC only when both ends support it in hardware.
public enum LinkAwareProfile {
    public static func candidates(panelWidth: Int, panelHeight: Int, hevc: Bool) -> [Candidate] {
        let all = CandidateLadder.make(panelWidth: panelWidth, panelHeight: panelHeight).filter { !$0.manualOnly }
        let hevcOnly = all.filter { $0.format.codec == .hevc }
        return hevc && !hevcOnly.isEmpty ? hevcOnly : all
    }

    public static func recommend(panelWidth: Int, panelHeight: Int, hevc: Bool, link: LinkResult,
                                 interface: LinkInterface) -> Recommendation {
        let outcomes = candidates(panelWidth: panelWidth, panelHeight: panelHeight, hevc: hevc)
            .map { CandidateOutcome(candidate: $0) }
        return ProfileRecommender.recommend(outcomes: outcomes, link: link, interface: interface,
                                            requireBenchmarks: false)
    }

    /// Bitrate ceiling from a measured link: 0.6 x usable throughput (never below the global floor).
    public static func bitrateCap(throughputBps: Int) -> Int {
        Swift.max(MSConstants.minBitrate, Int(MSConstants.linkBudgetShare * Double(throughputBps)))
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
