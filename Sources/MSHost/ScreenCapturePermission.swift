import CoreGraphics
import Foundation

/// Screen Recording (TCC) permission helpers.
public enum ScreenCapturePermission {
    /// True when this process may capture the screen. Never prompts.
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt (first call only) and returns the current state.
    @discardableResult
    public static func request() -> Bool { CGRequestScreenCaptureAccess() }

    /// Deep link to System Settings > Privacy & Security > Screen Recording.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
}
