import Foundation
import MSProtocol

enum LocalIdentity {
    /// `MACSCREEN_HOME` overrides the folder. With `--windowed` both roles can run on one Mac, so each
    /// role then gets its own folder (and therefore its own device id).
    static func open(role: Role, windowed: Bool) throws -> IdentityStore {
        var dir = IdentityStore.defaultDirectory()
        if let env = ProcessInfo.processInfo.environment["MACSCREEN_HOME"], !env.isEmpty {
            dir = URL(fileURLWithPath: env, isDirectory: true)
        } else if windowed {
            dir = dir.appendingPathComponent("windowed-\(role.rawValue)", isDirectory: true)
        }
        return try IdentityStore(directory: dir, defaultDeviceName: defaultName(windowed: windowed, role: role))
    }

    /// The Mac's own name (what a device is called until the user renames it).
    static func defaultName(windowed: Bool, role: Role) -> String {
        var name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        if windowed { name += " (\(role.rawValue))" }
        return name
    }
}
