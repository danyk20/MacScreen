import Foundation
import MSCore
import MSCodec
import MSProtocol

public struct ProbeProgress {
    public var fraction: Double
    public var message: String
}

public struct ProbeFailure: Error, CustomStringConvertible {
    public var message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

/// Settings for one setup test run (Host side).
public struct ProbeRunConfig {
    /// nil = the ladder for the Display's panel size.
    public var candidates: [Candidate]?
    public var encodeFrames = 90
    public var trainRatesBps = LinkProbe.defaultRatesBps
    public var trainDurationMs = LinkProbe.defaultTrainDurationMs
    /// Called on a background thread.
    public var onProgress: ((ProbeProgress) -> Void)?
    /// Called once on a background thread.
    public var onFinished: ((Result<ProbeOutcome, ProbeFailure>) -> Void)?

    public init() {}
}

/// Small blocking mailbox so the driver can run as straight-line code on a worker thread.
private final class Mailbox<T> {
    private let cond = NSCondition()
    private var items: [T] = []
    private var cancelled = false

    func put(_ v: T) {
        cond.lock(); items.append(v); cond.broadcast(); cond.unlock()
    }

    func cancel() {
        cond.lock(); cancelled = true; cond.broadcast(); cond.unlock()
    }

    /// Removes and returns the first item matching `match`; nil on timeout or cancel.
    func take(timeout: TimeInterval, where match: (T) -> Bool) -> T? {
        let end = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while true {
            if cancelled { return nil }
            if let i = items.firstIndex(where: match) { return items.remove(at: i) }
            if !cond.wait(until: end) { return nil }
        }
    }
}

/// Host side of the setup test: link trains, then per-candidate encode, `probeBlob`, Display decode.
/// `run` blocks; call it on a worker thread. Feed control messages in with `receive`.
public final class ProbeHostDriver {
    public struct Environment {
        public var sendControl: (ControlMessage) -> Void
        /// Opens the media channel to the Display's UDP port; call `mediaReady()` when it is up.
        public var openMedia: (UInt16) -> Void
        public var sendMedia: ([(PacketType, Data)], _ paceOverMicros: UInt64) -> Void

        public init(sendControl: @escaping (ControlMessage) -> Void, openMedia: @escaping (UInt16) -> Void,
                    sendMedia: @escaping ([(PacketType, Data)], UInt64) -> Void) {
            self.sendControl = sendControl
            self.openMedia = openMedia
            self.sendMedia = sendMedia
        }
    }

    private enum Event {
        case accept(UInt16)
        case mediaReady
        case link(LinkProbeResultMessage)
        case decode(Data)
    }

    private let env: Environment
    private let mailbox = Mailbox<Event>()
    private var cancelledFlag = false
    private let flagLock = NSLock()

    public init(environment: Environment) { env = environment }

    public func receive(_ m: ControlMessage) {
        switch m {
        case .sessionAccept(let a): mailbox.put(.accept(a.udpPort))
        case .linkProbeResult(let r): mailbox.put(.link(r))
        case .probeResult(let r): mailbox.put(.decode(r.json))
        default: break
        }
    }

    public func mediaReady() { mailbox.put(.mediaReady) }

    public func cancel() {
        flagLock.lock(); cancelledFlag = true; flagLock.unlock()
        mailbox.cancel()
    }

    private var isCancelled: Bool { flagLock.lock(); defer { flagLock.unlock() }; return cancelledFlag }

    private static func failed(_ f: VideoFormat, bitrate: Int, _ reason: String) -> BenchResult {
        BenchResult(format: f, bitrate: bitrate, frames: 0, hardware: false, meanMs: 0, p95Ms: 0, maxMs: 0,
                    throughputFps: 0, passed: false, failureReason: reason)
    }

    public func run(config: ProbeRunConfig, hostCaps: CapabilitiesMessage, displayCaps: CapabilitiesMessage,
                    displayId: String, interface: LinkInterface) -> Result<ProbeOutcome, ProbeFailure> {
        let candidates = config.candidates
            ?? CandidateLadder.make(panelWidth: displayCaps.panelPixelWidth, panelHeight: displayCaps.panelPixelHeight)
        let total = Double(config.trainRatesBps.count + candidates.count + 1)
        var done = 0.0
        func progress(_ msg: String) { config.onProgress?(ProbeProgress(fraction: Swift.min(done / total, 1), message: msg)) }

        // 1. Open the media channel (a zero-packet train asks the Display to listen).
        progress("Opening media channel")
        env.sendControl(.linkProbeStart(LinkProbeStartMessage(trainId: 0, rateBps: 0, durationMs: 0, packetCount: 0)))
        guard let port = mailbox.take(timeout: 10, where: { if case .accept = $0 { return true } else { return false } }),
              case .accept(let udpPort) = port else {
            return .failure(ProbeFailure(isCancelled ? "Cancelled" : "The Display did not open the media channel."))
        }
        env.openMedia(udpPort)
        guard mailbox.take(timeout: 10, where: { if case .mediaReady = $0 { return true } else { return false } }) != nil else {
            return .failure(ProbeFailure(isCancelled ? "Cancelled" : "The media channel did not come up."))
        }
        done += 1

        // 2. Link trains. Train 1 is a warm-up that is not counted.
        var trains: [LinkTrainResult] = []
        let warm = LinkProbe.startMessage(trainId: 1, rateBps: config.trainRatesBps.first ?? 10_000_000, durationMs: 100)
        _ = runTrain(warm)
        for (i, rate) in config.trainRatesBps.enumerated() {
            if isCancelled { return .failure(ProbeFailure("Cancelled")) }
            progress(String(format: "Measuring link at %d Mbit/s", rate / 1_000_000))
            let msg = LinkProbe.startMessage(trainId: UInt32(10 + i), rateBps: rate, durationMs: config.trainDurationMs)
            let r = runTrain(msg)
            trains.append(LinkTrainResult(rateBps: rate, sent: msg.packetCount, received: r?.received ?? 0,
                                          jitterMs: r?.jitterMs ?? 0))
            done += 1
        }
        let link = LinkResult(trains: trains)

        // 3. Candidates in order; stop at the first full pass.
        var outcomes: [CandidateOutcome] = []
        var recommendation = ProfileRecommender.recommend(outcomes: [], link: link, interface: interface)
        for c in candidates {
            if isCancelled { return .failure(ProbeFailure("Cancelled")) }
            let f = c.format
            progress("Testing \(f.codec.name) \(f.width)x\(f.height) @ \(f.fps) fps")
            defer { done += 1 }
            var o = CandidateOutcome(candidate: c)
            let encOK = f.codec == .hevc ? hostCaps.hwEncodeHEVC : hostCaps.hwEncodeH264
            let decOK = f.codec == .hevc ? displayCaps.hwDecodeHEVC : displayCaps.hwDecodeH264
            if !encOK {
                o.skipReason = "Host has no hardware \(f.codec.name) encoder"
            } else if !decOK {
                o.skipReason = "Display has no hardware \(f.codec.name) decoder"
            } else if Double(c.bitrate) > MSConstants.linkBudgetShare * Double(link.usableThroughputBps) {
                // The recommender names the reason; no point encoding.
            } else {
                let (enc, sample) = EncodeBench.run(format: f, bitrate: c.bitrate, frameCount: config.encodeFrames)
                o.encode = enc
                if enc.passed, let sample {
                    env.sendControl(.probeBlob(sample.serialize()))
                    if let ev = mailbox.take(timeout: 60, where: { if case .decode = $0 { return true } else { return false } }),
                       case .decode(let json) = ev,
                       let r = try? JSONDecoder().decode(BenchResult.self, from: json) {
                        o.decode = r
                    } else {
                        o.decode = Self.failed(f, bitrate: c.bitrate,
                                               isCancelled ? "Cancelled" : "Display did not answer the decode test")
                    }
                }
            }
            outcomes.append(o)
            recommendation = ProfileRecommender.recommend(outcomes: outcomes, link: link, interface: interface)
            if recommendation.candidate != nil { break }
        }
        if isCancelled { return .failure(ProbeFailure("Cancelled")) }
        done = total
        progress("Done")
        return .success(ProbeOutcome(displayId: displayId, displayName: displayCaps.deviceName, interface: interface,
                                     panelWidth: displayCaps.panelPixelWidth, panelHeight: displayCaps.panelPixelHeight,
                                     link: link, outcomes: outcomes, recommendation: recommendation))
    }

    private func runTrain(_ msg: LinkProbeStartMessage) -> LinkProbeResultMessage? {
        env.sendControl(.linkProbeStart(msg))
        env.sendMedia(LinkProbe.packets(trainId: msg.trainId, count: msg.packetCount),
                      UInt64(msg.durationMs) * 1000)
        let ev = mailbox.take(timeout: Double(msg.durationMs) / 1000 + 3) {
            if case .link(let r) = $0 { return r.trainId == msg.trainId } else { return false }
        }
        if case .link(let r)? = ev { return r }
        return nil
    }
}

/// Display side: decodes `probeBlob`s and measures link trains. Thread-safe entry points.
public final class ProbeResponder {
    private let sendControl: (ControlMessage) -> Void
    private let openMedia: () -> Void
    private let queue = DispatchQueue(label: "ms.probe.responder")
    private let benchQueue = DispatchQueue(label: "ms.probe.bench", qos: .userInitiated)
    private let receiver = LinkProbeReceiver()
    private var stopped = false

    public init(sendControl: @escaping (ControlMessage) -> Void, openMedia: @escaping () -> Void) {
        self.sendControl = sendControl
        self.openMedia = openMedia
    }

    /// Returns true if the message was a probe message and has been taken.
    @discardableResult
    public func handle(_ m: ControlMessage) -> Bool {
        switch m {
        case .probeBlob(let data):
            benchQueue.async { [weak self] in self?.decode(data) }
            return true
        case .linkProbeStart(let s):
            if s.packetCount == 0 { openMedia(); return true }
            queue.async { [weak self] in self?.expect(s) }
            return true
        default:
            return false
        }
    }

    /// Media queue.
    public func handleLinkPacket(_ payload: Data) {
        let at = MonoClock.nowMicros()
        guard let p = try? LinkProbePacket.decode(payload) else { return }
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.receiver.packet(p, at: at)
            if self.receiver.isComplete(p.trainId) { self.finish(p.trainId) }
        }
    }

    public func stop() { queue.async { [weak self] in self?.stopped = true } }

    private func expect(_ s: LinkProbeStartMessage) {
        guard !stopped else { return }
        receiver.expect(s)
        if receiver.isComplete(s.trainId) { finish(s.trainId); return }
        let wait = Double(s.durationMs) / 1000 + 0.4
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.finish(s.trainId) }
    }

    private func finish(_ id: UInt32) {
        guard !stopped, let r = receiver.finish(id) else { return }
        sendControl(.linkProbeResult(r))
    }

    private func decode(_ data: Data) {
        let result: BenchResult
        do {
            result = DecodeBench.run(sample: try SampleFile.parse(data))
        } catch {
            let f = VideoFormat(codec: .h264, width: 0, height: 0, fps: 1, bitDepth: 8)
            result = ProbeHostDriver.failedResult(f, "probe blob could not be parsed: \(error)")
        }
        if let json = try? JSONEncoder().encode(result) { sendControl(.probeResult(ProbeResultMessage(json: json))) }
    }
}

extension ProbeHostDriver {
    static func failedResult(_ f: VideoFormat, _ reason: String) -> BenchResult {
        failed(f, bitrate: 0, reason)
    }
}
