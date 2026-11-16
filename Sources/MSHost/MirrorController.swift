import CoreGraphics
import Foundation
import MSCore

/// Talks to the display system. Faked in tests so no real display is ever touched.
public protocol MirrorBackend {
    func mainDisplayID() -> CGDirectDisplayID
    /// Mirror `display` of `target`; `target == nil` stops mirroring `display` (restores extend).
    func configureMirror(display: CGDirectDisplayID, of target: CGDirectDisplayID?) throws
}

public struct SystemMirrorBackend: MirrorBackend {
    public init() {}
    public func mainDisplayID() -> CGDirectDisplayID { CGMainDisplayID() }
    public func configureMirror(display: CGDirectDisplayID, of target: CGDirectDisplayID?) throws {
        var cfg: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&cfg)
        guard err == .success, let cfg else { throw VirtualDisplayError.mirrorFailed(err.rawValue) }
        err = CGConfigureDisplayMirrorOfDisplay(cfg, display, target ?? kCGNullDirectDisplay)
        if err != .success {
            CGCancelDisplayConfiguration(cfg)
            throw VirtualDisplayError.mirrorFailed(err.rawValue)
        }
        err = CGCompleteDisplayConfiguration(cfg, .forSession)
        if err != .success {
            CGCancelDisplayConfiguration(cfg)
            throw VirtualDisplayError.mirrorFailed(err.rawValue)
        }
    }
}

/// Extend (default) or Mirror for the virtual display of the current session (PLAN.md section 7).
/// The preference outlives sessions; the system state is restored on `detach`. Main thread only.
public final class MirrorController {
    private static let log = Log.logger("mirror")
    private let backend: MirrorBackend
    private var attached: CGDirectDisplayID?
    private var applied = false

    /// User preference: true = Mirror.
    public private(set) var wantsMirror = false

    public init(backend: MirrorBackend = SystemMirrorBackend()) { self.backend = backend }

    /// True while the virtual display is actually mirroring main (sent as `hostState.mirroring`).
    public var isMirroring: Bool { applied }

    /// The virtual display exists now; apply the stored preference.
    public func attach(displayID: CGDirectDisplayID) {
        attached = displayID
        applied = false
        if wantsMirror { apply(true) }
    }

    /// Session over: restore Extend if we changed anything. Safe if the display is already gone.
    public func detach() {
        if applied, let id = attached {
            do { try backend.configureMirror(display: id, of: nil) } catch {
                Self.log.info("unmirror on detach: \(String(describing: error), privacy: .public)")
            }
        }
        applied = false
        attached = nil
    }

    /// Menu toggle. Returns the resulting `isMirroring`.
    @discardableResult
    public func setMirror(_ on: Bool) -> Bool {
        wantsMirror = on
        if attached != nil { apply(on) }
        return applied
    }

    private func apply(_ on: Bool) {
        guard let id = attached, on != applied else { return }
        let main = backend.mainDisplayID()
        if on && main == id { return }  // never mirror the display onto itself
        do {
            try backend.configureMirror(display: id, of: on ? main : nil)
            applied = on
        } catch {
            Self.log.error("mirror \(on) failed: \(String(describing: error), privacy: .public)")
        }
    }
}
