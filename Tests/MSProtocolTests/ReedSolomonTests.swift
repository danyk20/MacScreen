import XCTest
import MSCore
@testable import MSProtocol

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next() >> 24) }
}

final class ReedSolomonTests: XCTestCase {
    private let shardSize = 1200

    private func makeData(k: Int, rng: inout SplitMix64) -> [Data] {
        var out: [Data] = []
        for j in 0..<k {
            let len = (j == k - 1) ? 1 + rng.below(shardSize - 1) : shardSize
            out.append(Data((0..<len).map { _ in rng.byte() }))
        }
        return out
    }

    private func roundTrip(data: [Data], m: Int, erased: Set<Int>, file: StaticString = #filePath, line: UInt = #line) throws {
        let k = data.count
        let parity = try ReedSolomon.encode(data: data, parityCount: m, shardSize: shardSize)
        XCTAssertEqual(parity.count, m, file: file, line: line)
        var shards: [Data?] = data.map { Optional($0) } + parity.map { Optional($0) }
        for i in erased { shards[i] = nil }
        let out = try ReedSolomon.reconstruct(shards: shards, dataCount: k, parityCount: m, shardSize: shardSize)
        XCTAssertEqual(out.count, k, file: file, line: line)
        for j in 0..<k {
            XCTAssertEqual(out[j].count, shardSize, file: file, line: line)
            XCTAssertEqual(out[j].prefix(data[j].count), data[j], "shard \(j) erased=\(erased.sorted())", file: file, line: line)
        }
    }

    func testGF256() {
        var rng = SplitMix64(seed: 1)
        for _ in 0..<1000 {
            let a = rng.byte(), b = rng.byte(), c = rng.byte()
            XCTAssertEqual(GF256.mul(a, b), GF256.mul(b, a))
            XCTAssertEqual(GF256.mul(a, b ^ c), GF256.mul(a, b) ^ GF256.mul(a, c))
        }
        for a in 1...255 { XCTAssertEqual(GF256.mul(UInt8(a), GF256.inv(UInt8(a))), 1) }
        XCTAssertEqual(GF256.inv(0), 0)
        XCTAssertEqual(GF256.mul(2, 0x80), 0x1D)
        XCTAssertEqual(GF256.exp.count, 510)
        XCTAssertEqual(GF256.log.count, 256)
    }

    func testExhaustiveSmall() throws {
        var rng = SplitMix64(seed: 2)
        for (k, m) in [(1, 1), (8, 2)] {
            let data = makeData(k: k, rng: &rng)
            let n = k + m
            for mask in 0..<(1 << n) where mask.nonzeroBitCount <= m {
                var erased = Set<Int>()
                for i in 0..<n where mask & (1 << i) != 0 { erased.insert(i) }
                try roundTrip(data: data, m: m, erased: erased)
            }
        }
    }

    func testLarge64x32() throws {
        var rng = SplitMix64(seed: 3)
        let k = 64, m = 32
        let data = makeData(k: k, rng: &rng)
        for _ in 0..<200 {
            var all = Array(0..<(k + m))
            for i in stride(from: all.count - 1, to: 0, by: -1) { all.swapAt(i, rng.below(i + 1)) }
            try roundTrip(data: data, m: m, erased: Set(all.prefix(32)))
        }
        try roundTrip(data: data, m: m, erased: Set(0..<32))
        try roundTrip(data: data, m: m, erased: Set((k - 32)..<k))
        try roundTrip(data: data, m: m, erased: Set(k..<(k + m)))
        try roundTrip(data: data, m: m, erased: Set(stride(from: 0, to: k, by: 2)))
    }

    func testTooManyErasures() throws {
        var rng = SplitMix64(seed: 4)
        let data = makeData(k: 8, rng: &rng)
        let parity = try ReedSolomon.encode(data: data, parityCount: 2, shardSize: shardSize)
        var shards: [Data?] = data.map { Optional($0) } + parity.map { Optional($0) }
        shards[0] = nil; shards[3] = nil; shards[9] = nil
        XCTAssertThrowsError(try ReedSolomon.reconstruct(shards: shards, dataCount: 8, parityCount: 2, shardSize: shardSize)) {
            XCTAssertEqual($0 as? ReedSolomonError, .notEnoughShards)
        }
        // Three data erasures with only two parity: also not enough.
        shards = data.map { Optional($0) } + parity.map { Optional($0) }
        shards[0] = nil; shards[1] = nil; shards[2] = nil
        XCTAssertThrowsError(try ReedSolomon.reconstruct(shards: shards, dataCount: 8, parityCount: 2, shardSize: shardSize)) {
            XCTAssertEqual($0 as? ReedSolomonError, .notEnoughShards)
        }
    }

    func testInvalidParameters() throws {
        let one = [Data(repeating: 1, count: 10)]
        XCTAssertThrowsError(try ReedSolomon.encode(data: [], parityCount: 1, shardSize: shardSize)) {
            XCTAssertEqual($0 as? ReedSolomonError, .invalidParameters)
        }
        let many = [Data](repeating: Data(count: 4), count: 250)
        XCTAssertThrowsError(try ReedSolomon.encode(data: many, parityCount: 6, shardSize: shardSize)) {
            XCTAssertEqual($0 as? ReedSolomonError, .invalidParameters)
        }
        XCTAssertThrowsError(try ReedSolomon.reconstruct(shards: [nil], dataCount: 0, parityCount: 1, shardSize: shardSize)) {
            XCTAssertEqual($0 as? ReedSolomonError, .invalidParameters)
        }
        XCTAssertThrowsError(try ReedSolomon.encode(data: [Data(count: shardSize + 1)], parityCount: 1, shardSize: shardSize)) {
            XCTAssertEqual($0 as? ReedSolomonError, .shardSizeMismatch)
        }
        XCTAssertThrowsError(try ReedSolomon.reconstruct(shards: [nil, Data(count: 5)], dataCount: 1, parityCount: 1, shardSize: shardSize)) {
            XCTAssertEqual($0 as? ReedSolomonError, .shardSizeMismatch)
        }
        XCTAssertThrowsError(try ReedSolomon.reconstruct(shards: [one[0], nil, nil], dataCount: 1, parityCount: 1, shardSize: shardSize)) {
            XCTAssertEqual($0 as? ReedSolomonError, .invalidParameters)
        }
    }

    func testZeroParity() throws {
        let data = [Data(repeating: 7, count: 100), Data(repeating: 9, count: 1200)]
        XCTAssertEqual(try ReedSolomon.encode(data: data, parityCount: 0, shardSize: shardSize), [])
        let out = try ReedSolomon.reconstruct(shards: data, dataCount: 2, parityCount: 0, shardSize: shardSize)
        XCTAssertEqual(out[0].count, shardSize)
        XCTAssertEqual(out[0].prefix(100), data[0])
        XCTAssertEqual(out[1], data[1])
    }

    func testEncodePerformance() throws {
        var rng = SplitMix64(seed: 5)
        let data = makeData(k: 64, rng: &rng)
        _ = try ReedSolomon.encode(data: data, parityCount: 7, shardSize: shardSize)
        let iterations = 200
        let t0 = MonoClock.nowMicros()
        for _ in 0..<iterations {
            _ = try ReedSolomon.encode(data: data, parityCount: 7, shardSize: shardSize)
        }
        let mean = Double(MonoClock.nowMicros() - t0) / Double(iterations)
        print("ReedSolomon encode k=64 m=7 size=1200: mean \(mean) us")
        XCTAssertLessThan(mean, 5000)
    }
}
