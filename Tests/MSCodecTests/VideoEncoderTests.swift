import XCTest
import CoreMedia
@testable import MSCodec

final class VideoEncoderTests: XCTestCase {
    private final class Collector {
        let lock = NSLock()
        var frames: [EncodedFrame] = []
        let exp: XCTestExpectation
        init(_ exp: XCTestExpectation) { self.exp = exp }
        func add(_ f: EncodedFrame) {
            lock.lock(); frames.append(f); lock.unlock()
            exp.fulfill()
        }
        var snapshot: [EncodedFrame] { lock.lock(); defer { lock.unlock() }; return frames }
    }

    private func fmt(_ c: Codec) -> VideoFormat {
        VideoFormat(codec: c, width: 1920, height: 1080, fps: 60, bitDepth: 8)
    }

    private func run(_ codec: Codec, count: Int, expectedOutputs: Int? = nil,
                     between: ((Int, VideoEncoder) -> Void)? = nil) throws -> (VideoEncoder, [EncodedFrame]) {
        let exp = expectation(description: "frames \(codec)")
        exp.expectedFulfillmentCount = expectedOutputs ?? count
        let col = Collector(exp)
        let enc = try VideoEncoder(format: fmt(codec), bitrate: 8_000_000, output: col.add)
        for i in 0..<count {
            enc.encode(makeNV12(width: 1920, height: 1080, frameIndex: i),
                       captureTimeMicros: UInt64(1_000_000 + i * 16_667))
            between?(i, enc)
        }
        wait(for: [exp], timeout: 10)
        return (enc, col.snapshot)
    }

    private func checkStream(_ codec: Codec, minSets: Int) throws {
        let (enc, frames) = try run(codec, count: 30)
        defer { enc.invalidate() }
        print("\(codec.name) lowLatency=\(enc.usesLowLatencyRateControl)")
        XCTAssertEqual(frames.count, 30)
        XCTAssertEqual(frames.map { $0.captureTimeMicros }, (0..<30).map { UInt64(1_000_000 + $0 * 16_667) })
        XCTAssertTrue(frames[0].isKeyframe)
        let sets = try XCTUnwrap(frames[0].parameterSets)
        XCTAssertGreaterThanOrEqual(sets.count, minSets)
        for f in frames.dropFirst() {
            XCTAssertFalse(f.isKeyframe)
            XCTAssertNil(f.parameterSets)
        }
        let desc = try ParameterSets.makeFormatDescription(codec: codec, parameterSets: sets)
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        XCTAssertEqual(dims.width, 1920)
        XCTAssertEqual(dims.height, 1080)
        XCTAssertEqual(enc.pendingFrames, 0)
    }

    func testHEVCStream() throws { try checkStream(.hevc, minSets: 3) }
    func testH264Stream() throws { try checkStream(.h264, minSets: 2) }

    func testRequestKeyframe() throws {
        for codec in Codec.allCases {
            let (enc, frames) = try run(codec, count: 20) { i, e in
                if i == 9 { e.requestKeyframe() }   // after frame 10 (index 9)
            }
            enc.invalidate()
            XCTAssertEqual(frames.count, 20)
            XCTAssertTrue(frames[10...11].contains { $0.isKeyframe }, "\(codec.name)")
            XCTAssertNotNil(frames[10...11].first { $0.isKeyframe }?.parameterSets)
        }
    }

    func testSetBitrateMidStream() throws {
        let (enc, frames) = try run(.hevc, count: 30) { i, e in
            if i == 14 { e.setBitrate(2_000_000) }
        }
        enc.invalidate()
        XCTAssertEqual(frames.count, 30)
        XCTAssertTrue(frames[0].isKeyframe)
    }

    func testTenBitH264Throws() {
        let f = VideoFormat(codec: .h264, width: 1920, height: 1080, fps: 60, bitDepth: 10)
        XCTAssertThrowsError(try VideoEncoder(format: f, bitrate: 8_000_000, output: { _ in })) { err in
            guard case CodecError.unsupportedFormat = err else { return XCTFail("wrong error \(err)") }
        }
    }

    func testInvalidateTwice() throws {
        let enc = try VideoEncoder(format: fmt(.hevc), bitrate: 8_000_000, output: { _ in })
        enc.invalidate()
        enc.invalidate()
        enc.encode(makeNV12(width: 1920, height: 1080, frameIndex: 0), captureTimeMicros: 1)
        XCTAssertEqual(enc.pendingFrames, 0)
    }

    func testCapabilitiesReport() throws {
        let r = CodecCapabilities.report()
        XCTAssertTrue(r.encoders.contains { $0.isHardware && $0.codecName.uppercased().contains("HEVC") || $0.isHardware && $0.codecName.contains("H.265") },
                      "encoders: \(r.encoders)")
        let data = try JSONEncoder().encode(r)
        XCTAssertGreaterThan(data.count, 10)
        XCTAssertTrue(CodecCapabilities.canHardwareEncode(fmt(.hevc)))
        print(String(data: data, encoding: .utf8) ?? "")
    }
}
