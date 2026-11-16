/// Arithmetic in GF(2^8) with primitive polynomial 0x11D and generator 2.
enum GF256 {
    /// `exp[i] = 2^i`, 510 entries so that `exp[log a + log b]` needs no modulo.
    static let exp: [UInt8] = tables.exp
    /// `log[a]` for a in 1...255 (`log[0]` is unused and 0).
    static let log: [UInt8] = tables.log

    /// Flat 64 KiB multiplication table, `mulTable[a << 8 | b] == a·b`. Allocated once, never freed.
    static let mulTable: UnsafeMutablePointer<UInt8> = {
        let t = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536)
        t.initialize(repeating: 0, count: 65_536)
        let e = tables.exp
        let l = tables.log
        for a in 1..<256 {
            for b in 1..<256 {
                t[(a << 8) | b] = e[Int(l[a]) + Int(l[b])]
            }
        }
        return t
    }()

    private static let tables: (exp: [UInt8], log: [UInt8]) = {
        var e = [UInt8](repeating: 0, count: 510)
        var l = [UInt8](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            e[i] = UInt8(truncatingIfNeeded: x)
            l[x] = UInt8(truncatingIfNeeded: i)
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255..<510 { e[i] = e[i - 255] }
        return (e, l)
    }()

    @inline(__always)
    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        mulTable[(Int(a) << 8) | Int(b)]
    }

    /// Multiplicative inverse; `inv(0)` returns 0.
    static func inv(_ a: UInt8) -> UInt8 {
        if a == 0 { return 0 }
        return exp[255 - Int(log[Int(a)])]
    }

    /// `dst[i] ^= coefficient · src[i]` for `i` in `0..<count`.
    @_optimize(speed)
    static func mulAdd(dst: UnsafeMutablePointer<UInt8>, src: UnsafePointer<UInt8>, coefficient: UInt8, count: Int) {
        if coefficient == 0 || count <= 0 { return }
        if coefficient == 1 {
            let rawDst = UnsafeMutableRawPointer(dst)
            let rawSrc = UnsafeRawPointer(src)
            var i = 0
            while i + 8 <= count {
                let a = rawDst.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                let b = rawSrc.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                rawDst.storeBytes(of: a ^ b, toByteOffset: i, as: UInt64.self)
                i += 8
            }
            while i < count {
                dst[i] ^= src[i]
                i += 1
            }
            return
        }
        let row = UnsafePointer(mulTable + (Int(coefficient) << 8))
        var d = dst
        var s = src
        let end = dst + count
        while d < end {
            d.pointee ^= row[Int(s.pointee)]
            d += 1
            s += 1
        }
    }

    /// `buf[i] = coefficient · buf[i]` in place.
    @_optimize(speed)
    static func scale(_ buf: UnsafeMutablePointer<UInt8>, coefficient: UInt8, count: Int) {
        if coefficient == 1 || count <= 0 { return }
        if coefficient == 0 {
            buf.update(repeating: 0, count: count)
            return
        }
        let row = UnsafePointer(mulTable + (Int(coefficient) << 8))
        for i in 0..<count {
            buf[i] = row[Int(buf[i])]
        }
    }
}
