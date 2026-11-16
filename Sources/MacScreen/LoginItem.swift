import Foundation

/// Launch-at-login for the Display role via a per-user LaunchAgent plist. Never calls launchctl:
/// the agent takes effect at the next login.
enum LoginItem {
    static let label = "app.macscreen.display"
    static var plistName: String { "\(label).plist" }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    /// Pure: property-list XML for the agent.
    static func plistContent(executablePath: String) throws -> Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, "--role", "display"],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    static func plistURL(in directory: URL) -> URL { directory.appendingPathComponent(plistName) }

    static func isEnabled(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: plistURL(in: directory).path)
    }

    static func enable(executablePath: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try plistContent(executablePath: executablePath).write(to: plistURL(in: directory), options: .atomic)
    }

    static func disable(in directory: URL) throws {
        let url = plistURL(in: directory)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static func set(_ on: Bool, executablePath: String, in directory: URL) throws {
        if on { try enable(executablePath: executablePath, in: directory) } else { try disable(in: directory) }
    }
}
