import XCTest
import CryptoKit
@testable import MSProtocol

final class CipherTests: XCTestCase {
    // MARK: ReplayWindow
    func testReplayWindow() {
        var w = ReplayWindow()
        XCTAssertFalse(w.accept(0))
        for i in 1...10 { XCTAssertTrue(w.accept(UInt64(i))) }
        for i in 1...10 { XCTAssertFalse(w.accept(UInt64(i))) }
        // out of order within window
        XCTAssertTrue(w.accept(20))
        XCTAssertTrue(w.accept(15))
        XCTAssertFalse(w.accept(15))
        XCTAssertFalse(w.accept(20))
        // too old
        XCTAssertTrue(w.accept(2000))
        XCTAssertFalse(w.accept(2000 - 1024))
        XCTAssertFalse(w.accept(5))
        XCTAssertTrue(w.accept(2000 - 1023))
        XCTAssertFalse(w.accept(2000 - 1023))
        // jump far ahead then old ones rejected
        XCTAssertTrue(w.accept(1_000_000))
        XCTAssertFalse(w.accept(2000))
        XCTAssertFalse(w.accept(15))
        XCTAssertTrue(w.accept(999_999))
        XCTAssertFalse(w.accept(1_000_000))
        XCTAssertFalse(w.accept(0))
    }

    func testReplayWindowSlideClearsOldSlots() {
        var w = ReplayWindow()
        XCTAssertTrue(w.accept(1))
        XCTAssertTrue(w.accept(1025))   // same slot as 1
        XCTAssertFalse(w.accept(1))     // too old now
        XCTAssertTrue(w.accept(1500))
        XCTAssertTrue(w.accept(1026))
        XCTAssertFalse(w.accept(1025))
    }

    // MARK: Packets
    func makePair() -> (PacketSealer, PacketOpener, SymmetricKey) {
        let k = SymmetricKey(size: .bits256)
        return (PacketSealer(key: k), PacketOpener(key: k), k)
    }

    func testRoundTrip() throws {
        let (s, o, _) = makePair()
        var expectedCounter: UInt64 = 0
        for (type, size) in [(UInt8(1), 0), (2, 1), (3, 960), (9, 1200), (1, 1228)] {
            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 13) })
            let dg = try s.seal(type: type, payload: payload)
            expectedCounter += 1
            XCTAssertEqual(dg.count, 12 + size + 16)
            XCTAssertEqual(dg[0], type)
            XCTAssertEqual(dg[1], 0)
            XCTAssertEqual(dg[2], 0)
            XCTAssertEqual(dg[3], 0)
            XCTAssertEqual(Array(dg[4..<12]), (0..<8).map { UInt8(truncatingIfNeeded: expectedCounter >> UInt64(56 - 8 * $0)) })
            let r = try o.open(dg)
            XCTAssertEqual(r.type, type)
            XCTAssertEqual(r.counter, expectedCounter)
            XCTAssertEqual(r.payload, payload)
        }
    }

    func testEveryByteFlipFails() throws {
        let (s, _, k) = makePair()
        let dg = try s.seal(type: 4, payload: Data((0..<40).map { UInt8($0) }))
        for i in 0..<dg.count {
            for bit in [0, 7] {
                var bad = dg
                bad[i] ^= UInt8(1 << bit)
                let o = PacketOpener(key: k)
                XCTAssertThrowsError(try o.open(bad), "byte \(i) bit \(bit)") {
                    XCTAssertEqual($0 as? CipherError, .authenticationFailed)
                }
            }
        }
    }

    func testReplayAndForgeryDoesNotPoisonWindow() throws {
        let (s, o, _) = makePair()
        let d1 = try s.seal(type: 1, payload: Data([1]))
        var forged = d1
        forged[forged.count - 1] ^= 1
        XCTAssertThrowsError(try o.open(forged)) { XCTAssertEqual($0 as? CipherError, .authenticationFailed) }
        _ = try o.open(d1)  // the genuine one still works
        XCTAssertThrowsError(try o.open(d1)) { XCTAssertEqual($0 as? CipherError, .replayed) }
    }

    func testWrongKeyAndTooShort() throws {
        let (s, _, _) = makePair()
        let dg = try s.seal(type: 1, payload: Data([1, 2]))
        let o2 = PacketOpener(key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try o2.open(dg)) { XCTAssertEqual($0 as? CipherError, .authenticationFailed) }
        XCTAssertThrowsError(try o2.open(Data(count: 27))) { XCTAssertEqual($0 as? CipherError, .tooShort) }
        XCTAssertThrowsError(try o2.open(Data())) { XCTAssertEqual($0 as? CipherError, .tooShort) }
    }

    func testOutOfOrderWithinWindow() throws {
        let (s, o, _) = makePair()
        let dgs = try (0..<50).map { try s.seal(type: 5, payload: Data([UInt8($0)])) }
        for i in stride(from: 49, through: 0, by: -1) {
            XCTAssertEqual(try o.open(dgs[i]).payload, Data([UInt8(i)]))
        }
        XCTAssertThrowsError(try o.open(dgs[7])) { XCTAssertEqual($0 as? CipherError, .replayed) }
    }

    func testDataSliceInput() throws {
        let (s, o, _) = makePair()
        let dg = try s.seal(type: 3, payload: Data([9, 8, 7]))
        var big = Data([0xAA, 0xBB, 0xCC])
        big.append(dg)
        big.append(contentsOf: [0xDD, 0xEE])
        let slice = big[3..<(3 + dg.count)]
        XCTAssertEqual(slice.startIndex, 3)
        let r = try o.open(slice)
        XCTAssertEqual(r.payload, Data([9, 8, 7]))
        XCTAssertEqual(r.type, 3)
    }

    func testConcurrentSealUniqueCounters() throws {
        let (s, o, _) = makePair()
        let perThread = 250  // 1000 total, fits the replay window
        let lock = NSLock()
        var all: [Data] = []
        let group = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global().async(group: group) {
                var local: [Data] = []
                for _ in 0..<perThread {
                    if let d = try? s.seal(type: 1, payload: Data([1])) { local.append(d) }
                }
                lock.lock(); all.append(contentsOf: local); lock.unlock()
            }
        }
        group.wait()
        XCTAssertEqual(all.count, 4 * perThread)
        var counters = Set<UInt64>()
        for d in all { counters.insert(try o.open(d).counter) }  // also verifies decryptable
        XCTAssertEqual(counters.count, 4 * perThread)
        XCTAssertEqual(counters.min(), 1)
        XCTAssertEqual(counters.max(), UInt64(4 * perThread))
    }

    // MARK: Control
    func testControlRoundTrip() throws {
        let k = SymmetricKey(size: .bits256)
        let s = ControlSealer(key: k), o = ControlOpener(key: k)
        for i in 0..<100 {
            let body = Data("message \(i)".utf8)
            let sealed = try s.seal(body)
            XCTAssertEqual(sealed.count, body.count + 16)
            XCTAssertEqual(try o.open(sealed), body)
        }
        XCTAssertEqual(try o.open(try s.seal(Data())), Data())
    }

    func testControlSkipAndTamper() throws {
        let k = SymmetricKey(size: .bits256)
        let s = ControlSealer(key: k), o = ControlOpener(key: k)
        let m1 = try s.seal(Data("a".utf8))
        let m2 = try s.seal(Data("b".utf8))
        let m3 = try s.seal(Data("c".utf8))
        XCTAssertEqual(try o.open(m1), Data("a".utf8))
        XCTAssertThrowsError(try o.open(m3)) { XCTAssertEqual($0 as? CipherError, .authenticationFailed) }
        // counter did not advance on failure: m2 still opens
        XCTAssertEqual(try o.open(m2), Data("b".utf8))
        XCTAssertEqual(try o.open(m3), Data("c".utf8))
        // tamper
        let m4 = try s.seal(Data("dddd".utf8))
        var bad = m4
        bad[0] ^= 1
        XCTAssertThrowsError(try o.open(bad)) { XCTAssertEqual($0 as? CipherError, .authenticationFailed) }
        XCTAssertEqual(try o.open(m4), Data("dddd".utf8))
        XCTAssertThrowsError(try o.open(Data(count: 3))) { XCTAssertEqual($0 as? CipherError, .tooShort) }
    }
}
