import Foundation

/// User settings (PLAN.md section 7). Codable, stored as one JSON blob in UserDefaults.
/// Host-side fields are preferences only: the Host clamps them to what the Display advertises.
public struct AppSettings: Codable, Equatable {
    /// Maximum video height in pixels; 0 = the Display's native panel size (5K: manual choice only).
    /// Default 2160 (Gate G1: HEVC 3840x2160 @ 60 fps).
    public var maxHeight: Int = 2160
    /// Preferred frame rate (30 or 60).
    public var fps: Int = 60
    /// "hevc" or "h264".
    public var codec: String = "hevc"
    /// Bitrate cap in Mbit/s; 0 = automatic (profile bitrate).
    public var bitrateCapMbps: Int = 0
    /// Not supported yet; always false in the UI.
    public var hdr: Bool = false
    /// "embedded" or "overlay".
    public var cursorMode: String = "embedded"
    public var statsOverlay: Bool = false
    /// Stored only; LoginItem arrives in T4.3.
    public var launchAtLogin: Bool = false
    /// FEC ratio recommended by the setup test (PLAN 6.10); nil = link default.
    public var fecRatio: Double?

    /// "Play sound on Display" (T5.2). Optional so settings stored before this field still decode.
    public var playSoundOnDisplay: Bool?
    public var playsSoundOnDisplay: Bool { playSoundOnDisplay ?? false }

    public init() {}

    public static let heightOptions = [0, 2160, 1440, 1080, 720]
    public static let fpsOptions = [30, 60]
    public static let bitrateOptions = [0, 10, 20, 40, 80, 150]
    public static let defaultsKey = "settings.v1"

    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s.sanitized()
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: AppSettings.defaultsKey) }
    }

    /// Replaces out-of-range values with defaults.
    public func sanitized() -> AppSettings {
        var s = self
        let d = AppSettings()
        if s.maxHeight < 0 { s.maxHeight = d.maxHeight }
        if !AppSettings.fpsOptions.contains(s.fps) { s.fps = d.fps }
        if s.codec != "hevc" && s.codec != "h264" { s.codec = d.codec }
        if s.bitrateCapMbps < 0 { s.bitrateCapMbps = d.bitrateCapMbps }
        if s.cursorMode != "embedded" && s.cursorMode != "overlay" { s.cursorMode = d.cursorMode }
        if let f = s.fecRatio, f < 0 || f > MSConstants.fecRatioMax { s.fecRatio = nil }
        s.hdr = false
        return s
    }
}
