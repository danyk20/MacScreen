import Foundation
import IOKit.pwr_mgt

/// Abstraction over IOPMAssertion so the lifecycle logic is testable.
protocol PowerAssertions: AnyObject {
    /// Prevent display sleep and idle sleep. Idempotent.
    func holdDisplayAwake()
    func releaseDisplayAwake()
    /// Wake the panel (user-activity declaration).
    func wakeDisplay()
}

final class IOKitPowerAssertions: PowerAssertions {
    private var displayID: IOPMAssertionID = 0
    private var idleID: IOPMAssertionID = 0
    private var activityID: IOPMAssertionID = 0
    private var held = false

    func holdDisplayAwake() {
        guard !held else { return }
        let reason = "MacScreen is showing a Host" as CFString
        let r1 = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayID)
        let r2 = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &idleID)
        held = r1 == kIOReturnSuccess || r2 == kIOReturnSuccess
    }

    func releaseDisplayAwake() {
        guard held else { return }
        if displayID != 0 { IOPMAssertionRelease(displayID); displayID = 0 }
        if idleID != 0 { IOPMAssertionRelease(idleID); idleID = 0 }
        held = false
    }

    func wakeDisplay() {
        IOPMAssertionDeclareUserActivity("MacScreen Host connected" as CFString, kIOPMUserActiveLocal, &activityID)
    }
}

/// Decides when assertions are held: only while a Host is connected and its display is not asleep.
/// Main thread only.
final class DisplayPowerController {
    private let assertions: PowerAssertions
    private(set) var connected = false
    private(set) var hostAsleep = false

    init(assertions: PowerAssertions) { self.assertions = assertions }

    func hostConnected() {
        connected = true
        hostAsleep = false
        assertions.wakeDisplay()
        apply()
    }

    func hostDisconnected() {
        connected = false
        hostAsleep = false
        apply()
    }

    func hostStateChanged(displayAsleep: Bool) {
        guard connected else { return }
        hostAsleep = displayAsleep
        apply()
    }

    private func apply() {
        if connected && !hostAsleep { assertions.holdDisplayAwake() } else { assertions.releaseDisplayAwake() }
    }
}
