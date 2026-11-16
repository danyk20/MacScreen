import XCTest
@testable import MSCodec

final class ParameterSetsTests: XCTestCase {
    func testConfigRoundTrip() throws {
        for n in [0, 1, 3] {
            let sets = (0..<n).map { i in Data((0..<(5 + i * 7)).map { UInt8(truncatingIfNeeded: $0 + i) }) }
            let enc = ParameterSets.encodeConfig(sets)
            XCTAssertEqual(try ParameterSets.decodeConfig(enc), sets)
        }
    }

    func testConfigTruncatedThrows() {
        let enc = ParameterSets.encodeConfig([Data([1, 2, 3, 4]), Data([5, 6])])
        XCTAssertThrowsError(try ParameterSets.decodeConfig(Data()))
        for cut in 1..<enc.count {
            XCTAssertThrowsError(try ParameterSets.decodeConfig(enc.prefix(cut)), "cut \(cut)")
        }
    }

    func testFramePayloadRoundTrip() throws {
        let sample = Data((0..<100).map { UInt8($0) })
        let key = EncodedFrame(data: sample, parameterSets: [Data([1, 2]), Data([3]), Data([4, 5, 6])],
                               isKeyframe: true, captureTimeMicros: 123)
        let k = try FramePayload.decode(FramePayload.encode(key), isKeyframe: true, captureTimeMicros: 123)
        XCTAssertEqual(k.data, sample)
        XCTAssertEqual(k.parameterSets, key.parameterSets)
        XCTAssertTrue(k.isKeyframe)
        XCTAssertEqual(k.captureTimeMicros, 123)

        let delta = EncodedFrame(data: sample, parameterSets: nil, isKeyframe: false, captureTimeMicros: 9)
        let enc = FramePayload.encode(delta)
        XCTAssertEqual(enc.count, 2 + sample.count)
        let d = try FramePayload.decode(enc, isKeyframe: false, captureTimeMicros: 9)
        XCTAssertEqual(d.data, sample)
        XCTAssertNil(d.parameterSets)
    }

    func testFramePayloadTruncatedThrows() {
        let key = EncodedFrame(data: Data([9, 9, 9]), parameterSets: [Data([1, 2, 3])], isKeyframe: true,
                               captureTimeMicros: 0)
        let enc = FramePayload.encode(key)
        XCTAssertThrowsError(try FramePayload.decode(Data(), isKeyframe: true, captureTimeMicros: 0))
        XCTAssertThrowsError(try FramePayload.decode(Data([0]), isKeyframe: true, captureTimeMicros: 0))
        // Cut inside the config region.
        XCTAssertThrowsError(try FramePayload.decode(enc.prefix(4), isKeyframe: true, captureTimeMicros: 0))
    }
}
