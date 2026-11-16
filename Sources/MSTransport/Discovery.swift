import Foundation
import Network
import os
import MSCore

public struct DiscoveredDisplay: Equatable, Hashable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint

    public init(id: String, name: String, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
    }
}

/// Display side: advertises `_macscreen._tcp` and accepts control connections.
public final class DisplayAdvertiser {
    private static let log = Log.logger("transport")

    private let deviceId: String
    private let deviceName: String
    private let queue: DispatchQueue
    private var listener: NWListener?
    private let portLock = NSLock()
    private var portValue: UInt16?

    public var onConnection: ((NWConnection) -> Void)?
    public var onStateChange: ((Bool) -> Void)?

    public init(deviceId: String, deviceName: String, queue: DispatchQueue) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.queue = queue
    }

    public var port: UInt16? {
        portLock.lock(); defer { portLock.unlock() }
        return portValue
    }

    private func setPort(_ p: UInt16?) {
        portLock.lock(); portValue = p; portLock.unlock()
    }

    public func start() throws {
        guard listener == nil else { return }
        let l = try NWListener(using: ControlChannel.tcpParameters(), on: .any)
        var txt = NWTXTRecord()
        txt["id"] = deviceId
        txt["name"] = deviceName
        txt["v"] = String(MSConstants.protoVersion)
        l.service = NWListener.Service(name: deviceName, type: MSConstants.bonjourType, txtRecord: txt)
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.setPort(l?.port?.rawValue)
                self.onStateChange?(true)
            case .failed(let e):
                Self.log.error("listener failed: \(String(describing: e))")
                self.setPort(nil)
                self.onStateChange?(false)
            case .cancelled:
                self.setPort(nil)
                self.onStateChange?(false)
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let cb = self?.onConnection else {
                conn.cancel()
                return
            }
            cb(conn)
        }
        listener = l
        l.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// Host side: browses for Displays.
public final class DisplayBrowser {
    private static let log = Log.logger("transport")

    private let queue: DispatchQueue
    private var browser: NWBrowser?

    public var onChange: (([DiscoveredDisplay]) -> Void)?

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    public func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: MSConstants.bonjourType, domain: nil),
                          using: ControlChannel.tcpParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results)
        }
        b.stateUpdateHandler = { state in
            if case .failed(let e) = state {
                Self.log.error("browser failed: \(String(describing: e))")
            }
        }
        browser = b
        b.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var out: [DiscoveredDisplay] = []
        for r in results {
            guard case .bonjour(let txt) = r.metadata,
                  let id = txt["id"], !id.isEmpty,
                  let v = txt["v"], v == String(MSConstants.protoVersion) else { continue }
            var name = txt["name"] ?? ""
            if name.isEmpty, case .service(let n, _, _, _) = r.endpoint { name = n }
            out.append(DiscoveredDisplay(id: id, name: name, endpoint: r.endpoint))
        }
        out.sort { ($0.name, $0.id) < ($1.name, $1.id) }
        onChange?(out)
    }
}
