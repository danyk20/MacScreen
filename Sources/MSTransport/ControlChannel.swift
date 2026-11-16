import Foundation
import Network
import os
import MSCore
import MSProtocol

public enum ControlRole { case host, display }

public enum ControlCloseReason: Error, Equatable {
    case timeout
    case peerClosed
    case handshakeFailed(String)
    case protocolError(String)
    case localClose
    case network(String)
}

/// Framed, handshaken and encrypted TCP control channel (PLAN section 6.5).
/// All state is confined to `queue`; callbacks fire on it.
public final class ControlChannel {
    private static let log = Log.logger("transport")
    private static let tickInterval = 0.1

    private let connection: NWConnection
    private let role: ControlRole
    private let identity: Identity
    private let isKnownPeer: (Data) -> Bool
    private let queue: DispatchQueue

    public var onSecured: ((HandshakeResult) -> Void)?
    public var onMessage: ((ControlMessage) -> Void)?
    public var onClosed: ((ControlCloseReason) -> Void)?

    private let securedLock = NSLock()
    private var securedFlag = false
    public private(set) var isSecured: Bool {
        get { securedLock.lock(); defer { securedLock.unlock() }; return securedFlag }
        set { securedLock.lock(); securedFlag = newValue; securedLock.unlock() }
    }

    private let remoteHostLock = NSLock()
    private var remoteHostValue: NWEndpoint.Host?
    /// Peer address, set when the connection becomes ready.
    public var remoteHost: NWEndpoint.Host? {
        remoteHostLock.lock(); defer { remoteHostLock.unlock() }
        return remoteHostValue
    }

    private var started = false
    private var closed = false
    private var framer = ControlFramer()
    private var hostHandshake: HostHandshake?
    private var displayHandshake: DisplayHandshake?
    private var sealer: ControlSealer?
    private var opener: ControlOpener?
    private var timer: DispatchSourceTimer?
    private var startTime: Double = 0
    private var lastRx: Double = 0
    private var lastTx: Double = 0

    public init(connection: NWConnection, role: ControlRole, identity: Identity,
                isKnownPeer: @escaping (Data) -> Bool, queue: DispatchQueue) {
        self.connection = connection
        self.role = role
        self.identity = identity
        self.isKnownPeer = isKnownPeer
        self.queue = queue
    }

    public static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false
        return params
    }

    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: Public API

    public func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    public func send(_ message: ControlMessage) {
        queue.async { [weak self] in self?.sendOnQueue(message) }
    }

    public func close(_ reason: ControlCloseReason = .localClose) {
        queue.async { [weak self] in self?.finish(reason, sendBye: true) }
    }

    // MARK: Lifecycle

    private func startOnQueue() {
        guard !started, !closed else { return }
        started = true
        startTime = Self.now()
        lastRx = startTime
        lastTx = startTime

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        connection.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State) {
        guard !closed else { return }
        switch state {
        case .ready:
            var endpoint = connection.currentPath?.remoteEndpoint
            if case .hostPort = endpoint {} else { endpoint = connection.endpoint }
            if case let .hostPort(host, _)? = endpoint {
                remoteHostLock.lock(); remoteHostValue = host; remoteHostLock.unlock()
            }
            if role == .host {
                let hh = HostHandshake(identity: identity, isKnownPeer: isKnownPeer)
                hostHandshake = hh
                sendPlain(.hello(hh.makeHello()))
            } else {
                displayHandshake = DisplayHandshake(identity: identity, isKnownPeer: isKnownPeer)
            }
            receiveLoop()
        case .failed(let error):
            finish(.network(String(describing: error)), sendBye: false)
        case .cancelled:
            finish(.localClose, sendBye: false)
        default:
            break
        }
    }

    private func tick() {
        guard !closed else { return }
        let now = Self.now()
        if !isSecured {
            if now - startTime >= MSConstants.controlTimeoutS { finish(.timeout, sendBye: false) }
            return
        }
        if now - lastRx >= MSConstants.controlTimeoutS {
            finish(.timeout, sendBye: false)
            return
        }
        if now - lastTx >= MSConstants.controlKeepaliveS {
            sendOnQueue(.keepalive)
        }
    }

    private func finish(_ reason: ControlCloseReason, sendBye: Bool) {
        guard !closed else { return }
        closed = true
        if sendBye, isSecured, let sealer = sealer,
           let body = try? ControlMessage.bye(ByeMessage(reason: "\(reason)")).encodeBody(),
           let sealed = try? sealer.seal(body) {
            let frame = ControlFramer.frame(typeCode: ControlMessage.bye(ByeMessage(reason: "")).typeCode, body: sealed)
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let cb = onClosed
        onClosed = nil
        onSecured = nil
        onMessage = nil
        hostHandshake = nil
        displayHandshake = nil
        cb?(reason)
    }

    // MARK: Sending

    private func sendPlain(_ message: ControlMessage) {
        guard !closed else { return }
        do {
            let body = try message.encodeBody()
            write(ControlFramer.frame(typeCode: message.typeCode, body: body))
        } catch {
            finish(.protocolError("encode failed: \(error)"), sendBye: false)
        }
    }

    private func sendOnQueue(_ message: ControlMessage) {
        guard !closed else { return }
        guard !message.isHandshake else {
            Self.log.error("dropping handshake message sent through public send")
            return
        }
        guard isSecured, let sealer = sealer else {
            Self.log.error("dropping control message \(message.typeCode) sent before channel secured")
            return
        }
        do {
            let sealed = try sealer.seal(try message.encodeBody())
            write(ControlFramer.frame(typeCode: message.typeCode, body: sealed))
        } catch {
            finish(.protocolError("seal failed: \(error)"), sendBye: false)
        }
    }

    private func write(_ frame: Data) {
        lastTx = Self.now()
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let error = error, let self = self else { return }
            self.finish(.network(String(describing: error)), sendBye: false)
        })
    }

    // MARK: Receiving

    private func receiveLoop() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            self?.didReceive(data: data, isComplete: isComplete, error: error)
        }
    }

    private func didReceive(data: Data?, isComplete: Bool, error: NWError?) {
        guard !closed else { return }
        if let data = data, !data.isEmpty {
            lastRx = Self.now()
            framer.append(data)
            do {
                while !closed, let frame = try framer.next() {
                    handleFrame(typeCode: frame.typeCode, body: frame.body)
                }
            } catch {
                finish(.protocolError("framing: \(error)"), sendBye: false)
            }
            if closed { return }
        }
        if let error = error {
            finish(.network(String(describing: error)), sendBye: false)
        } else if isComplete {
            finish(.peerClosed, sendBye: false)
        } else {
            receiveLoop()
        }
    }

    private func handleFrame(typeCode: UInt8, body: Data) {
        if !isSecured {
            let message: ControlMessage
            do { message = try ControlMessage.decode(typeCode: typeCode, body: body) } catch {
                finish(.protocolError("decode: \(error)"), sendBye: false)
                return
            }
            guard message.isHandshake else {
                finish(.protocolError("non-handshake frame \(typeCode) before handshake finished"), sendBye: false)
                return
            }
            handleHandshake(message)
            return
        }
        if typeCode >= 1 && typeCode <= 4 {
            finish(.protocolError("handshake frame after handshake"), sendBye: false)
            return
        }
        guard let opener = opener else { return }
        let message: ControlMessage
        do {
            let plain = try opener.open(body)
            message = try ControlMessage.decode(typeCode: typeCode, body: plain)
        } catch {
            finish(.protocolError("open/decode: \(error)"), sendBye: false)
            return
        }
        switch message {
        case .keepalive: break
        case .bye: finish(.peerClosed, sendBye: false)
        default: onMessage?(message)
        }
    }

    private func handleHandshake(_ message: ControlMessage) {
        do {
            switch (role, message) {
            case (.host, .helloReply(let r)):
                guard let hh = hostHandshake else { throw HandshakeError.wrongState }
                sendPlain(.reveal(try hh.handleHelloReply(r)))
            case (.host, .revealReply(let r)):
                guard let hh = hostHandshake else { throw HandshakeError.wrongState }
                secure(try hh.handleRevealReply(r))
            case (.display, .hello(let h)):
                guard let dh = displayHandshake else { throw HandshakeError.wrongState }
                sendPlain(.helloReply(try dh.handleHello(h)))
            case (.display, .reveal(let r)):
                guard let dh = displayHandshake else { throw HandshakeError.wrongState }
                let (reply, result) = try dh.handleReveal(r)
                sendPlain(.revealReply(reply))
                secure(result)
            default:
                finish(.protocolError("unexpected handshake message \(message.typeCode)"), sendBye: false)
            }
        } catch {
            finish(.handshakeFailed(String(describing: error)), sendBye: false)
        }
    }

    private func secure(_ result: HandshakeResult) {
        guard !closed else { return }
        switch role {
        case .host:
            sealer = ControlSealer(key: result.keys.ctlH2D)
            opener = ControlOpener(key: result.keys.ctlD2H)
        case .display:
            sealer = ControlSealer(key: result.keys.ctlD2H)
            opener = ControlOpener(key: result.keys.ctlH2D)
        }
        hostHandshake = nil
        displayHandshake = nil
        isSecured = true
        let now = Self.now()
        lastRx = now
        lastTx = now
        onSecured?(result)
    }
}
