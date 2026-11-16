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

    static let roleDefaultsKey = "role"
    private static let log = Logger(subsystem: "app.macscreen", category: "app")

    static func parse(_ args: [String], defaults: UserDefaults) -> LaunchOptions {
        var roleArg: String?
        var windowed = false
        var stats = false
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
        return LaunchOptions(role: role, windowed: windowed, stats: stats)
    }
}
