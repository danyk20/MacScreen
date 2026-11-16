import Darwin

/// Monotonic clock based on `mach_continuous_time` (keeps counting during sleep).
public enum MonoClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        if info.denom == 0 { info = mach_timebase_info_data_t(numer: 1, denom: 1) }
        return info
    }()

    public static func nowMicros() -> UInt64 {
        micros(fromMachTicks: mach_continuous_time())
    }

    /// Converts mach ticks to microseconds using a 128-bit intermediate (no overflow).
    public static func micros(fromMachTicks ticks: UInt64) -> UInt64 {
        let tb = timebase
        let numer = UInt64(tb.numer)
        let denom = UInt64(tb.denom) * 1000
        let (high, low) = ticks.multipliedFullWidth(by: numer)
        if high >= denom { return UInt64.max }
        return denom.dividingFullWidth((high, low)).quotient
    }
}
