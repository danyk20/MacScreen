import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import MSCore

/// State shared with VideoToolbox output handlers. Locks are never held across VideoToolbox calls.
private final class EncoderShared: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var keyframeRequested = true   // the first frame is always a keyframe
    let output: (EncodedFrame) -> Void
    let codec: Codec

    init(codec: Codec, output: @escaping (EncodedFrame) -> Void) {
        self.codec = codec
        self.output = output
    }

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

    func requestKeyframe() {
        lock.lock(); keyframeRequested = true; lock.unlock()
    }

    func takeKeyframeRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let v = keyframeRequested
        keyframeRequested = false
        return v
    }
}

public final class VideoEncoder {
    private static let log = Log.logger("codec")

    private let format: VideoFormat
    private let colour: ColourPlan
    private let shared: EncoderShared
    private let sessionLock = NSLock()
    private var session: VTCompressionSession?
    public private(set) var usesLowLatencyRateControl: Bool = false

    public init(format: VideoFormat, bitrate: Int, colour: ColourPlan = .srgb,
                output: @escaping (EncodedFrame) -> Void) throws {
        guard format.bitDepth == 8 || format.bitDepth == 10 else {
            throw CodecError.unsupportedFormat("bit depth \(format.bitDepth)")
        }
        if format.bitDepth == 10 && format.codec != .hevc {
            throw CodecError.unsupportedFormat("10-bit requires HEVC")
        }
        guard format.width > 0, format.height > 0, format.fps > 0 else {
            throw CodecError.unsupportedFormat("invalid dimensions or fps")
        }
        self.format = format
        self.colour = colour
        self.shared = EncoderShared(codec: format.codec, output: output)

        let pixelFormat: OSType = format.bitDepth == 10
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let sourceAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: format.width,
            kCVPixelBufferHeightKey as String: format.height,
        ]

        func create(lowLatency: Bool) -> (VTCompressionSession?, OSStatus) {
            var spec: [String: Any] = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
            ]
            if lowLatency {
                spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true
            }
            var s: VTCompressionSession?
            let st = VTCompressionSessionCreate(
                allocator: nil, width: Int32(format.width), height: Int32(format.height),
                codecType: format.codec.cmType, encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: sourceAttrs as CFDictionary, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            return (s, st)
        }

        // Measured on Apple M2 (macOS 27): with low-latency rate control the HEVC hardware encoder
        // takes ~21 ms per 4K frame and rejects the speed-priority property; without it ~12 ms, still
        // one frame in / one frame out. H.264 is the opposite: ~20 ms with it, ~75 ms without.
        // So low-latency rate control is requested for H.264 only.
        let wantLowLatency = format.codec == .h264
        var (created, status) = create(lowLatency: wantLowLatency)
        if created != nil && status == noErr {
            usesLowLatencyRateControl = wantLowLatency
        } else if wantLowLatency {
            Self.log.info("low-latency rate control session failed (\(status)); retrying without it")
            (created, status) = create(lowLatency: false)
            usesLowLatencyRateControl = false
        }
        guard status == noErr, let s = created else {
            throw CodecError.sessionCreationFailed(status)
        }
        Self.log.info("encoder created \(format.codec.name) \(format.width)x\(format.height) lowLatency=\(self.usesLowLatencyRateControl)")
        session = s

        configure(s, bitrate: bitrate)
        let prep = VTCompressionSessionPrepareToEncodeFrames(s)
        if prep != noErr {
            Self.log.error("PrepareToEncodeFrames failed (\(prep))")
        }
    }

    deinit { invalidate() }

    // MARK: properties

    private func setProperty(_ s: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) {
        let st = VTSessionSetProperty(s, key: key, value: value)
        if st != noErr {
            Self.log.error("property \(key as String) rejected (\(st))")
        }
    }

    private func configure(_ s: VTCompressionSession, bitrate: Int) {
        setProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        setProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        let profile: CFString
        switch format.codec {
        case .hevc: profile = format.bitDepth == 10 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        case .h264: profile = kVTProfileLevel_H264_High_AutoLevel
        }
        setProperty(s, kVTCompressionPropertyKey_ProfileLevel, profile)
        setProperty(s, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        setProperty(s, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: format.fps))
        setProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 36000))
        setProperty(s, kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        setProperty(s, kVTCompressionPropertyKey_ColorPrimaries, colour.vuiPrimaries)
        setProperty(s, kVTCompressionPropertyKey_TransferFunction, colour.vuiTransfer)
        setProperty(s, kVTCompressionPropertyKey_YCbCrMatrix, colour.vuiMatrix)
        if #available(macOS 13.0, *) {
            setProperty(s, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        }
    }

    // MARK: API

    public var pendingFrames: Int { shared.pendingCount }

    public func setBitrate(_ bps: Int) {
        sessionLock.lock()
        let s = session
        sessionLock.unlock()
        guard let s else { return }
        setProperty(s, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bps))
    }

    public func requestKeyframe() { shared.requestKeyframe() }

    public func encode(_ pb: CVPixelBuffer, captureTimeMicros: UInt64) {
        sessionLock.lock()
        let s = session
        sessionLock.unlock()
        guard let s else { return }

        let pts = CMTime(value: Int64(truncatingIfNeeded: captureTimeMicros), timescale: 1_000_000)
        let duration = CMTime(value: Int64(1_000_000 / max(format.fps, 1)), timescale: 1_000_000)
        var props: CFDictionary?
        if shared.takeKeyframeRequest() {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }

        let shared = self.shared
        shared.incrementPending()
        let status = VTCompressionSessionEncodeFrame(
            s, imageBuffer: pb, presentationTimeStamp: pts, duration: duration,
            frameProperties: props, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            VideoEncoder.handleOutput(shared: shared, status: status, sampleBuffer: sampleBuffer)
        }
        if status != noErr {
            // The handler is not invoked when the call itself fails.
            shared.decrementPending()
            Self.log.debug("EncodeFrame failed (\(status))")
        }
    }

    public func invalidate() {
        sessionLock.lock()
        let s = session
        session = nil
        sessionLock.unlock()
        guard let s else { return }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(s)
    }

    // MARK: output

    private static func handleOutput(shared: EncoderShared, status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        defer { shared.decrementPending() }
        guard status == noErr, let sb = sampleBuffer else {
            log.debug("frame dropped or failed (\(status))")
            return
        }
        guard CMSampleBufferDataIsReady(sb), let block = CMSampleBufferGetDataBuffer(sb) else {
            log.debug("sample has no data")
            return
        }

        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool, notSync {
            isKey = false
        }

        var sets: [Data]?
        if isKey {
            guard let desc = CMSampleBufferGetFormatDescription(sb),
                  let extracted = try? ParameterSets.extract(from: desc, codec: shared.codec) else {
                log.error("keyframe without parameter sets; dropped")
                return
            }
            sets = extracted
        }

        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copyStatus: OSStatus = data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(kCMBlockBufferBadPointerParameterErr) }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copyStatus == noErr else {
            log.error("block buffer copy failed (\(copyStatus))")
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let micros = pts.isValid
            ? UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value))
            : 0
        shared.output(EncodedFrame(data: data, parameterSets: sets, isKeyframe: isKey, captureTimeMicros: micros))
    }
}
