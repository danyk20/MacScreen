import Foundation
import os

enum Role: String {
    case host
    case display
}

struct LaunchOptions {
    var role: Role?
    var windowed: Bool
    var stats: Bool
    /// Case-insensitive name substring of the Display the Host should connect to automatically.
    var connect: String?
    /// "embedded" (default) or "overlay" (`--cursor overlay`).
    var cursorMode: String = "embedded"

    static let roleDefaultsKey = "role"
    private static let log = Logger(subsystem: "app.macscreen", category: "app")

    static func parse(_ args: [String], defaults: UserDefaults) -> LaunchOptions {
        var roleArg: String?
        var windowed = false
        var stats = false
        var connect: String?
        var cursorMode = "embedded"
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--role" {
                if index + 1 < args.count {
                    roleArg = args[index + 1]
                    index += 1
                } else {
                    roleArg = ""
                }
            } else if arg.hasPrefix("--role=") {
                roleArg = String(arg.dropFirst("--role=".count))
            } else if arg == "--windowed" {
                windowed = true
            } else if arg == "--stats" {
                stats = true
            } else if arg == "--connect" {
                if index + 1 < args.count {
                    connect = args[index + 1]
                    index += 1
                }
            } else if arg.hasPrefix("--connect=") {
                connect = String(arg.dropFirst("--connect=".count))
            } else if arg == "--cursor", index + 1 < args.count {
                cursorMode = args[index + 1] == "overlay" ? "overlay" : "embedded"
                index += 1
            } else if arg.hasPrefix("--cursor=") {
                cursorMode = arg.dropFirst("--cursor=".count) == "overlay" ? "overlay" : "embedded"
            }
            index += 1
        }

        var role: Role?
        if let value = roleArg {
            if let parsed = Role(rawValue: value) {
                role = parsed
                defaults.set(parsed.rawValue, forKey: roleDefaultsKey)
            } else {
                log.error("Invalid --role value '\(value, privacy: .public)'; expected host or display")
            }
        } else if let stored = defaults.string(forKey: roleDefaultsKey) {
            role = Role(rawValue: stored)
        }
        return LaunchOptions(role: role, windowed: windowed, stats: stats, connect: connect, cursorMode: cursorMode)
    }
}
