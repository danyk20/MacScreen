import Foundation
import MSCore

public enum ControlMessageError: Error, Equatable {
    case unknownType(UInt8)
    case malformed(String)
    case frameTooLarge(Int)
}

public struct WireVideoFormat: Codable, Equatable {
    /// 1 = h264, 2 = hevc
    public var codec: UInt8
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitDepth: Int

    public init(codec: UInt8, width: Int, height: Int, fps: Int, bitDepth: Int) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitDepth = bitDepth
    }
}

public struct CapabilitiesMessage: Codable, Equatable {
    /// "host" or "display"
    public var role: String
    public var deviceName: String
    public var osVersion: String
    public var panelPixelWidth: Int
    public var panelPixelHeight: Int
    public var panelWidthMM: Double
    public var panelHeightMM: Double
    public var backingScale: Double
    public var edrHeadroom: Double
    public var refreshHz: Double
    public var hwDecodeH264: Bool
    public var hwDecodeHEVC: Bool
    public var hwEncodeH264: Bool
    public var hwEncodeHEVC: Bool
    public var wideColor: Bool

    public init(role: String, deviceName: String, osVersion: String,
                panelPixelWidth: Int, panelPixelHeight: Int,
                panelWidthMM: Double, panelHeightMM: Double,
                backingScale: Double, edrHeadroom: Double, refreshHz: Double,
                hwDecodeH264: Bool, hwDecodeHEVC: Bool, hwEncodeH264: Bool, hwEncodeHEVC: Bool,
                wideColor: Bool) {
        self.role = role
        self.deviceName = deviceName
        self.osVersion = osVersion
        self.panelPixelWidth = panelPixelWidth
        self.panelPixelHeight = panelPixelHeight
        self.panelWidthMM = panelWidthMM
        self.panelHeightMM = panelHeightMM
        self.backingScale = backingScale
        self.edrHeadroom = edrHeadroom
        self.refreshHz = refreshHz
        self.hwDecodeH264 = hwDecodeH264
        self.hwDecodeHEVC = hwDecodeHEVC
        self.hwEncodeH264 = hwEncodeH264
        self.hwEncodeHEVC = hwEncodeHEVC
        self.wideColor = wideColor
    }
}

/// Host to Display: "the user typed the right code".
public struct PairConfirmMessage: Codable, Equatable {
    public init() {}
}

/// Display to Host: user clicked Allow or Deny.
public struct PairResultMessage: Codable, Equatable {
    public var accepted: Bool
    public init(accepted: Bool) { self.accepted = accepted }
}

/// Opaque BenchResult JSON.
public struct ProbeResultMessage: Codable, Equatable {
    public var json: Data
    public init(json: Data) { self.json = json }
}

public struct LinkProbeStartMessage: Codable, Equatable {
    public var trainId: UInt32
    public var rateBps: Int
    public var durationMs: Int
    public var packetCount: Int

    public init(trainId: UInt32, rateBps: Int, durationMs: Int, packetCount: Int) {
        self.trainId = trainId
        self.rateBps = rateBps
        self.durationMs = durationMs
        self.packetCount = packetCount
    }
}

public struct LinkProbeResultMessage: Codable, Equatable {
    public var trainId: UInt32
    public var received: Int
    public var firstArrivalMicros: UInt64
    public var lastArrivalMicros: UInt64
    public var jitterMs: Double

    public init(trainId: UInt32, received: Int, firstArrivalMicros: UInt64,
                lastArrivalMicros: UInt64, jitterMs: Double) {
        self.trainId = trainId
        self.received = received
        self.firstArrivalMicros = firstArrivalMicros
        self.lastArrivalMicros = lastArrivalMicros
        self.jitterMs = jitterMs
    }
}

public struct SessionRequestMessage: Codable, Equatable {
    public var format: WireVideoFormat
    public var hiDPI: Bool
    /// "overlay" or "embedded"
    public var cursorMode: String
    public var audio: Bool
    public var fecRatio: Double

    public init(format: WireVideoFormat, hiDPI: Bool, cursorMode: String, audio: Bool, fecRatio: Double) {
        self.format = format
        self.hiDPI = hiDPI
        self.cursorMode = cursorMode
        self.audio = audio
        self.fecRatio = fecRatio
    }
}

public struct SessionAcceptMessage: Codable, Equatable {
    public var udpPort: UInt16
    public init(udpPort: UInt16) { self.udpPort = udpPort }
}

public struct ReconfigureMessage: Codable, Equatable {
    public var format: WireVideoFormat
    public init(format: WireVideoFormat) { self.format = format }
}

public struct CursorImageMessage: Codable, Equatable {
    public var id: UInt16
    public var png: Data
    public var hotX: Double
    public var hotY: Double
    public var widthPt: Double
    public var heightPt: Double

    public init(id: UInt16, png: Data, hotX: Double, hotY: Double, widthPt: Double, heightPt: Double) {
        self.id = id
        self.png = png
        self.hotX = hotX
        self.hotY = hotY
        self.widthPt = widthPt
        self.heightPt = heightPt
    }
}

public struct HostStateMessage: Codable, Equatable {
    public var displayAsleep: Bool
    public var mirroring: Bool
    public init(displayAsleep: Bool, mirroring: Bool) {
        self.displayAsleep = displayAsleep
        self.mirroring = mirroring
    }
}

public struct ByeMessage: Codable, Equatable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

public enum ControlMessage: Equatable {
    case hello(HelloMessage)
    case helloReply(HelloReplyMessage)
    case reveal(RevealMessage)
    case revealReply(RevealReplyMessage)
    case pairConfirm(PairConfirmMessage)
    case pairResult(PairResultMessage)
    case capabilities(CapabilitiesMessage)
    case probeResult(ProbeResultMessage)
    case linkProbeStart(LinkProbeStartMessage)
    case linkProbeResult(LinkProbeResultMessage)
    case sessionRequest(SessionRequestMessage)
    case sessionAccept(SessionAcceptMessage)
    case reconfigure(ReconfigureMessage)
    case cursorImage(CursorImageMessage)
    case hostState(HostStateMessage)
    case keepalive
    case bye(ByeMessage)
    case probeBlob(Data)

    public var typeCode: UInt8 {
        switch self {
        case .hello: return 1
        case .helloReply: return 2
        case .reveal: return 3
        case .revealReply: return 4
        case .pairConfirm: return 10
        case .pairResult: return 11
        case .capabilities: return 12
        case .probeResult: return 13
        case .linkProbeStart: return 14
        case .linkProbeResult: return 15
        case .sessionRequest: return 16
        case .sessionAccept: return 17
        case .reconfigure: return 18
        case .cursorImage: return 19
        case .hostState: return 20
        case .keepalive: return 21
        case .bye: return 22
        case .probeBlob: return 0x80
        }
    }

    /// Types 1 to 4.
    public var isHandshake: Bool { typeCode >= 1 && typeCode <= 4 }

    public func encodeBody() throws -> Data {
        let enc = JSONEncoder()
        switch self {
        case .hello(let m): return try enc.encode(m)
        case .helloReply(let m): return try enc.encode(m)
        case .reveal(let m): return try enc.encode(m)
        case .revealReply(let m): return try enc.encode(m)
        case .pairConfirm(let m): return try enc.encode(m)
        case .pairResult(let m): return try enc.encode(m)
        case .capabilities(let m): return try enc.encode(m)
        case .probeResult(let m): return try enc.encode(m)
        case .linkProbeStart(let m): return try enc.encode(m)
        case .linkProbeResult(let m): return try enc.encode(m)
        case .sessionRequest(let m): return try enc.encode(m)
        case .sessionAccept(let m): return try enc.encode(m)
        case .reconfigure(let m): return try enc.encode(m)
        case .cursorImage(let m): return try enc.encode(m)
        case .hostState(let m): return try enc.encode(m)
        case .keepalive: return Data()
        case .bye(let m): return try enc.encode(m)
        case .probeBlob(let d): return d
        }
    }

    public static func decode(typeCode: UInt8, body: Data) throws -> ControlMessage {
        let dec = JSONDecoder()
        func json<T: Decodable>(_ t: T.Type) throws -> T {
            do { return try dec.decode(t, from: body) } catch {
                throw ControlMessageError.malformed("type \(typeCode): \(error)")
            }
        }
        switch typeCode {
        case 1: return .hello(try json(HelloMessage.self))
        case 2: return .helloReply(try json(HelloReplyMessage.self))
        case 3: return .reveal(try json(RevealMessage.self))
        case 4: return .revealReply(try json(RevealReplyMessage.self))
        case 10: return .pairConfirm(try json(PairConfirmMessage.self))
        case 11: return .pairResult(try json(PairResultMessage.self))
        case 12: return .capabilities(try json(CapabilitiesMessage.self))
        case 13: return .probeResult(try json(ProbeResultMessage.self))
        case 14: return .linkProbeStart(try json(LinkProbeStartMessage.self))
        case 15: return .linkProbeResult(try json(LinkProbeResultMessage.self))
        case 16: return .sessionRequest(try json(SessionRequestMessage.self))
        case 17: return .sessionAccept(try json(SessionAcceptMessage.self))
        case 18: return .reconfigure(try json(ReconfigureMessage.self))
        case 19: return .cursorImage(try json(CursorImageMessage.self))
        case 20: return .hostState(try json(HostStateMessage.self))
        case 21: return .keepalive
        case 22: return .bye(try json(ByeMessage.self))
        case 0x80: return .probeBlob(body)
        default: throw ControlMessageError.unknownType(typeCode)
        }
    }
}

/// TCP framing: `u32 length | u8 type | body`, length counts the type byte plus the body.
public struct ControlFramer {
    public static let maxFrameLength = 64 * 1024 * 1024

    private var buffer = Data()
    private var offset = 0

    public init() {}

    public static func frame(typeCode: UInt8, body: Data) -> Data {
        var w = ByteWriter(capacity: body.count + 5)
        w.u32(UInt32(truncatingIfNeeded: body.count + 1))
        w.u8(typeCode)
        w.bytes(body)
        return w.data
    }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete frame, or nil if more bytes are needed.
    public mutating func next() throws -> (typeCode: UInt8, body: Data)? {
        let avail = buffer.count - offset
        guard avail >= 4 else { return nil }
        let base = buffer.startIndex + offset
        var hr = ByteReader(buffer.subdata(in: base..<(base + 4)))
        let len = Int(try hr.u32())
        guard len >= 1 else { throw ControlMessageError.malformed("zero-length frame") }
        guard len <= ControlFramer.maxFrameLength else { throw ControlMessageError.frameTooLarge(len) }
        guard avail >= 4 + len else { return nil }
        let type = buffer[base + 4]
        let body = buffer.subdata(in: (base + 5)..<(base + 4 + len))
        offset += 4 + len
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.count < 1 << 20)
            offset = 0
        } else if offset > 1 << 20 && offset > buffer.count / 2 {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset))
            offset = 0
        }
        return (type, body)
    }
}
