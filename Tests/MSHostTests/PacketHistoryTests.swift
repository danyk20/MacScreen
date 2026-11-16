import XCTest
import MSCore
import MSProtocol
@testable import MSHost

final class PacketHistoryTests: XCTestCase {
    private func frags(_ id: UInt32, bytes: Int, ratio: Double = 0.1) throws -> [OutgoingFragment] {
        try Fragmenter.fragment(payload: Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &+ Int(id)) }),
                                frameId: id, isKeyframe: false, captureTimeMicros: 1, fecRatio: ratio)
    }

    private func decoded(_ items: [(PacketType, Data)]) throws -> [VideoFragment] {
        try items.map { try VideoFragment.decode($0.1) }
    }

    func testRetransmitsRequestedDataFragments() throws {
        let h = PacketHistory()
        let f = try frags(7, bytes: 5000)   // 5 data fragments, 1 parity
        h.record(frameId: 7, fragments: f, nowMicros: 1000)
        let out = h.retransmissions(for: NackPacket(frameId: 7, blockIndex: 0, fragIndices: [1, 3, 3, 99]), nowMicros: 2000)
        let d = try decoded(out)
        XCTAssertEqual(d.map { $0.fragIndex }, [1, 3])
        XCTAssertTrue(out.allSatisfy { $0.0 == .videoData })
        let original = f.filter { $0.type == .videoData && [1, 3].contains($0.fragment.fragIndex) }
        XCTAssertEqual(d.map { $0.payload }, original.map { $0.fragment.payload })
    }

    func testEmptyIndicesMeansWholeBlockAndBlockZeroMeansWholeFrame() throws {
        let h = PacketHistory()
        let bytes = MSConstants.fragmentSize * (MSConstants.maxDataFragsPerBlock + 4)   // 2 blocks: 64 + 4
        h.record(frameId: 1, fragments: try frags(1, bytes: bytes), nowMicros: 0)
        let b1 = try decoded(h.retransmissions(for: NackPacket(frameId: 1, blockIndex: 1, fragIndices: []), nowMicros: 1))
        XCTAssertEqual(b1.count, 4)
        XCTAssertTrue(b1.allSatisfy { $0.blockIndex == 1 })
        let all = h.retransmissions(for: NackPacket(frameId: 1, blockIndex: 0, fragIndices: []), nowMicros: 1)
        XCTAssertEqual(all.count, MSConstants.maxDataFragsPerBlock + 4)
    }

    func testUnknownFrameOrBlockGivesNothing() throws {
        let h = PacketHistory()
        h.record(frameId: 1, fragments: try frags(1, bytes: 3000), nowMicros: 0)
        XCTAssertTrue(h.retransmissions(for: NackPacket(frameId: 2, blockIndex: 0, fragIndices: [0]), nowMicros: 1).isEmpty)
        XCTAssertTrue(h.retransmissions(for: NackPacket(frameId: 1, blockIndex: 5, fragIndices: [0]), nowMicros: 1).isEmpty)
        XCTAssertTrue(h.retransmissions(for: NackPacket(frameId: 1, blockIndex: 5, fragIndices: []), nowMicros: 1).isEmpty)
    }

    func testEntriesExpireAfterHistoryWindow() throws {
        let h = PacketHistory()
        let window = UInt64(MSConstants.packetHistoryMs) * 1000
        h.record(frameId: 1, fragments: try frags(1, bytes: 3000), nowMicros: 0)
        h.record(frameId: 2, fragments: try frags(2, bytes: 3000), nowMicros: window)
        XCTAssertEqual(h.frameCount, 2)
        let n1 = NackPacket(frameId: 1, blockIndex: 0, fragIndices: [0])
        XCTAssertEqual(h.retransmissions(for: n1, nowMicros: window).count, 1)
        XCTAssertTrue(h.retransmissions(for: n1, nowMicros: window + 1).isEmpty)
        XCTAssertEqual(h.frameCount, 1)
        h.record(frameId: 3, fragments: try frags(3, bytes: 3000), nowMicros: 3 * window)
        XCTAssertEqual(h.frameCount, 1)
    }

    func testNoParityIsStored() throws {
        let h = PacketHistory()
        h.record(frameId: 1, fragments: try frags(1, bytes: 2400, ratio: 0.5), nowMicros: 0)
        let all = try decoded(h.retransmissions(for: NackPacket(frameId: 1, blockIndex: 0, fragIndices: []), nowMicros: 0))
        XCTAssertEqual(all.count, 2)
    }
}
