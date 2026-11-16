import XCTest
import MSCodec
@testable import MSProbe

final class SampleFileTests: XCTestCase {
    private func make() -> SampleFile {
        let fmt = VideoFormat(codec: .hevc, width: 640, height: 360, fps: 60, bitDepth: 8)
        var frames: [EncodedFrame] = []
        for i in 0..<3 {
            var bytes: [UInt8] = []
            for b in 0..<(10 + i) { bytes.append(UInt8(b)) }
            let sets: [Data]? = i == 0 ? [Data([1, 2, 3]), Data([4, 5])] : nil
            frames.append(EncodedFrame(data: Data(bytes), parameterSets: sets, isKeyframe: i == 0,
                                       captureTimeMicros: UInt64(i) * 1_000_000 / 60))
        }
        return SampleFile(header: .init(format: fmt, frameCount: 3, bitrate: 1234), frames: frames)
    }

    func testRoundTrip() throws {
        let s = make()
        let p = try SampleFile.parse(s.serialize())
        XCTAssertEqual(p.header, s.header)
        XCTAssertEqual(p.frames.count, 3)
        for (a, b) in zip(s.frames, p.frames) {
            XCTAssertEqual(a.data, b.data)
            XCTAssertEqual(a.parameterSets, b.parameterSets)
            XCTAssertEqual(a.isKeyframe, b.isKeyframe)
            XCTAssertEqual(a.captureTimeMicros, b.captureTimeMicros)
        }
    }

    func testErrors() throws {
        var d = make().serialize()
        XCTAssertThrowsError(try SampleFile.parse(d.dropLast(3))) { XCTAssertEqual($0 as? SampleFileError, .truncated) }
        XCTAssertThrowsError(try SampleFile.parse(Data([1, 2]))) { XCTAssertEqual($0 as? SampleFileError, .truncated) }
        d[0] = 0x58
        XCTAssertThrowsError(try SampleFile.parse(d)) { XCTAssertEqual($0 as? SampleFileError, .badMagic) }
        var bad = Data("MSV1".utf8)
        bad.append(contentsOf: [0, 0, 0, 2, 0x7B, 0x7D])
        XCTAssertThrowsError(try SampleFile.parse(bad)) { XCTAssertEqual($0 as? SampleFileError, .badHeader) }
    }

    func testFileIO() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.msv")
        let s = make()
        try s.write(to: url)
        let r = try SampleFile.read(from: url)
        XCTAssertEqual(r.header, s.header)
        XCTAssertEqual(r.frames.map { $0.data }, s.frames.map { $0.data })
    }
}
