import CoreVideo
import XCTest

/// Creates an IOSurface-backed NV12 (video range) buffer: constant luma per frame plus a moving vertical bar.
func makeNV12(width: Int, height: Int, frameIndex: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    let st = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                 attrs as CFDictionary, &pb)
    guard st == kCVReturnSuccess, let buf = pb else {
        XCTFail("CVPixelBufferCreate failed \(st)")
        preconditionFailure("no pixel buffer")
    }
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    let luma = UInt8(16 + (frameIndex * 7) % 200)
    if let y = CVPixelBufferGetBaseAddressOfPlane(buf, 0) {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let barX = (frameIndex * 16) % max(width - 32, 1)
        for row in 0..<height {
            let p = y.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for col in 0..<width { p[col] = luma }
            for col in barX..<min(barX + 32, width) { p[col] = 235 }
        }
    }
    if let c = CVPixelBufferGetBaseAddressOfPlane(buf, 1) {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        for row in 0..<(height / 2) {
            let p = c.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for i in 0..<width { p[i] = 128 }
        }
    }
    return buf
}
