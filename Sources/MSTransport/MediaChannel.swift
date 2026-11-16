import Foundation
import Network
import CryptoKit
import os
import MSCore
import MSProtocol

// MARK: - Public API

public struct MediaCounters: Equatable {
    public var packetsSent: UInt64 = 0
    public var bytesSent: UInt64 = 0
    public var packetsReceived: UInt64 = 0
    public var bytesReceived: UInt64 = 0
    public var authFailures: UInt64 = 0
    public var replays: UInt64 = 0
    public var sendErrors: UInt64 = 0
    /// Packets missing from the receive counter sequence (gaps), minus late arrivals. Pre-FEC network loss.
    public var packetsLost: UInt64 = 0
    public init() {}
}

public protocol MediaChannel: AnyObject {
    /// Called on the channel queue with the decrypted inner payload.
    var onPacket: ((PacketType, Data) -> Void)? { get set }
    /// Any thread.
    func send(_ type: PacketType, _ payload: Data)
    /// Sends items in order, spread evenly over at most `paceOverMicros` (0 = immediately). Any thread.
    func sendBatch(_ items: [(PacketType, Data)], paceOverMicros: UInt64)
    var counters: MediaCounters { get }
    func close()
}

public enum MediaParameters {
    public static func udp() -> NWParameters {
        let p = NWParameters.udp
        p.serviceClass = .interactiveVideo
        p.includePeerToPeer = false
        p.allowLocalEndpointReuse = true
        return p
    }
}

// MARK: - Shared core

private final class UnfairLock {
    private let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    init() { p.initialize(to: os_unfair_lock()) }
    deinit { p.deinitialize(count: 1); p.deallocate() }
    @inline(__always) func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(p)
        defer { os_unfair_lock_unlock(p) }
        return body()
    }
}

/// Sealing, opening, pacing and counters shared by client and server.
/// All mutable state except `counters`, `onPacket` and `closed` is confined to `queue`.
private final class MediaCore {
    static let sliceSize = 16

    let queue: DispatchQueue
    private let sealer: PacketSealer
    private let opener: PacketOpener
    private let log = Log.logger("media")

    private let lock = UnfairLock()
    private var _counters = MediaCounters()
    private var _onPacket: ((PacketType, Data) -> Void)?
    private var _closed = false

    /// Evaluated on `queue`: the connection to send on, or nil.
    var target: () -> NWConnection? = { nil }
    /// Called on `queue` when a packet authenticated on a connection.
    var onAuthenticated: ((NWConnection) -> Void)?

    // Pacing state (queue only).
    private struct Slice { var due: UInt64; var datagrams: [Data] }
    private var fifo: [Slice] = []
    private var lastDue: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var timerResumed = false

    private var lastDropLog: UInt64 = 0
    private var highestCounter: UInt64 = 0   // queue only

    init(sealKey: SymmetricKey, openKey: SymmetricKey, queue: DispatchQueue) {
        sealer = PacketSealer(key: sealKey)
        opener = PacketOpener(key: openKey)
        self.queue = queue
    }

    // MARK: thread-safe state

    var counters: MediaCounters { lock.withLock { _counters } }
    var onPacket: ((PacketType, Data) -> Void)? {
        get { lock.withLock { _onPacket } }
        set { lock.withLock { _onPacket = newValue } }
    }
    var isClosed: Bool { lock.withLock { _closed } }
    @inline(__always) private func bump(_ f: (inout MediaCounters) -> Void) { lock.withLock { f(&_counters) } }

    /// Marks closed; returns false if it already was.
    func markClosed() -> Bool {
        lock.withLock {
            if _closed { return false }
            _closed = true
            return true
        }
    }

    // MARK: send

    func send(_ type: PacketType, _ payload: Data) {
        guard !isClosed else { return }
        guard let d = seal(type, payload) else { return }
        queue.async { [weak self] in self?.enqueue([Slice(due: 0, datagrams: [d])]) }
    }

    func sendBatch(_ items: [(PacketType, Data)], paceOverMicros: UInt64) {
        guard !isClosed, !items.isEmpty else { return }
        var datagrams: [Data] = []
        datagrams.reserveCapacity(items.count)
        for (t, p) in items { if let d = seal(t, p) { datagrams.append(d) } }
        guard !datagrams.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            if datagrams.count <= MediaCore.sliceSize || paceOverMicros == 0 {
                self.enqueue([Slice(due: 0, datagrams: datagrams)])
                return
            }
            let n = (datagrams.count + MediaCore.sliceSize - 1) / MediaCore.sliceSize
            let step = paceOverMicros / UInt64(n)
            var slices: [Slice] = []
            slices.reserveCapacity(n)
            for i in 0..<n {
                let lo = i * MediaCore.sliceSize
                let hi = min(lo + MediaCore.sliceSize, datagrams.count)
                slices.append(Slice(due: UInt64(i) * step, datagrams: Array(datagrams[lo..<hi])))
            }
            self.enqueue(slices)
        }
    }

    private func seal(_ type: PacketType, _ payload: Data) -> Data? {
        do { return try sealer.seal(type: type.rawValue, payload: payload) } catch {
            bump { $0.sendErrors += 1 }
            return nil
        }
    }

    /// Queue only. `Slice.due` is an offset from now in microseconds.
    private func enqueue(_ slices: [Slice]) {
        guard !isClosed else { return }
        let now = MonoClock.nowMicros()
        let wasEmpty = fifo.isEmpty
        for s in slices {
            // Never earlier than anything already queued: order is preserved.
            let due = max(now &+ s.due, lastDue)
            lastDue = due
            fifo.append(Slice(due: due, datagrams: s.datagrams))
        }
        if wasEmpty { drain() }
    }

    private func drain() {
        guard !isClosed else { return }
        let now = MonoClock.nowMicros()
        var sent = 0
        while sent < fifo.count, fifo[sent].due <= now {
            emit(fifo[sent].datagrams)
            sent += 1
        }
        if sent > 0 { fifo.removeFirst(sent) }
        guard let next = fifo.first else { return }
        armTimer(afterMicros: next.due - now)
    }

    private func armTimer(afterMicros us: UInt64) {
        let t: DispatchSourceTimer
        if let existing = timer {
            t = existing
        } else {
            t = DispatchSource.makeTimerSource(flags: [], queue: queue)
            t.setEventHandler { [weak self] in self?.drain() }
            timer = t
        }
        t.schedule(deadline: .now() + .nanoseconds(Int(min(us, 10_000_000) * 1000)),
                   repeating: .never, leeway: .nanoseconds(0))
        if !timerResumed { timerResumed = true; t.resume() }
    }

    private func emit(_ datagrams: [Data]) {
        guard let conn = target() else {
            bump { $0.sendErrors += UInt64(datagrams.count) }
            return
        }
        var bytes: UInt64 = 0
        conn.batch {
            for d in datagrams {
                bytes += UInt64(d.count)
                conn.send(content: d, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.bump { $0.sendErrors += 1 } }
                })
            }
        }
        let n = UInt64(datagrams.count)
        bump { $0.packetsSent += n; $0.bytesSent += bytes }
    }

    // MARK: receive

    /// Starts a receive loop on `conn` (call on `queue`).
    func startReceiving(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self = self, let conn = conn, !self.isClosed else { return }
            if let data = data, !data.isEmpty { self.handle(data, from: conn) }
            if error == nil { self.startReceiving(on: conn) }
        }
    }

    private func handle(_ datagram: Data, from conn: NWConnection) {
        do {
            let r = try opener.open(datagram)
            guard let type = PacketType(rawValue: r.type) else { return }
            let counter = r.counter
            let advance: UInt64 = counter > highestCounter ? counter - highestCounter - 1 : 0
            if counter > highestCounter { highestCounter = counter }
            let late = counter < highestCounter
            bump {
                $0.packetsReceived += 1
                $0.bytesReceived += UInt64(datagram.count)
                $0.packetsLost += advance
                if late, $0.packetsLost > 0 { $0.packetsLost -= 1 }
            }
            onAuthenticated?(conn)
            onPacket?(type, r.payload)
        } catch CipherError.replayed {
            bump { $0.replays += 1 }
            noteDrop("replay")
        } catch {
            bump { $0.authFailures += 1 }
            noteDrop("auth/format failure")
        }
    }

    private func noteDrop(_ what: String) {
        let now = MonoClock.nowMicros()
        if now &- lastDropLog >= 1_000_000 {
            lastDropLog = now
            log.debug("dropped datagram: \(what, privacy: .public)")
        }
    }

    /// Queue only; cancels the pacing timer and drops pending slices.
    func shutdownOnQueue() {
        fifo.removeAll()
        if let t = timer {
            t.setEventHandler {}
            t.cancel()
            timer = nil
        }
    }
}

// MARK: - Client (Host side)

public final class MediaClient: MediaChannel {
    private let core: MediaCore
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var started = false

    public var onReady: (() -> Void)?
    public var onFailed: ((String) -> Void)?

    public var onPacket: ((PacketType, Data) -> Void)? {
        get { core.onPacket }
        set { core.onPacket = newValue }
    }
    public var counters: MediaCounters { core.counters }

    public init(host: NWEndpoint.Host, port: UInt16, sealKey: SymmetricKey, openKey: SymmetricKey,
                queue: DispatchQueue, requiredInterfaceType: NWInterface.InterfaceType? = nil) {
        let params = MediaParameters.udp()
        if let t = requiredInterfaceType { params.requiredInterfaceType = t }
        let p = NWEndpoint.Port(rawValue: port) ?? .any
        connection = NWConnection(host: host, port: p, using: params)
        core = MediaCore(sealKey: sealKey, openKey: openKey, queue: queue)
        self.queue = queue
        let conn = connection
        core.target = { conn }
    }

    deinit { connection.cancel() }

    public func start() {
        queue.async { [weak self] in
            guard let self = self, !self.started, !self.core.isClosed else { return }
            self.started = true
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self = self, !self.core.isClosed else { return }
                switch state {
                case .ready:
                    self.onReady?()
                case .failed(let e):
                    self.onFailed?("\(e)")
                case .waiting(let e):
                    self.onFailed?("waiting: \(e)")
                default: break
                }
            }
            self.connection.start(queue: self.queue)
            self.core.startReceiving(on: self.connection)
        }
    }

    public func send(_ type: PacketType, _ payload: Data) { core.send(type, payload) }

    public func sendBatch(_ items: [(PacketType, Data)], paceOverMicros: UInt64) {
        core.sendBatch(items, paceOverMicros: paceOverMicros)
    }

    public func close() {
        guard core.markClosed() else { return }
        let conn = connection
        queue.async { [core] in
            core.shutdownOnQueue()
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
    }
}

// MARK: - Server (Display side)

public final class MediaServer: MediaChannel {
    private static let maxCandidates = 4

    private let core: MediaCore
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var candidates: [NWConnection] = []   // oldest first; queue only
    private var active: NWConnection?             // queue only
    private let portLock = UnfairLock()
    private var _port: UInt16?

    public var onListening: ((UInt16) -> Void)?
    public var onPacket: ((PacketType, Data) -> Void)? {
        get { core.onPacket }
        set { core.onPacket = newValue }
    }
    public var counters: MediaCounters { core.counters }
    public var port: UInt16? { portLock.withLock { _port } }

    public init(sealKey: SymmetricKey, openKey: SymmetricKey, queue: DispatchQueue) {
        core = MediaCore(sealKey: sealKey, openKey: openKey, queue: queue)
        self.queue = queue
        core.target = { [weak self] in self?.active }
        core.onAuthenticated = { [weak self] conn in self?.active = conn }
    }

    deinit {
        listener?.cancel()
        for c in candidates { c.cancel() }
    }

    public func start() throws {
        let l = try NWListener(using: MediaParameters.udp(), on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self = self, let l = l else { return }
            if case .ready = state, let p = l.port?.rawValue {
                self.portLock.withLock { self._port = p }
                self.onListening?(p)
            }
        }
        l.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        // Runs on `queue` (listener queue).
        guard !core.isClosed else { conn.cancel(); return }
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn else { return }
            switch state {
            case .failed, .cancelled: self.forget(conn)
            default: break
            }
        }
        candidates.append(conn)
        while candidates.count > MediaServer.maxCandidates {
            // Evict the oldest candidate that is not the active return path.
            let idx = candidates.firstIndex(where: { $0 !== active }) ?? 0
            let old = candidates.remove(at: idx)
            if old === active { active = nil }
            old.cancel()
        }
        conn.start(queue: queue)
        core.startReceiving(on: conn)
    }

    private func forget(_ conn: NWConnection) {
        candidates.removeAll { $0 === conn }
        if active === conn { active = nil }
    }

    public func send(_ type: PacketType, _ payload: Data) { core.send(type, payload) }

    public func sendBatch(_ items: [(PacketType, Data)], paceOverMicros: UInt64) {
        core.sendBatch(items, paceOverMicros: paceOverMicros)
    }

    public func close() {
        guard core.markClosed() else { return }
        queue.async { [weak self, core] in
            core.shutdownOnQueue()
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            for c in self.candidates { c.stateUpdateHandler = nil; c.cancel() }
            self.candidates.removeAll()
            self.active = nil
        }
    }
}
