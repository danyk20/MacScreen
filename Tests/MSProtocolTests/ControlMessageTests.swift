import XCTest
@testable import MSProtocol

final class ControlMessageTests: XCTestCase {
    static let fmt = WireVideoFormat(codec: 2, width: 3840, height: 2160, fps: 60, bitDepth: 10)

    static func all() -> [(UInt8, ControlMessage)] {
        let d = Data([1, 2, 3, 4])
        return [
            (1, .hello(HelloMessage(v: 1, deviceId: "a", deviceName: "A", identityKey: d, commit: d))),
            (2, .helloReply(HelloReplyMessage(v: 1, deviceId: "b", deviceName: "B", identityKey: d,
                                              ephKey: d, nonce: d, knowsPeer: true))),
            (3, .reveal(RevealMessage(ephKey: d, nonce: d, signature: d))),
            (4, .revealReply(RevealReplyMessage(signature: d))),
            (9, .pairRequest(PairRequestMessage())),
            (10, .pairConfirm(PairConfirmMessage())),
            (11, .pairResult(PairResultMessage(accepted: true))),
            (12, .capabilities(CapabilitiesMessage(role: "display", deviceName: "iMac", osVersion: "12.7",
                panelPixelWidth: 5120, panelPixelHeight: 2880, panelWidthMM: 596.7, panelHeightMM: 335.7,
                backingScale: 2, edrHeadroom: 1, refreshHz: 60, hwDecodeH264: true, hwDecodeHEVC: true,
                hwEncodeH264: false, hwEncodeHEVC: false, wideColor: true))),
            (13, .probeResult(ProbeResultMessage(json: Data("{\"x\":1}".utf8)))),
            (14, .linkProbeStart(LinkProbeStartMessage(trainId: 7, rateBps: 50_000_000, durationMs: 200, packetCount: 800))),
            (15, .linkProbeResult(LinkProbeResultMessage(trainId: 7, received: 799, firstArrivalMicros: 10,
                                                         lastArrivalMicros: UInt64.max - 1, jitterMs: 0.25))),
            (16, .sessionRequest(SessionRequestMessage(format: fmt, hiDPI: true, cursorMode: "overlay",
                                                       audio: false, fecRatio: 0.1))),
            (17, .sessionAccept(SessionAcceptMessage(udpPort: 65535))),
            (18, .reconfigure(ReconfigureMessage(format: fmt))),
            (19, .cursorImage(CursorImageMessage(id: 9, png: d, hotX: 1.5, hotY: 2.5, widthPt: 16, heightPt: 24))),
            (20, .hostState(HostStateMessage(displayAsleep: false, mirroring: true))),
            (21, .keepalive),
            (22, .bye(ByeMessage(reason: "done"))),
            (0x80, .probeBlob(Data((0..<1000).map { UInt8($0 & 0xFF) }))),
        ]
    }

    func testTypeCodes() {
        for (code, m) in Self.all() { XCTAssertEqual(m.typeCode, code) }
        for (code, m) in Self.all() { XCTAssertEqual(m.isHandshake, (1...4).contains(code)) }
    }

    func testRoundTripSingleFrames() throws {
        for (_, m) in Self.all() {
            let frame = ControlFramer.frame(typeCode: m.typeCode, body: try m.encodeBody())
            var f = ControlFramer()
            f.append(frame)
            let r = try XCTUnwrap(try f.next())
            XCTAssertEqual(try ControlMessage.decode(typeCode: r.typeCode, body: r.body), m)
            XCTAssertNil(try f.next())
        }
    }

    func testByteAtATimeAndConcatenated() throws {
        var stream = Data()
        var expected: [ControlMessage] = []
        for _ in 0..<3 {
            for (_, m) in Self.all() {
                stream.append(ControlFramer.frame(typeCode: m.typeCode, body: try m.encodeBody()))
                expected.append(m)
            }
        }
        // 1 byte at a time
        var f = ControlFramer()
        var got: [ControlMessage] = []
        for b in stream {
            f.append(Data([b]))
            while let r = try f.next() { got.append(try ControlMessage.decode(typeCode: r.typeCode, body: r.body)) }
        }
        XCTAssertEqual(got, expected)
        // random chunk sizes
        var g = SystemRandomNumberGenerator()
        f = ControlFramer()
        got = []
        var pos = 0
        while pos < stream.count {
            let n = min(Int.random(in: 1...700, using: &g), stream.count - pos)
            f.append(stream.subdata(in: pos..<(pos + n)))
            pos += n
            while let r = try f.next() { got.append(try ControlMessage.decode(typeCode: r.typeCode, body: r.body)) }
        }
        XCTAssertEqual(got, expected)
        // everything at once
        f = ControlFramer()
        f.append(stream)
        got = []
        while let r = try f.next() { got.append(try ControlMessage.decode(typeCode: r.typeCode, body: r.body)) }
        XCTAssertEqual(got, expected)
    }

    func testUnknownType() {
        XCTAssertThrowsError(try ControlMessage.decode(typeCode: 99, body: Data())) {
            XCTAssertEqual($0 as? ControlMessageError, .unknownType(99))
        }
        XCTAssertThrowsError(try ControlMessage.decode(typeCode: 11, body: Data("nope".utf8)))
    }

    func testOversizeAndZeroLength() {
        var f = ControlFramer()
        f.append(Data([0x04, 0x00, 0x00, 0x01, 0x15]))  // 64 MiB + 1
        XCTAssertThrowsError(try f.next()) {
            XCTAssertEqual($0 as? ControlMessageError, .frameTooLarge(0x0400_0001))
        }
        var z = ControlFramer()
        z.append(Data([0, 0, 0, 0]))
        XCTAssertThrowsError(try z.next()) {
            guard case .malformed = $0 as? ControlMessageError else { return XCTFail("\($0)") }
        }
    }

    func testLargeBlobIsFast() throws {
        let blob = Data(repeating: 0xAB, count: 16 << 20)
        let start = Date()
        let m = ControlMessage.probeBlob(blob)
        let frame = ControlFramer.frame(typeCode: m.typeCode, body: try m.encodeBody())
        var f = ControlFramer()
        var pos = 0
        var out: (typeCode: UInt8, body: Data)?
        while pos < frame.count {
            let n = min(65536, frame.count - pos)
            f.append(frame.subdata(in: pos..<(pos + n)))
            pos += n
            if let r = try f.next() { out = r }
        }
        let r = try XCTUnwrap(out)
        XCTAssertEqual(try ControlMessage.decode(typeCode: r.typeCode, body: r.body), m)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }
}
