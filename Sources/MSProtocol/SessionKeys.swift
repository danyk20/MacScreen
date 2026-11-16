import Foundation
import CryptoKit

public struct SessionKeys {
    public let ctlH2D: SymmetricKey
    public let ctlD2H: SymmetricKey
    public let medH2D: SymmetricKey
    public let medD2H: SymmetricKey

    public init(ctlH2D: SymmetricKey, ctlD2H: SymmetricKey, medH2D: SymmetricKey, medD2H: SymmetricKey) {
        self.ctlH2D = ctlH2D
        self.ctlD2H = ctlD2H
        self.medH2D = medH2D
        self.medD2H = medD2H
    }
}

public struct HandshakeResult {
    public let keys: SessionKeys
    public let peerIdentityKey: Data
    public let peerDeviceId: String
    public let peerDeviceName: String
    public let transcript: Data
    public let pairingCode: String
    public let peerWasKnown: Bool

    public init(keys: SessionKeys, peerIdentityKey: Data, peerDeviceId: String, peerDeviceName: String,
                transcript: Data, pairingCode: String, peerWasKnown: Bool) {
        self.keys = keys
        self.peerIdentityKey = peerIdentityKey
        self.peerDeviceId = peerDeviceId
        self.peerDeviceName = peerDeviceName
        self.transcript = transcript
        self.pairingCode = pairingCode
        self.peerWasKnown = peerWasKnown
    }
}

public struct Identity {
    public let deviceId: String
    public var deviceName: String
    public let signingKey: Curve25519.Signing.PrivateKey

    public init(deviceId: String, deviceName: String, signingKey: Curve25519.Signing.PrivateKey) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.signingKey = signingKey
    }

    public var publicKey: Data { signingKey.publicKey.rawRepresentation }
}
