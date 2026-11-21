import Foundation

/// Reads plan usage from claude.ai's own JSON API (the request the usage page makes),
/// authenticated with the session cookies the login window left in WebKit's store.
///
/// Each refresh is one small HTTPS request. WebKit is only touched to read cookies:
/// once at launch, after a login, and (throttled) after claude.ai rejects the session.
@MainActor
final class ClaudeWebService {
    enum Result {
        case usage(ClaudeUsage)
        /// No session cookie, or claude.ai rejected it (logged out / expired)
        case unauthorized
        /// Network error, Cloudflare challenge, or a response we don't understand
        case failed
    }

    var log: (String) -> Void = { _ in }

    private var cookies: [HTTPCookie]?
    private var orgId: String?
    /// Earliest time we'll re-read WebKit's cookie store after finding no usable session.
    private var nextCookieRead = Date.distantPast
    private static let cookieRereadInterval: TimeInterval = 5 * 60

    /// Ephemeral, cookie-less session: we send exactly the cookies we read from WebKit.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    /// Call after a login so the next fetch re-reads cookies immediately.
    func invalidate() {
        cookies = nil
        orgId = nil
        nextCookieRead = .distantPast
    }

    func fetchUsage() async -> Result {
        if cookies == nil {
            guard Date() >= nextCookieRead else { return .unauthorized }
            nextCookieRead = Date().addingTimeInterval(Self.cookieRereadInterval)
            let read = await ScraperService.shared.cookies(forDomain: "claude.ai")
            log("read \(read.count) claude.ai cookies")
            guard read.contains(where: { $0.name == "sessionKey" }) else { return .unauthorized }
            cookies = read
        }
        guard let cookies else { return .unauthorized }

        if orgId == nil {
            orgId = cookies.first(where: { $0.name == "lastActiveOrg" })?.value
        }
        if orgId == nil {
            switch await get("/api/organizations", cookies: cookies) {
            case .json(let json):
                let orgs = json as? [[String: Any]] ?? []
                let chatOrg = orgs.first { ($0["capabilities"] as? [String])?.contains("chat") == true }
                orgId = (chatOrg ?? orgs.first)?["uuid"] as? String
            case .unauthorized:
                return rejected()
            case .failed:
                return .failed
            }
        }
        guard let orgId else {
            log("no organization found")
            return .failed
        }

        switch await get("/api/organizations/\(orgId)/usage", cookies: cookies) {
        case .json(let json):
            guard let dict = json as? [String: Any], let usage = OAuthService.parseUsage(dict) else {
                log("unexpected usage response")
                return .failed
            }
            return .usage(usage)
        case .unauthorized:
            return rejected()
        case .failed:
            return .failed
        }
    }

    /// Session expired or logged out: drop it and re-read WebKit's store later (throttled).
    private func rejected() -> Result {
        log("session rejected")
        cookies = nil
        orgId = nil
        return .unauthorized
    }

    // MARK: - HTTP

    private enum Response {
        case json(Any)
        case unauthorized
        case failed
    }

    private func get(_ path: String, cookies: [HTTPCookie]) async -> Response {
        guard let url = URL(string: "https://claude.ai" + path) else { return .failed }
        var request = URLRequest(url: url)
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Same UA as the scraper web view, so Cloudflare sees one consistent client
        request.setValue(ScraperService.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            log("network error")
            return .failed
        }
        let isJSON = http.value(forHTTPHeaderField: "Content-Type")?.contains("json") == true

        if http.statusCode == 200, isJSON, let json = try? JSONSerialization.jsonObject(with: data) {
            return .json(json)
        }
        // claude.ai answers auth failures with a JSON error; a Cloudflare challenge is HTML
        if (http.statusCode == 401 || http.statusCode == 403), isJSON {
            return .unauthorized
        }
        log("HTTP \(http.statusCode)\(isJSON ? "" : " (non-JSON)") for \(path)")
        return .failed
    }
}
