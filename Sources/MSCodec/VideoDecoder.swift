import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import MSCore

/// State shared with VideoToolbox output handlers. Locks are never held across VideoToolbox calls.
private final class DecoderShared: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    func incrementPending() {
        lock.lock(); pending += 1; lock.unlock()
    }

    func decrementPending() {
        lock.lock(); if pending > 0 { pending -= 1 }; lock.unlock()
    }
}

public final class VideoDecoder {
    private static let log = Log.logger("codec")

    private let codec: Codec
    private let output: (CVPixelBuffer, UInt64, Double) -> Void
    private let shared = DecoderShared()

    // Guarded by `lock`; never held while calling VideoToolbox.
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentSets: [Data]?
    private var hardware = false

    public init(codec: Codec, output: @escaping (CVPixelBuffer, _ captureTimeMicros: UInt64, _ decodeMs: Double) -> Void) {
        self.codec = codec
        self.output = output
    }

    deinit { invalidate() }

    public var isHardwareAccelerated: Bool {
        lock.lock(); defer { lock.unlock() }
        return hardware
    }

    public var pendingFrames: Int { shared.pendingCount }

    // MARK: API

    public func decode(_ f: EncodedFrame) throws {
        let startMicros = MonoClock.nowMicros()

        if let sets = f.parameterSets {
            try updateSession(parameterSets: sets)
        }

        lock.lock()
        let s = session
        let desc = formatDescription
        lock.unlock()
        guard let s, let desc else { throw CodecError.missingParameterSets }

        let sample = try makeSampleBuffer(f, formatDescription: desc)
        let captureMicros = f.captureTimeMicros
        let shared = self.shared
        let output = self.output

        shared.incrementPending()
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            s, sampleBuffer: sample, flags: ._EnableAsynchronousDecompression, infoFlagsOut: &infoFlags
        ) { status, _, imageBuffer, pts, _ in
            defer { shared.decrementPending() }
            guard status == noErr, let image = imageBuffer else {
                VideoDecoder.log.error("decode failed or produced no image (\(status))")
                return
            }
            let micros = pts.isValid
                ? UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value))
                : captureMicros
            let decodeMs = Double(MonoClock.nowMicros() &- startMicros) / 1000.0
            output(image, micros, decodeMs)
        }
        if status != noErr {
            // The handler is not invoked when the call itself fails.
            shared.decrementPending()
            if status == kVTInvalidSessionErr {
                Self.log.error("decompression session invalidated by the system; dropping it")
                dropSession(ifEqualTo: s)
            } else {
                Self.log.error("DecodeFrame failed (\(status))")
            }
            throw CodecError.decodeFailed(status)
        }
    }

    public func flush() {
        lock.lock()
        let s = session
        lock.unlock()
        guard let s else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(s)
    }

    public func invalidate() {
        lock.lock()
        let s = session
        session = nil
        formatDescription = nil
        currentSets = nil
        hardware = false
        lock.unlock()
        guard let s else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(s)
        VTDecompressionSessionInvalidate(s)
    }

    // MARK: session management

    private func dropSession(ifEqualTo s: VTDecompressionSession) {
        lock.lock()
        let same = session.map { CFEqual($0, s) } ?? false
        if same {
            session = nil
            formatDescription = nil
            currentSets = nil
            hardware = false
        }
        lock.unlock()
        if same { VTDecompressionSessionInvalidate(s) }
    }

    private func updateSession(parameterSets sets: [Data]) throws {
        lock.lock()
        let existing = session
        let sameSets = currentSets == sets
        lock.unlock()
        if existing != nil && sameSets { return }

        let desc = try ParameterSets.makeFormatDescription(codec: codec, parameterSets: sets)

        if let existing, VTDecompressionSessionCanAcceptFormatDescription(existing, formatDescription: desc) {
            lock.lock()
            formatDescription = desc
            currentSets = sets
            lock.unlock()
            return
        }

        // Replace the session (or create the first one).
        invalidate()
        let (created, isHW) = try createSession(desc)
        lock.lock()
        session = created
        formatDescription = desc
        currentSets = sets
        hardware = isHW
        lock.unlock()
    }

    private func createSession(_ desc: CMVideoFormatDescription) throws -> (VTDecompressionSession, Bool) {
        var bits = 8
        if let ext = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber {
            bits = ext.intValue
        }
        let pixelFormat: OSType = bits == 10
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let destAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        func create(requireHardware: Bool) -> (VTDecompressionSession?, OSStatus) {
            let spec: [String: Any] = requireHardware
                ? [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true]
                : [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true]
            var s: VTDecompressionSession?
            let st = VTDecompressionSessionCreate(
                allocator: nil, formatDescription: desc, decoderSpecification: spec as CFDictionary,
                imageBufferAttributes: destAttrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
            return (s, st)
        }

        var (created, status) = create(requireHardware: true)
        if created == nil || status != noErr {
            Self.log.info("software decode fallback (hardware session failed: \(status))")
            (created, status) = create(requireHardware: false)
        }
        guard status == noErr, let s = created else {
            throw CodecError.sessionCreationFailed(status)
        }

        let rt = VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        if rt != noErr {
            Self.log.error("property RealTime rejected (\(rt))")
        }

        var value: Unmanaged<CFTypeRef>?
        let q = VTSessionCopyProperty(
            s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault, valueOut: &value)
        let isHW = q == noErr && (value?.takeRetainedValue() as? NSNumber)?.boolValue == true
        Self.log.info("decoder created \(self.codec.name) bits=\(bits) hardware=\(isHW)")
        return (s, isHW)
    }

    // MARK: sample buffer

    private func makeSampleBuffer(_ f: EncodedFrame, formatDescription: CMVideoFormatDescription) throws -> CMSampleBuffer {
        let n = f.data.count
        guard n > 0 else { throw CodecError.decodeFailed(OSStatus(kCMBlockBufferBadLengthParameterErr)) }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: n,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: n, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let bb = block else { throw CodecError.decodeFailed(status) }

        status = f.data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(kCMBlockBufferBadPointerParameterErr) }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb, offsetIntoDestination: 0, dataLength: n)
        }
        guard status == noErr else { throw CodecError.decodeFailed(status) }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(truncatingIfNeeded: f.captureTimeMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleSize = n
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard status == noErr, let sb = sample else { throw CodecError.decodeFailed(status) }
        return sb
    }
}
