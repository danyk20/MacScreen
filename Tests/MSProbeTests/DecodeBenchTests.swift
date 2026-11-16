import XCTest
import MSCodec
@testable import MSProbe

final class DecodeBenchTests: XCTestCase {
    private func sample(_ codec: Codec) throws -> SampleFile {
        let fmt = VideoFormat(codec: codec, width: 640, height: 360, fps: 60, bitDepth: 8)
        let (_, s) = EncodeBench.run(format: fmt, bitrate: 4_000_000, frameCount: 60)
        return try XCTUnwrap(s)
    }

    private func bench(_ codec: Codec) throws {
        let r = DecodeBench.run(sample: try sample(codec))
        print("DecodeBench \(codec.name): frames=\(r.frames) hw=\(r.hardware) mean=\(r.meanMs) p95=\(r.p95Ms) fps=\(r.throughputFps) passed=\(r.passed) \(r.failureReason ?? "")")
        XCTAssertEqual(r.frames, 60)
        XCTAssertTrue(r.hardware)
        XCTAssertEqual(r.outputWidth, 640)
        XCTAssertEqual(r.outputHeight, 360)
        XCTAssertEqual(r.warmupExcluded, 10)
        XCTAssertGreaterThan(r.throughputFps, 0)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(BenchResult.self, from: data)
        XCTAssertEqual(back.frames, r.frames)
        XCTAssertEqual(back.outputWidth, 640)
        XCTAssertEqual(back.warmupExcluded, 10)
        XCTAssertEqual(back.format, r.format)
    }

    func testHEVC() throws { try bench(.hevc) }
    func testH264() throws { try bench(.h264) }

    func testCorruptedSampleFailsWithoutCrash() throws {
        var s = try sample(.h264)
        for i in s.frames.indices where !s.frames[i].isKeyframe {
            s.frames[i].data = s.frames[i].data.prefix(8)
        }
        let r = DecodeBench.run(sample: s)
        XCTAssertFalse(r.passed)
        XCTAssertNotNil(r.failureReason)
    }

    func testEmptySample() {
        let fmt = VideoFormat(codec: .h264, width: 640, height: 360, fps: 60, bitDepth: 8)
        let r = DecodeBench.run(sample: SampleFile(header: .init(format: fmt, frameCount: 0, bitrate: 1), frames: []))
        XCTAssertFalse(r.passed)
    }
}
