import CoreVideo
import Foundation
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
    let luma = Int32(16 + (frameIndex * 7) % 200)
    if let y = CVPixelBufferGetBaseAddressOfPlane(buf, 0) {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let barX = (frameIndex * 16) % max(width - 64, 1)
        let barW = min(64, max(width - barX, 0))
        for row in 0..<height {
            let p = y.advanced(by: row * stride)
            memset(p, luma, width)
            memset(p.advanced(by: barX), 235, barW)
        }
    }
    if let c = CVPixelBufferGetBaseAddressOfPlane(buf, 1) {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        for row in 0..<(height / 2) {
            memset(c.advanced(by: row * stride), 128, width)
        }
    }
    return buf
}

/// Mean of plane 0, sampling every 8th pixel in both directions.
func meanLuma(_ pb: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return 0 }
    let w = CVPixelBufferGetWidthOfPlane(pb, 0)
    let h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    var sum = 0
    var n = 0
    for row in Swift.stride(from: 0, to: h, by: 8) {
        let p = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
        for col in Swift.stride(from: 0, to: w, by: 8) {
            sum += Int(p[col])
            n += 1
        }
    }
    return n > 0 ? Double(sum) / Double(n) : 0
}
