import Foundation

/// Reads Codex (ChatGPT plan) rate limits. Live from the ChatGPT usage endpoint using the
/// login Codex stores in ~/.codex/auth.json; falls back to the newest rate-limit snapshot
/// Codex writes into its session logs. Never writes to ~/.codex — Codex owns token refresh.
@MainActor
final class CodexService {
    enum Source { case live, log }

    private let codexHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)

    var log: (String) -> Void = { _ in }

    /// True when ~/.codex/auth.json exists, i.e. the user has signed in to Codex on this Mac.
    var isSignedIn: Bool {
        FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path)
    }

    func fetchUsage() async -> (usage: CodexUsage, source: Source)? {
        if let live = await fetchLive() { return (live, .live) }
        if let snapshot = await readLatestSnapshot() { return (snapshot, .log) }
        return nil
    }

    // MARK: - Live

    private func fetchLive() async -> CodexUsage? {
        guard let data = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = tokens["account_id"] as? String {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeBar", forHTTPHeaderField: "User-Agent")

        guard let (body, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { log("live: network error"); return nil }
        guard status == 200 else {
            log(status == 401 ? "live: token expired — open Codex to refresh it" : "live: HTTP \(status)")
            return nil
        }
        guard let usage = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let limits = usage["rate_limit"] as? [String: Any]
        else { log("live: unexpected response"); return nil }

        let bars = [("primary_window", "5-hour limit"), ("secondary_window", "Weekly limit")]
            .compactMap { key, label -> UsageBar? in
                guard let window = limits[key] as? [String: Any] else { return nil }
                return Self.bar(label: label,
                                usedPercent: window["used_percent"],
                                resetAt: window["reset_at"])
            }
        guard !bars.isEmpty else { return nil }
        return CodexUsage(bars: bars,
                          plan: usage["plan_type"] as? String,
                          limitReached: limits["limit_reached"] as? Bool ?? false,
                          snapshotDate: nil)
    }

    // MARK: - Session-log fallback

    /// Session logs can be hundreds of MB; only the tail is read.
    private nonisolated static let tailBytes = 4 * 1024 * 1024

    private func readLatestSnapshot() async -> CodexUsage? {
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let task = Task.detached(priority: .utility) { () -> CodexUsage? in
            // Long-running sessions keep appending to the file in the folder of the day they
            // started, so pick the newest file by modification date rather than by path.
            guard let file = Self.newestLogFile(in: sessions) else { return nil }
            return Self.lastSnapshot(in: file)
        }
        let result = await task.value
        if result == nil { log("log: no rate-limit snapshot found") }
        return result
    }

    private nonisolated static func newestLogFile(in dir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            if newest == nil || date > newest!.date { newest = (url, date) }
        }
        return newest?.url
    }

    private nonisolated static func lastSnapshot(in file: URL) -> CodexUsage? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }

        // Each line is a JSON event; token_count events carry payload.rate_limits.
        // limit_id "premium" entries have no windows, so only "codex" ones count.
        let marker = Data(#""limit_id":"codex""#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.range(of: marker) != nil,
                  let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any]
            else { continue }

            let bars = [("primary", "5-hour limit"), ("secondary", "Weekly limit")]
                .compactMap { key, label -> UsageBar? in
                    guard let window = limits[key] as? [String: Any] else { return nil }
                    return bar(label: label, usedPercent: window["used_percent"], resetAt: window["resets_at"])
                }
            guard !bars.isEmpty else { continue }

            let timestamp = (event["timestamp"] as? String).flatMap { ts -> Date? in
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return fmt.date(from: ts)
            }
            return CodexUsage(bars: bars,
                              plan: limits["plan_type"] as? String,
                              limitReached: bars.contains { $0.percentage >= 100 },
                              snapshotDate: timestamp)
        }
        return nil
    }

    // MARK: - Helpers

    /// A window whose reset time has passed is shown as reset, so an old snapshot
    /// doesn't report a limit that no longer applies.
    private nonisolated static func bar(label: String, usedPercent: Any?, resetAt: Any?) -> UsageBar? {
        guard let used = (usedPercent as? NSNumber)?.doubleValue else { return nil }
        guard let epoch = (resetAt as? NSNumber)?.doubleValue else {
            return UsageBar(label: label, percentage: used, resetInfo: "")
        }
        let reset = Date(timeIntervalSince1970: epoch)
        if reset <= Date() {
            return UsageBar(label: label, percentage: 0, resetInfo: "Reset since last check")
        }
        return UsageBar(label: label, percentage: used, resetInfo: resetDescription(for: reset))
    }
}
