import XCTest
import MSCodec
@testable import MSProbe

final class CandidatesTests: XCTestCase {
    func testLadder() {
        let l = CandidateLadder.make(panelWidth: 5120, panelHeight: 2880)
        func f(_ c: Codec, _ w: Int, _ h: Int, _ fps: Int) -> VideoFormat {
            VideoFormat(codec: c, width: w, height: h, fps: fps, bitDepth: 8)
        }
        XCTAssertEqual(l.map { $0.format }, [
            f(.hevc, 3840, 2160, 60), f(.hevc, 3200, 1800, 60), f(.hevc, 2560, 1440, 60),
            f(.hevc, 3840, 2160, 30), f(.hevc, 3200, 1800, 30), f(.hevc, 2560, 1440, 30),
            f(.h264, 3840, 2160, 60), f(.h264, 3200, 1800, 60), f(.h264, 2560, 1440, 60),
            f(.h264, 3840, 2160, 30), f(.h264, 3200, 1800, 30), f(.h264, 2560, 1440, 30),
            f(.hevc, 5120, 2880, 30)])
        XCTAssertEqual(l[0].bitrate, 29_859_840)   // 0.06 bpp
        XCTAssertEqual(l[0].minBitrate, 19_906_560) // 0.04 bpp
        XCTAssertTrue(l.allSatisfy { $0.hiDPI })
        // 5K: 30 fps HEVC only, manual-only and last; no 5K60, no H.264 above 4096x2304.
        XCTAssertEqual(l.filter { $0.manualOnly }.map { $0.format }, [f(.hevc, 5120, 2880, 30)])
        XCTAssertTrue(l.last!.manualOnly)
        XCTAssertFalse(l.contains { $0.format.width == 5120 && $0.format.fps == 60 })
        XCTAssertFalse(l.contains { $0.format.codec == .h264 && $0.format.width > 4096 })
        for c in l {
            XCTAssertEqual(c.format.width % 2, 0)
            XCTAssertEqual(c.format.height % 2, 0)
        }
        let odd = CandidateLadder.make(panelWidth: 1001, panelHeight: 601)
        for c in odd { XCTAssertEqual(c.format.width % 2, 0); XCTAssertEqual(c.format.height % 2, 0) }
    }

    func testCandidateDecodesWithoutManualOnly() throws {
        let c = CandidateLadder.make(panelWidth: 3840, panelHeight: 2160)[0]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        json.removeValue(forKey: "manualOnly")
        let back = try JSONDecoder().decode(Candidate.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back, c)
    }
}
