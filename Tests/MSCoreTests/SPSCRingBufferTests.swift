import XCTest
@testable import MSCore

final class SPSCRingBufferTests: XCTestCase {
    private func write(_ rb: SPSCRingBuffer, _ a: [UInt8]) -> Int {
        a.withUnsafeBytes { rb.write($0) }
    }
    private func read(_ rb: SPSCRingBuffer, _ n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        let got = out.withUnsafeMutableBytes { rb.read(into: $0) }
        return Array(out[0..<got])
    }

    func testFillDrainAndCapacityRounding() {
        let rb = SPSCRingBuffer(capacity: 100)
        XCTAssertEqual(rb.availableToWrite, 128)
        XCTAssertEqual(rb.availableToRead, 0)
        let data = (0..<128).map { UInt8($0) }
        XCTAssertEqual(write(rb, data), 128)
        XCTAssertEqual(rb.availableToWrite, 0)
        XCTAssertEqual(write(rb, [1]), 0)
        XCTAssertEqual(read(rb, 200), data)
        XCTAssertEqual(rb.availableToRead, 0)
    }

    func testOverWriteReturnsShort() {
        let rb = SPSCRingBuffer(capacity: 16)
        XCTAssertEqual(write(rb, [UInt8](repeating: 7, count: 10)), 10)
        XCTAssertEqual(write(rb, [UInt8](repeating: 8, count: 10)), 6)
        XCTAssertEqual(rb.availableToRead, 16)
    }

    func testSkipAndReset() {
        let rb = SPSCRingBuffer(capacity: 16)
        _ = write(rb, [1, 2, 3, 4, 5])
        XCTAssertEqual(rb.skip(2), 2)
        XCTAssertEqual(read(rb, 10), [3, 4, 5])
        XCTAssertEqual(rb.skip(5), 0)
        _ = write(rb, [1, 2])
        rb.reset()
        XCTAssertEqual(rb.availableToRead, 0)
        XCTAssertEqual(rb.availableToWrite, 16)
    }

    func testWrapAroundManyTimes() {
        let rb = SPSCRingBuffer(capacity: 64)
        var counter: UInt8 = 0
        var expected: UInt8 = 0
        var chunk = 1
        for _ in 0..<5000 {
            chunk = (chunk * 7 + 3) % 40 + 1
            let src = (0..<chunk).map { i in counter &+ UInt8(i) }
            let w = write(rb, src)
            counter = counter &+ UInt8(w)
            let rchunk = (chunk * 5 + 1) % 50 + 1
            for b in read(rb, rchunk) {
                XCTAssertEqual(b, expected)
                expected = expected &+ 1
            }
        }
        for b in read(rb, 1000) {
            XCTAssertEqual(b, expected)
            expected = expected &+ 1
        }
        XCTAssertEqual(expected, counter)
    }

    func testTwoThreadStress() {
        let rb = SPSCRingBuffer(capacity: 4096)
        let total = 4 * 1024 * 1024
        let producer = expectation(description: "producer")
        let consumer = expectation(description: "consumer")
        var mismatches = 0
        DispatchQueue.global().async {
            var sent = 0
            var chunk = [UInt8](repeating: 0, count: 1000)
            var n = 13
            while sent < total {
                n = (n * 31 + 7) % 1000 + 1
                let len = min(n, total - sent)
                for i in 0..<len { chunk[i] = UInt8(truncatingIfNeeded: (sent + i) &* 31 &+ (sent + i) >> 8) }
                var off = 0
                while off < len {
                    let w = chunk.withUnsafeBytes { rb.write(UnsafeRawBufferPointer(rebasing: $0[off..<len])) }
                    off += w
                    if w == 0 { sched_yield() }
                }
                sent += len
            }
            producer.fulfill()
        }
        DispatchQueue.global().async {
            var got = 0
            var buf = [UInt8](repeating: 0, count: 777)
            while got < total {
                let r = buf.withUnsafeMutableBytes { rb.read(into: $0) }
                if r == 0 { sched_yield(); continue }
                for i in 0..<r {
                    let p = got + i
                    if buf[i] != UInt8(truncatingIfNeeded: p &* 31 &+ p >> 8) { mismatches += 1 }
                }
                got += r
            }
            consumer.fulfill()
        }
        wait(for: [producer, consumer], timeout: 60)
        XCTAssertEqual(mismatches, 0)
    }
}
