import CoreVideo
import Foundation
import MSProtocol

/// Receives everything a `DisplaySession` wants to show. Called from internal queues; implementations hop as needed.
public protocol DisplaySink: AnyObject {
    func present(_ pixelBuffer: CVPixelBuffer, captureTimeMicros: UInt64)
    func showPairingCode(_ code: String, hostName: String)
    func hidePairingCode()
    /// "Allow <host>?" Call `completion` exactly once.
    func askAllow(hostName: String, completion: @escaping (Bool) -> Void)
    func sessionStarted(hostName: String)
    func sessionEnded()
    /// New cursor bitmap (control channel). Default: ignored.
    func cursorImage(_ image: CursorImageMessage)
    /// Latest cursor position (media channel, may be reordered or lost). Default: ignored.
    func cursorPosition(_ packet: CursorPacket)
    /// Host state change (control channel). Default: ignored.
    func hostState(_ state: HostStateMessage)
}

public extension DisplaySink {
    func cursorImage(_ image: CursorImageMessage) {}
    func cursorPosition(_ packet: CursorPacket) {}
    func hostState(_ state: HostStateMessage) {}
}
