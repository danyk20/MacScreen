import XCTest
import MSCodec
@testable import MSProbe

final class EncodeBenchTests: XCTestCase {
    private func bench(_ codec: Codec) throws {
        let fmt = VideoFormat(codec: codec, width: 640, height: 360, fps: 60, bitDepth: 8)
        let (r, s) = EncodeBench.run(format: fmt, bitrate: 4_000_000, frameCount: 30)
        print("EncodeBench \(codec.name) 640x360: frames=\(r.frames) mean=\(r.meanMs) p95=\(r.p95Ms) max=\(r.maxMs) fps=\(r.throughputFps) passed=\(r.passed)")
        XCTAssertEqual(r.frames, 30)
        let sample = try XCTUnwrap(s)
        XCTAssertEqual(sample.frames.count, 30)
        XCTAssertTrue(sample.frames[0].isKeyframe)
        XCTAssertGreaterThan(r.p95Ms, 0)
        XCTAssertNoThrow(try JSONEncoder().encode(r))
    }

    func testHEVC() throws { try bench(.hevc) }
    func testH264() throws { try bench(.h264) }

    func testImpossibleFormat() {
        let fmt = VideoFormat(codec: .h264, width: 640, height: 360, fps: 60, bitDepth: 10)
        let (r, s) = EncodeBench.run(format: fmt, bitrate: 1_000_000, frameCount: 5)
        XCTAssertFalse(r.passed)
        XCTAssertNotNil(r.failureReason)
        XCTAssertNil(s)
    }
}
