import Foundation

/// Reads plan usage from the endpoint Claude Code's `/usage` command uses,
/// authenticated with the OAuth token Claude Code stores in the Keychain.
@MainActor
final class OAuthService {
    /// Response keys in display order. `utilization` is already a 0–100 percentage.
    private static let windows: [(key: String, label: String)] = [
        ("five_hour", "Current session"),
        ("seven_day", "Weekly · All models"),
        ("seven_day_opus", "Weekly · Opus"),
        ("seven_day_sonnet", "Weekly · Sonnet"),
    ]

    // Cached so we don't hit the Keychain every refresh; re-read on 401.
    private var cachedToken: String?

    func fetchUsage() async -> ClaudeUsage? {
        await fetchUsage(retryOnUnauthorized: true)
    }

    private func fetchUsage(retryOnUnauthorized: Bool) async -> ClaudeUsage? {
        if cachedToken == nil { cachedToken = await KeychainService.shared.readClaudeOAuthToken() }
        guard let token = cachedToken,
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeBar", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return nil }

        if status == 401 {
            // Claude Code refreshed the token since we cached it
            cachedToken = nil
            return retryOnUnauthorized ? await fetchUsage(retryOnUnauthorized: false) : nil
        }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let bars = Self.windows.compactMap { key, label -> UsageBar? in
            guard let window = json[key] as? [String: Any],
                  let utilization = (window["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            return UsageBar(label: label,
                            percentage: utilization,
                            resetInfo: Self.resetText(window["resets_at"] as? String))
        }
        return bars.isEmpty ? nil : ClaudeUsage(bars: bars, isAuthenticated: true, plan: nil)
    }

    /// "2026-10-30T15:50:00.239523+00:00" → "Resets at 11:50 AM"
    private static func resetText(_ iso: String?) -> String {
        guard let iso else { return "" }
        // ISO8601DateFormatter can't parse microsecond precision; drop the fraction
        let trimmed = iso.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        guard let date = ISO8601DateFormatter().date(from: trimmed) else { return "" }
        return resetDescription(for: date)
    }
}
