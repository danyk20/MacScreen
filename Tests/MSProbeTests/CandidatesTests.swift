import XCTest
import MSCodec
@testable import MSProbe

final class CandidatesTests: XCTestCase {
    func testLadder() {
        let l = CandidateLadder.make(panelWidth: 5120, panelHeight: 2880)
        XCTAssertEqual(l.count, 16)
        XCTAssertEqual(l[0].format, VideoFormat(codec: .hevc, width: 5120, height: 2880, fps: 60, bitDepth: 8))
        XCTAssertEqual(l[0].bitrate, 53_084_160)
        XCTAssertTrue(l[0].hiDPI)
        XCTAssertEqual(l[1].format.codec, .h264)
        XCTAssertEqual(l[1].format.width, 5120)
        XCTAssertEqual(l.prefix(8).map { $0.format.fps }, Array(repeating: 60, count: 8))
        XCTAssertEqual(l.suffix(8).map { $0.format.fps }, Array(repeating: 30, count: 8))
        XCTAssertEqual(l[2].format.width, 3840)
        XCTAssertEqual(l[4].format.width, 3200)
        XCTAssertFalse(l[6].hiDPI)
        XCTAssertEqual(l[6].format.width, 2560)
        XCTAssertEqual(l[8].format.codec, .hevc)
        for c in l {
            XCTAssertEqual(c.format.width % 2, 0)
            XCTAssertEqual(c.format.height % 2, 0)
        }
        let odd = CandidateLadder.make(panelWidth: 1001, panelHeight: 601)
        for c in odd { XCTAssertEqual(c.format.width % 2, 0); XCTAssertEqual(c.format.height % 2, 0) }
    }
}
