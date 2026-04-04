import Foundation

final class OAuthService {
    func getFiveHourUtilization() async -> String {
        guard let token = KeychainService.shared.readClaudeOAuthToken(),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage")
        else { return "–" }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeBar/1.0.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "–" }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fiveHour = json["five_hour"] as? [String: Any],
               let utilization = fiveHour["utilization"] as? Double {
                return "\(Int((utilization * 100).rounded()))%"
            }
        } catch {}
        return "–"
    }
}
