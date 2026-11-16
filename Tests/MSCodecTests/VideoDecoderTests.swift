import XCTest
import CoreVideo
import CoreMedia
@testable import MSCodec

final class VideoDecoderTests: XCTestCase {
    private final class Box<T> {
        private let lock = NSLock()
        private var items: [T] = []
        func add(_ t: T) { lock.lock(); items.append(t); lock.unlock() }
        var snapshot: [T] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private struct Out {
        var buffer: CVPixelBuffer
        var micros: UInt64
        var ms: Double
    }

    private func fmt(_ c: Codec, _ w: Int = 1920, _ h: Int = 1080) -> VideoFormat {
        VideoFormat(codec: c, width: w, height: h, fps: 60, bitDepth: 8)
    }

    private func ts(_ i: Int) -> UInt64 { UInt64(1_000_000 + i * 16_667) }

    /// Encodes `count` frames and returns them with their source mean luma.
    private func encode(_ codec: Codec, width: Int = 1920, height: Int = 1080, count: Int,
                        keyframeAt: Int? = nil) throws -> (frames: [EncodedFrame], luma: [Double]) {
        let exp = expectation(description: "encode \(codec.name)")
        exp.expectedFulfillmentCount = count
        let box = Box<EncodedFrame>()
        let enc = try VideoEncoder(format: fmt(codec, width, height), bitrate: 8_000_000) { f in
            box.add(f); exp.fulfill()
        }
        defer { enc.invalidate() }
        var luma: [Double] = []
        for i in 0..<count {
            if i == keyframeAt { enc.requestKeyframe() }
            let pb = makeNV12(width: width, height: height, frameIndex: i)
            luma.append(meanLuma(pb))
            enc.encode(pb, captureTimeMicros: ts(i))
        }
        wait(for: [exp], timeout: 10)
        return (box.snapshot, luma)
    }

    private func roundTrip(_ codec: Codec, viaPayload: Bool) throws {
        let (frames, luma) = try encode(codec, count: 30)
        XCTAssertEqual(frames.count, 30)

        let exp = expectation(description: "decode \(codec.name)")
        exp.expectedFulfillmentCount = 30
        let box = Box<Out>()
        let dec = VideoDecoder(codec: codec) { pb, micros, ms in
            box.add(Out(buffer: pb, micros: micros, ms: ms)); exp.fulfill()
        }
        defer { dec.invalidate() }
        XCTAssertFalse(dec.isHardwareAccelerated)
        for f in frames {
            var input = f
            if viaPayload {
                let payload = FramePayload.encode(f)
                input = try FramePayload.decode(payload, isKeyframe: f.isKeyframe, captureTimeMicros: f.captureTimeMicros)
            }
            try dec.decode(input)
        }
        wait(for: [exp], timeout: 10)
        dec.flush()
        XCTAssertEqual(dec.pendingFrames, 0)
        XCTAssertTrue(dec.isHardwareAccelerated)

        let outs = box.snapshot
        XCTAssertEqual(outs.count, 30)
        XCTAssertEqual(outs.map { $0.micros }, (0..<30).map { ts($0) })
        for (i, o) in outs.enumerated() {
            XCTAssertEqual(CVPixelBufferGetWidth(o.buffer), 1920)
            XCTAssertEqual(CVPixelBufferGetHeight(o.buffer), 1080)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(o.buffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            XCTAssertNotNil(CVPixelBufferGetIOSurface(o.buffer))
            XCTAssertGreaterThan(o.ms, 0)
            XCTAssertEqual(meanLuma(o.buffer), luma[i], accuracy: 3, "frame \(i)")
        }
    }

    func testRoundTripHEVC() throws { try roundTrip(.hevc, viaPayload: false) }
    func testRoundTripH264() throws { try roundTrip(.h264, viaPayload: false) }
    func testRoundTripThroughPayloadHEVC() throws { try roundTrip(.hevc, viaPayload: true) }
    func testRoundTripThroughPayloadH264() throws { try roundTrip(.h264, viaPayload: true) }

    func testNonKeyframeFirstThrows() throws {
        for codec in Codec.allCases {
            let (frames, _) = try encode(codec, count: 3)
            let dec = VideoDecoder(codec: codec) { _, _, _ in }
            defer { dec.invalidate() }
            XCTAssertThrowsError(try dec.decode(frames[1])) { error in
                guard case CodecError.missingParameterSets = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
            XCTAssertEqual(dec.pendingFrames, 0)
        }
    }

    func testMidStreamFormatChange() throws {
        for codec in Codec.allCases {
            let a = try encode(codec, width: 1920, height: 1080, count: 10)
            let b = try encode(codec, width: 1280, height: 720, count: 10)
            let exp = expectation(description: "decode \(codec.name)")
            exp.expectedFulfillmentCount = 20
            let box = Box<Out>()
            let dec = VideoDecoder(codec: codec) { pb, micros, ms in
                box.add(Out(buffer: pb, micros: micros, ms: ms)); exp.fulfill()
            }
            defer { dec.invalidate() }
            for f in a.frames + b.frames { try dec.decode(f) }
            wait(for: [exp], timeout: 10)
            dec.flush()
            let outs = box.snapshot
            XCTAssertEqual(outs.filter { CVPixelBufferGetWidth($0.buffer) == 1920 && CVPixelBufferGetHeight($0.buffer) == 1080 }.count, 10)
            XCTAssertEqual(outs.filter { CVPixelBufferGetWidth($0.buffer) == 1280 && CVPixelBufferGetHeight($0.buffer) == 720 }.count, 10)
        }
    }

    func testGarbageDataDoesNotBreakDecoder() throws {
        for codec in Codec.allCases {
            let (frames, _) = try encode(codec, count: 10, keyframeAt: 5)
            XCTAssertTrue(frames[5].isKeyframe, codec.name)
            let box = Box<Out>()
            let dec = VideoDecoder(codec: codec) { pb, micros, ms in
                box.add(Out(buffer: pb, micros: micros, ms: ms))
            }
            defer { dec.invalidate() }
            for f in frames[0..<5] { try dec.decode(f) }

            var garbage = Data([0, 0, 0, 60])
            garbage.append(Data((0..<60).map { _ in UInt8.random(in: 0...255) }))
            // May or may not throw depending on how VideoToolbox reports it; it must not crash.
            _ = try? dec.decode(EncodedFrame(data: garbage, parameterSets: nil, isKeyframe: false,
                                             captureTimeMicros: ts(99)))
            dec.flush()

            for f in frames[5...] { try dec.decode(f) }
            dec.flush()
            XCTAssertEqual(dec.pendingFrames, 0)
            let micros = Set(box.snapshot.map { $0.micros })
            for i in 5..<10 { XCTAssertTrue(micros.contains(ts(i)), "\(codec.name) frame \(i) missing") }
        }
    }

    func testFlushAndDoubleInvalidate() throws {
        let (frames, _) = try encode(.hevc, count: 10)
        let dec = VideoDecoder(codec: .hevc) { _, _, _ in }
        for f in frames { try dec.decode(f) }
        dec.flush()
        XCTAssertEqual(dec.pendingFrames, 0)
        dec.invalidate()
        dec.invalidate()
        XCTAssertFalse(dec.isHardwareAccelerated)
        // A keyframe after invalidate recreates the session.
        try dec.decode(frames[0])
        dec.flush()
        XCTAssertTrue(dec.isHardwareAccelerated)
    }
}
