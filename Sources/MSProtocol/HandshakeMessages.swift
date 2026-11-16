import Foundation

/// Plaintext handshake messages (PLAN §6.5, control types 1–4). `Data` fields encode as base64.
public struct HelloMessage: Codable, Equatable {
    public var v: UInt8
    public var deviceId: String
    public var deviceName: String
    public var identityKey: Data
    public var commit: Data

    public init(v: UInt8, deviceId: String, deviceName: String, identityKey: Data, commit: Data) {
        self.v = v
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.identityKey = identityKey
        self.commit = commit
    }
}

public struct HelloReplyMessage: Codable, Equatable {
    public var v: UInt8
    public var deviceId: String
    public var deviceName: String
    public var identityKey: Data
    public var ephKey: Data
    public var nonce: Data
    public var knowsPeer: Bool

    public init(v: UInt8, deviceId: String, deviceName: String, identityKey: Data,
                ephKey: Data, nonce: Data, knowsPeer: Bool) {
        self.v = v
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.identityKey = identityKey
        self.ephKey = ephKey
        self.nonce = nonce
        self.knowsPeer = knowsPeer
    }
}

public struct RevealMessage: Codable, Equatable {
    public var ephKey: Data
    public var nonce: Data
    public var signature: Data

    public init(ephKey: Data, nonce: Data, signature: Data) {
        self.ephKey = ephKey
        self.nonce = nonce
        self.signature = signature
    }
}

public struct RevealReplyMessage: Codable, Equatable {
    public var signature: Data

    public init(signature: Data) {
        self.signature = signature
    }
}
