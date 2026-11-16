import XCTest
import MSCodec
@testable import MSProbe

final class CandidatesTests: XCTestCase {
    func testLadder() {
        let l = CandidateLadder.make(panelWidth: 5120, panelHeight: 2880)
        XCTAssertEqual(l.count, 14)
        XCTAssertEqual(l[0].format, VideoFormat(codec: .hevc, width: 5120, height: 2880, fps: 60, bitDepth: 8))
        XCTAssertEqual(l[0].bitrate, 53_084_160)
        XCTAssertTrue(l[0].hiDPI)
        // No H.264 at 5K: hardware H.264 stops at 4096x2304.
        XCTAssertFalse(l.contains { $0.format.codec == .h264 && $0.format.width > 4096 })
        XCTAssertEqual(l.prefix(7).map { $0.format.fps }, Array(repeating: 60, count: 7))
        XCTAssertEqual(l.suffix(7).map { $0.format.fps }, Array(repeating: 30, count: 7))
        XCTAssertEqual(l[1].format, VideoFormat(codec: .hevc, width: 3840, height: 2160, fps: 60, bitDepth: 8))
        XCTAssertEqual(l[2].format.codec, .h264)
        XCTAssertEqual(l[3].format.width, 3200)
        XCTAssertFalse(l[5].hiDPI)
        XCTAssertEqual(l[5].format.width, 2560)
        XCTAssertEqual(l[7].format.width, 5120)
        for c in l {
            XCTAssertEqual(c.format.width % 2, 0)
            XCTAssertEqual(c.format.height % 2, 0)
        }
        let odd = CandidateLadder.make(panelWidth: 1001, panelHeight: 601)
        for c in odd { XCTAssertEqual(c.format.width % 2, 0); XCTAssertEqual(c.format.height % 2, 0) }
    }
}
