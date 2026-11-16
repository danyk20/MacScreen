import Foundation
import CoreVideo
import CoreGraphics
import CoreText
import MSCore

public enum TestPatternError: Error {
    case invalidSize
    case poolCreationFailed(CVReturn)
    case bufferCreationFailed(CVReturn)
    case stripRenderingFailed
    case lockFailed(CVReturn)
}

/// Deterministic synthetic desktop-like frames (bands, scrolling text, moving bar, colour thirds).
public final class TestPattern {
    public let width: Int
    public let height: Int
    public let bitDepth: Int
    public var pixelFormat: OSType {
        bitDepth == 10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                       : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private static let stripRows = 200
    private static let barWidth = 96
    private static let bandHeight = 16
    private static let bandValues: [UInt8] = [40, 90, 60, 130, 80, 150, 50, 110, 70, 170, 100, 60]
    private static let chromaValues: [UInt8] = [96, 128, 160]

    private let pool: CVPixelBufferPool
    private let stripRowCount: Int
    // 8-bit sources
    private var strip8: [UInt8] = []
    // 10-bit sources (already shifted into the high bits)
    private var strip16: [UInt16] = []
    private var bandRows16: [[UInt16]] = []
    private var bar16: [UInt16] = []
    private var chromaRows16: [[UInt16]] = []

    public init(width: Int, height: Int, bitDepth: Int = 8) throws {
        guard width >= 2, height >= 2, bitDepth == 8 || bitDepth == 10 else { throw TestPatternError.invalidSize }
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.stripRowCount = Swift.min(Self.stripRows, height)

        let format: OSType = bitDepth == 10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var p: CVPixelBufferPool?
        let rc = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        guard rc == kCVReturnSuccess, let created = p else { throw TestPatternError.poolCreationFailed(rc) }
        pool = created

        strip8 = try Self.renderStrip(width: width, rows: stripRowCount)
        if bitDepth == 10 {
            strip16 = strip8.map(Self.to10bitHigh)
            bandRows16 = Self.bandValues.map { [UInt16](repeating: Self.to10bitHigh($0), count: width) }
            bar16 = [UInt16](repeating: Self.to10bitHigh(235), count: Self.barWidth)
            let pairs = (width + 1) / 2 * 2
            chromaRows16 = Self.chromaValues.map { [UInt16](repeating: Self.to10bitHigh($0), count: pairs) }
        }
    }

    /// 8-bit video-range value to a 10-bit sample stored in the high bits of a 16-bit word.
    private static func to10bitHigh(_ v: UInt8) -> UInt16 {
        let ten = (UInt16(v) << 2) | (UInt16(v) >> 6)
        return ten << 6
    }

    private static func renderStrip(width: Int, rows: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * rows)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: rows, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: rows))
            let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.setStrokeColor(gray: 0, alpha: 1)
            let text = "The quick brown fox jumps over the lazy dog 0123456789 "
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: String(repeating: text, count: Swift.max(1, width / 380 + 1)), attributes: attrs))
            var y = CGFloat(rows) - 18
            var n = 0
            while y > 0 {
                ctx.textPosition = CGPoint(x: CGFloat(4 + (n % 5) * 7), y: y)
                CTLineDraw(line, ctx)
                y -= 17
                n += 1
            }
            return true
        }
        guard ok else { throw TestPatternError.stripRenderingFailed }
        // Map full-range grey to video-range luma.
        for i in 0..<bytes.count { bytes[i] = UInt8(16 + Int(bytes[i]) * 219 / 255) }
        return bytes
    }

    private static func mod(_ a: Int, _ m: Int) -> Int { ((a % m) + m) % m }

    public func frame(_ index: Int) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let rc = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard rc == kCVReturnSuccess, let pb = out else { throw TestPatternError.bufferCreationFailed(rc) }
        let lr = CVPixelBufferLockBaseAddress(pb, [])
        guard lr == kCVReturnSuccess else { throw TestPatternError.lockFailed(lr) }
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else {
            throw TestPatternError.bufferCreationFailed(kCVReturnError)
        }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let sample = bitDepth == 10 ? 2 : 1
        let bands = Self.bandValues.count

        // (a) bands, scrolling 2 rows per frame
        for y in 0..<height {
            let blk = Self.mod((y + 2 * index) / Self.bandHeight, bands)
            let row = lumaBase + y * lumaStride
            if bitDepth == 10 {
                bandRows16[blk].withUnsafeBytes { _ = memcpy(row, $0.baseAddress, width * 2) }
            } else {
                memset(row, Int32(Self.bandValues[blk]), width)
            }
        }
        // (b) text strip, moving 4 rows per frame, wrapping
        let offset = Self.mod(4 * index, height)
        for r in 0..<stripRowCount {
            let dst = lumaBase + ((offset + r) % height) * lumaStride
            if bitDepth == 10 {
                strip16.withUnsafeBytes { _ = memcpy(dst, $0.baseAddress! + r * width * 2, width * 2) }
            } else {
                strip8.withUnsafeBytes { _ = memcpy(dst, $0.baseAddress! + r * width, width) }
            }
        }
        // (c) bright bar, 16 px per frame
        let bx = Self.mod(16 * index, width)
        let bw = Swift.min(Self.barWidth, width - bx)
        for y in 0..<height {
            let dst = lumaBase + y * lumaStride + bx * sample
            if bitDepth == 10 {
                bar16.withUnsafeBytes { _ = memcpy(dst, $0.baseAddress, bw * 2) }
            } else {
                memset(dst, 235, bw)
            }
        }
        // (d) chroma thirds
        let chromaRowsCount = CVPixelBufferGetHeightOfPlane(pb, 1)
        for y in 0..<chromaRowsCount {
            let third = Swift.min(2, y * 3 / Swift.max(chromaRowsCount, 1))
            let row = chromaBase + y * chromaStride
            if bitDepth == 10 {
                chromaRows16[third].withUnsafeBytes { _ = memcpy(row, $0.baseAddress, Swift.min($0.count, chromaStride)) }
            } else {
                memset(row, Int32(Self.chromaValues[third]), Swift.min((width + 1) / 2 * 2, chromaStride))
            }
        }
        return pb
    }
}
