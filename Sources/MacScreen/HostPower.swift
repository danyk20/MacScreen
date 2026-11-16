import Foundation
import IOKit.pwr_mgt

/// Abstraction over the Host's IOPMAssertion so the logic is testable.
protocol SleepAssertions: AnyObject {
    /// kIOPMAssertionTypePreventSystemSleep. Idempotent.
    func holdSystemAwake()
    func releaseSystemAwake()
}

final class IOKitSleepAssertions: SleepAssertions {
    private var id: IOPMAssertionID = 0
    private var held = false

    func holdSystemAwake() {
        guard !held else { return }
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "MacScreen is streaming to a Display" as CFString, &id)
        held = r == kIOReturnSuccess
    }

    func releaseSystemAwake() {
        guard held else { return }
        if id != 0 { IOPMAssertionRelease(id); id = 0 }
        held = false
    }
}

/// Holds the assertion exactly while a session is streaming (PLAN section 6.7). Main thread only.
final class HostPowerController {
    private let assertions: SleepAssertions
    private(set) var streaming = false

    init(assertions: SleepAssertions) { self.assertions = assertions }

    func setStreaming(_ on: Bool) {
        streaming = on
        if on { assertions.holdSystemAwake() } else { assertions.releaseSystemAwake() }
    }
}
