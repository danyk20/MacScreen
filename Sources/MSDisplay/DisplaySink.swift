import CoreVideo
import Foundation

/// Receives everything a `DisplaySession` wants to show. Called from internal queues; implementations hop as needed.
public protocol DisplaySink: AnyObject {
    func present(_ pixelBuffer: CVPixelBuffer, captureTimeMicros: UInt64)
    func showPairingCode(_ code: String, hostName: String)
    func hidePairingCode()
    /// "Allow <host>?" Call `completion` exactly once.
    func askAllow(hostName: String, completion: @escaping (Bool) -> Void)
    func sessionStarted(hostName: String)
    func sessionEnded()
}
