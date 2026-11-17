import Foundation

/// 1024-entry sliding replay window. Counters start at 1; 0 is always rejected.
public struct ReplayWindow {
    public static let size: UInt64 = 1024
    private var highest: UInt64 = 0
    private var bits = [UInt64](repeating: 0, count: 16)  // bit (counter % 1024)

    public init() {}

    /// Returns true exactly once per acceptable counter.
    public mutating func accept(_ counter: UInt64) -> Bool {
        if counter == 0 { return false }
        let n = ReplayWindow.size
        if counter > highest {
            let advance = counter - highest
            if advance >= n {
                for i in 0..<bits.count { bits[i] = 0 }
            } else {
                // Counted loop: `c <= counter` would overflow (trap) when counter == UInt64.max.
                var c = highest
                for _ in 0..<advance {
                    c += 1
                    clear(c)
                }
            }
            highest = counter
            set(counter)
            return true
        }
        if highest - counter >= n { return false }
        if test(counter) { return false }
        set(counter)
        return true
    }

    private func test(_ c: UInt64) -> Bool {
        let i = Int(c % ReplayWindow.size)
        return bits[i >> 6] & (1 << UInt64(i & 63)) != 0
    }

    private mutating func set(_ c: UInt64) {
        let i = Int(c % ReplayWindow.size)
        bits[i >> 6] |= (1 << UInt64(i & 63))
    }

    private mutating func clear(_ c: UInt64) {
        let i = Int(c % ReplayWindow.size)
        bits[i >> 6] &= ~(1 << UInt64(i & 63))
    }
}
