import AppKit
import CryptoKit

struct AppUpdate {
    let version: String
    let dmgURL: URL
    /// "sha256:<hex>" as reported by the GitHub API, when available
    let digest: String?
    let releasePage: URL
}

/// Checks GitHub releases for a newer version and installs it in place.
///
/// Files the app downloads itself don't get the quarantine flag (only browsers and
/// other quarantine-enabled apps set it), so after the first install, updates don't
/// need the Gatekeeper "Open Anyway" step.
@MainActor
final class UpdateService {
    private let latestReleaseURL = URL(string: "https://api.github.com/repos/wtjohns/ClaudeBar/releases/latest")!

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    enum UpdateError: LocalizedError {
        case badResponse, checksumMismatch, mountFailed, appNotFound, wrongBundle, notWritable

        var errorDescription: String? {
            switch self {
            case .badResponse: return "Couldn't reach GitHub"
            case .checksumMismatch: return "Download checksum didn't match"
            case .mountFailed: return "Couldn't open the downloaded disk image"
            case .appNotFound: return "Disk image doesn't contain ClaudeBar.app"
            case .wrongBundle: return "Downloaded app failed verification"
            case .notWritable: return "No permission to replace the installed app"
            }
        }
    }

    /// Returns the latest release if it's newer than the running version.
    func check() async throws -> AppUpdate? {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let dmgURL = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError.badResponse }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isVersion(version, newerThan: currentVersion) else { return nil }
        return AppUpdate(version: version, dmgURL: dmgURL, digest: dmg["digest"] as? String, releasePage: page)
    }

    /// Downloads, verifies and stages the update, then hands off to a helper that swaps
    /// the app bundle once this process exits and relaunches it. Terminates the app on success.
    func install(_ update: AppUpdate, progress: (String) -> Void) async throws {
        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            throw UpdateError.notWritable
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBar-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        progress("Downloading \(update.version)…")
        let (downloaded, response) = try await URLSession.shared.download(from: update.dmgURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse }
        let dmg = work.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: downloaded, to: dmg)

        if let digest = update.digest, digest.hasPrefix("sha256:") {
            let expected = String(digest.dropFirst("sha256:".count))
            let actual = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw UpdateError.checksumMismatch }
        }

        progress("Installing…")
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        guard await Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly",
                                                  "-noautoopen", "-mountpoint", mount.path]) == 0
        else { throw UpdateError.mountFailed }

        let staged = work.appendingPathComponent("ClaudeBar.app", isDirectory: true)
        let copied = await Self.run("/usr/bin/ditto", [mount.appendingPathComponent("ClaudeBar.app").path, staged.path])
        _ = await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
        guard copied == 0 else { throw UpdateError.appNotFound }

        // Only accept a bundle that is ClaudeBar at the advertised version
        guard let bundle = Bundle(url: staged),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == update.version
        else { throw UpdateError.wrongBundle }

        // Wait for this process to exit, swap bundles (restoring the old one if the copy
        // fails), relaunch, clean up. Arguments are passed positionally to avoid quoting issues.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        if mv "$2" "$2.old" && ditto "$3" "$2"; then rm -rf "$2.old"; else rm -rf "$2"; mv "$2.old" "$2"; fi
        open "$2"
        rm -rf "$4"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                            destination.path, staged.path, work.path]
        try helper.run()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let x = i < lhs.count ? lhs[i] : 0, y = i < rhs.count ? rhs[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func run(_ tool: String, _ args: [String]) async -> Int32 {
        await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { cont.resume(returning: -1) }
        }
    }
}
