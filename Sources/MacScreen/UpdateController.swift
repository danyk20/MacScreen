import AppKit
import CryptoKit
import MSCore
import os

/// "Check for Updates" and in-app install. The app is replaced in place from the GitHub release DMG:
/// the DMG is verified against the release's SHA256SUMS.txt, the new bundle is checked, and a small helper script
/// swaps the bundle after this process quits and reopens the app. Main thread only.
final class UpdateController: NSObject {
    private static let log = Logger(subsystem: "app.macscreen", category: "update")
    private static let lastCheckKey = "msLastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 3600

    enum State: Equatable {
        case idle
        case checking
        case available(String)          // version text; the release itself is in `release`
        case downloading(Int)           // percent
        case installing
    }

    private(set) var state = State.idle { didSet { onChange?() } }
    private var release: Release?
    var onChange: (() -> Void)?
    /// Role-specific warning shown before installing (set by the app).
    var installNote: () -> String? = { nil }

    /// The running version: the full release version stamped by CI, else the bundle version.
    static var currentVersion: SemanticVersion {
        let info = Bundle.main.infoDictionary
        let text = (info?["MSReleaseVersion"] as? String) ?? (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        return SemanticVersion(text) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    }

    var menuTitle: String {
        switch state {
        case .idle: return "Check for Updates\u{2026}"
        case .checking: return "Checking for Updates\u{2026}"
        case .available(let v): return "Update to \(v)\u{2026}"
        case .downloading(let p): return "Downloading Update\u{2026} \(p)%"
        case .installing: return "Installing Update\u{2026}"
        }
    }

    var menuEnabled: Bool {
        switch state {
        case .idle, .available: return true
        default: return false
        }
    }

    @objc func menuAction() {
        if let r = release, case .available = state { present(r) } else { check(userInitiated: true) }
    }

    /// Quiet check at launch, at most once a day, when the user has not turned it off.
    func autoCheckIfDue(enabled: Bool) {
        guard enabled else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > Self.checkInterval else { return }
        check(userInitiated: false)
    }

    // MARK: Check

    func check(userInitiated: Bool) {
        guard menuEnabled else { return }
        state = .checking
        Task { @MainActor in
            do {
                let found = try await Self.fetchNewest(than: Self.currentVersion)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                release = found
                if let r = found {
                    state = .available(r.version.description)
                    if userInitiated { present(r) }
                } else {
                    state = .idle
                    if userInitiated {
                        _ = Dialogs.alert("MacScreen is up to date",
                                          "You have the latest version (\(Self.currentVersion)).")
                    }
                }
            } catch {
                state = .idle
                Self.log.error("update check failed: \(String(describing: error), privacy: .public)")
                if userInitiated {
                    _ = Dialogs.alert("Could not check for updates",
                                      "Check your internet connection and try again.\n\n\(error.localizedDescription)")
                }
            }
        }
    }

    private static func fetchNewest(than current: SemanticVersion) async throws -> Release? {
        var req = URLRequest(url: UpdateConfig.feedURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacScreen/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse }
        return ReleaseFeed.newer(than: current, in: ReleaseFeed.parse(data))
    }

    // MARK: Offer

    private func present(_ r: Release) {
        var info = "You have \(Self.currentVersion).\(r.isPrerelease ? " This is a pre-release." : "")"
        let notes = r.notes.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.prefix(6).joined(separator: "\n")
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(500)) }
        if let n = installNote() { info += "\n\n" + n }
        let choice = Dialogs.alert("MacScreen \(r.version) is available", info,
                                   buttons: ["Install and Restart", "Release Notes", "Later"])
        switch choice {
        case .alertFirstButtonReturn: install(r)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(r.pageURL)
        default: break
        }
    }

    // MARK: Install

    private func install(_ r: Release) {
        let target = Bundle.main.bundleURL
        guard Self.canReplace(target) else {
            // Running from a disk image, a translocated copy or a folder we cannot write: hand over the DMG.
            Task { @MainActor in
                state = .idle
                if let dmg = try? await download(r.dmg, verifyAgainst: r.checksums) {
                    NSWorkspace.shared.open(dmg)
                    _ = Dialogs.alert("Finish the update by hand",
                                      "MacScreen cannot replace itself where it is now. The new version was opened: drag MacScreen to Applications and replace the old one.")
                }
            }
            return
        }
        state = .downloading(0)
        Task { @MainActor in
            do {
                let dmg = try await download(r.dmg, verifyAgainst: r.checksums)
                state = .installing
                let staged = try await Task.detached { try Self.stage(dmg: dmg, expecting: r.version) }.value
                try Self.launchSwapper(staged: staged, target: target)
                Self.log.notice("update to \(r.version.description, privacy: .public) staged; quitting")
                NSApp.terminate(nil)
            } catch {
                state = .available(r.version.description)
                Self.log.error("update failed: \(String(describing: error), privacy: .public)")
                _ = Dialogs.alert("The update could not be installed",
                                  "\(error.localizedDescription)\n\nYour current version is unchanged. You can download the new version from the release page.")
            }
        }
    }

    private static func canReplace(_ app: URL) -> Bool {
        let path = app.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    private func download(_ asset: ReleaseAsset, verifyAgainst sums: ReleaseAsset) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macscreen-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sumsFile = try await Downloader.fetch(sums.url, to: dir.appendingPathComponent("SHA256SUMS.txt")) { _ in }
        let sumsText = try String(contentsOf: sumsFile, encoding: .utf8)
        guard let expected = ChecksumFile.parse(sumsText)[asset.name] else { throw UpdateError.noChecksum(asset.name) }
        let box = WeakBox(self)
        let file = try await Downloader.fetch(asset.url, to: dir.appendingPathComponent(asset.name)) { pct in
            DispatchQueue.main.async { box.controller?.progressed(pct) }
        }
        guard try Self.sha256(of: file) == expected else { throw UpdateError.checksumMismatch }
        return file
    }

    private func progressed(_ pct: Int) {
        if case .downloading = state { state = .downloading(pct) }
    }

    private static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Mounts the DMG, copies the app out, unmounts, and checks the copy is the app and version we expect.
    private static func stage(dmg: URL, expecting version: SemanticVersion) throws -> URL {
        let work = dmg.deletingLastPathComponent()
        let mount = work.appendingPathComponent("mnt")
        let out = work.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        let app = out.appendingPathComponent("MacScreen.app")
        _ = try run("/usr/bin/ditto", [mount.appendingPathComponent("MacScreen.app").path, app.path])

        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let v = (info["MSReleaseVersion"] as? String).flatMap(SemanticVersion.init), v == version else {
            throw UpdateError.wrongApp
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    /// Detached helper: waits for this process to exit, swaps the bundle (restoring the old one on failure),
    /// removes the quarantine flag and reopens the app. Arguments are passed positionally, never interpolated.
    private static func launchSwapper(staged: URL, target: URL) throws {
        let script = SwapScript.text
        let file = staged.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("swap.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [file.path, String(getpid()), target.path, staged.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw UpdateError.command(exe, text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }
}

/// Lets the download callback (any thread) reach the controller on the main queue without a Sendable capture.
private final class WeakBox: @unchecked Sendable {
    weak var controller: UpdateController?
    init(_ c: UpdateController) { controller = c }
}

enum UpdateError: LocalizedError {
    case badResponse, noChecksum(String), checksumMismatch, wrongApp, command(String, String)
    var errorDescription: String? {
        switch self {
        case .badResponse: return "The update server did not answer as expected."
        case .noChecksum(let n): return "The release has no checksum for \(n)."
        case .checksumMismatch: return "The downloaded file is damaged (checksum mismatch)."
        case .wrongApp: return "The downloaded file is not the expected MacScreen version."
        case .command(let c, let o): return "\((c as NSString).lastPathComponent) failed: \(o)"
        }
    }
}

/// Minimal HTTPS file download with progress.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progress: @Sendable (Int) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    private init(destination: URL, progress: @escaping @Sendable (Int) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> URL {
        let d = Downloader(destination: destination, progress: progress)
        return try await d.run(url)
    }

    private func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            continuation = c
            let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            session = s
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue("MacScreen/\(UpdateController.currentVersion)", forHTTPHeaderField: "User-Agent")
            s.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        if total > 0 { progress(Int(Double(written) / Double(total) * 100)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let ok = (downloadTask.response as? HTTPURLResponse)?.statusCode == 200
        do {
            guard ok else { throw UpdateError.badResponse }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { finish(.failure(error)) }
    }

    private func finish(_ r: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        session?.finishTasksAndInvalidate()
        c.resume(with: r)
    }
}
