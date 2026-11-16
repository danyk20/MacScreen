import Foundation

public enum ReedSolomonError: Error, Equatable {
    case invalidParameters
    case notEnoughShards
    case shardSizeMismatch
}

/// Systematic Reed–Solomon erasure code over GF(2^8) with a Cauchy parity matrix.
public enum ReedSolomon {
    /// Coefficient of data column `j` in parity row `i`: inv((k + i) XOR j).
    @inline(__always)
    private static func coefficient(k: Int, parityRow i: Int, dataColumn j: Int) -> UInt8 {
        GF256.inv(UInt8(truncatingIfNeeded: k + i) ^ UInt8(truncatingIfNeeded: j))
    }

    private static func validate(k: Int, m: Int, shardSize: Int) throws {
        guard k >= 1, m >= 0, k + m <= 255, shardSize >= 1 else {
            throw ReedSolomonError.invalidParameters
        }
    }

    /// data: k shards, each at most `shardSize` bytes (shorter shards are treated as zero-padded).
    /// Returns m parity shards of exactly `shardSize` bytes. `m == 0` returns `[]`.
    public static func encode(data: [Data], parityCount m: Int, shardSize: Int) throws -> [Data] {
        let k = data.count
        try validate(k: k, m: m, shardSize: shardSize)
        for shard in data where shard.count > shardSize {
            throw ReedSolomonError.shardSizeMismatch
        }
        if m == 0 { return [] }

        let total = m * shardSize
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
        defer { out.deallocate() }
        out.initialize(repeating: 0, count: total)

        for j in 0..<k {
            data[j].withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count > 0 else { return }
                let src = base.assumingMemoryBound(to: UInt8.self)
                for i in 0..<m {
                    GF256.mulAdd(dst: out + i * shardSize, src: src,
                                 coefficient: coefficient(k: k, parityRow: i, dataColumn: j),
                                 count: raw.count)
                }
            }
        }
        return (0..<m).map { Data(bytes: out + $0 * shardSize, count: shardSize) }
    }

    /// shards: k + m entries (data 0..<k, then parity 0..<m); nil = missing.
    /// Returns the k data shards, each exactly `shardSize` bytes.
    public static func reconstruct(shards: [Data?], dataCount k: Int, parityCount m: Int, shardSize: Int) throws -> [Data] {
        try validate(k: k, m: m, shardSize: shardSize)
        guard shards.count == k + m else { throw ReedSolomonError.invalidParameters }
        for (idx, shard) in shards.enumerated() {
            guard let shard else { continue }
            if idx < k {
                if shard.count > shardSize { throw ReedSolomonError.shardSizeMismatch }
            } else if shard.count != shardSize {
                throw ReedSolomonError.shardSizeMismatch
            }
        }

        var missing: [Int] = []
        for j in 0..<k where shards[j] == nil { missing.append(j) }
        let e = missing.count

        func padded(_ d: Data) -> Data {
            if d.count == shardSize { return d }
            var p = d
            p.append(Data(count: shardSize - d.count))
            return p
        }

        if e == 0 {
            return (0..<k).map { padded(shards[$0] ?? Data()) }
        }

        var chosen: [Int] = []
        var p = 0
        while p < m && chosen.count < e {
            if shards[k + p] != nil { chosen.append(p) }
            p += 1
        }
        guard chosen.count == e else { throw ReedSolomonError.notEnoughShards }

        // Syndrome buffers: e rows of shardSize bytes.
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: e * shardSize)
        defer { buf.deallocate() }
        buf.initialize(repeating: 0, count: e * shardSize)

        for (r, parityIndex) in chosen.enumerated() {
            let row = buf + r * shardSize
            if let parity = shards[k + parityIndex] {
                parity.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress, raw.count == shardSize else { return }
                    row.update(from: base.assumingMemoryBound(to: UInt8.self), count: shardSize)
                }
            }
            for j in 0..<k {
                guard let d = shards[j] else { continue }
                d.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress, raw.count > 0 else { return }
                    GF256.mulAdd(dst: row, src: base.assumingMemoryBound(to: UInt8.self),
                                 coefficient: coefficient(k: k, parityRow: parityIndex, dataColumn: j),
                                 count: raw.count)
                }
            }
        }

        // e×e matrix restricted to missing columns.
        var matrix = [UInt8](repeating: 0, count: e * e)
        for (r, parityIndex) in chosen.enumerated() {
            for (c, j) in missing.enumerated() {
                matrix[r * e + c] = coefficient(k: k, parityRow: parityIndex, dataColumn: j)
            }
        }
        var order = Array(0..<e) // order[r] = buffer row holding matrix row r

        for c in 0..<e {
            var pivot = -1
            for r in c..<e where matrix[r * e + c] != 0 {
                pivot = r
                break
            }
            guard pivot >= 0 else { throw ReedSolomonError.notEnoughShards } // cannot happen for Cauchy
            if pivot != c {
                for x in 0..<e { matrix.swapAt(pivot * e + x, c * e + x) }
                order.swapAt(pivot, c)
            }
            let pivotInv = GF256.inv(matrix[c * e + c])
            for x in 0..<e { matrix[c * e + x] = GF256.mul(matrix[c * e + x], pivotInv) }
            let pivotBuf = buf + order[c] * shardSize
            GF256.scale(pivotBuf, coefficient: pivotInv, count: shardSize)
            for r in 0..<e where r != c {
                let f = matrix[r * e + c]
                if f == 0 { continue }
                for x in 0..<e { matrix[r * e + x] ^= GF256.mul(f, matrix[c * e + x]) }
                GF256.mulAdd(dst: buf + order[r] * shardSize, src: pivotBuf, coefficient: f, count: shardSize)
            }
        }

        var result: [Data] = []
        result.reserveCapacity(k)
        var next = 0
        for j in 0..<k {
            if let d = shards[j] {
                result.append(padded(d))
            } else {
                result.append(Data(bytes: buf + order[next] * shardSize, count: shardSize))
                next += 1
            }
        }
        return result
    }
}
