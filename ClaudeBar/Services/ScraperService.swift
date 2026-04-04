import Foundation
import WebKit

// MARK: - JavaScript payloads

private let usageJS = """
(function() {
    const usage = { bars: [], resetDate: null, isAuthenticated: true, plan: null };

    const href = window.location.href;
    if (href.includes('/login') || href.includes('/signup')) {
        usage.isAuthenticated = false;
        return JSON.stringify(usage);
    }
    const text = document.body.innerText;
    if ((text.includes('Welcome back') || text.includes('Log in')) && text.includes('Continue with')) {
        usage.isAuthenticated = false;
        return JSON.stringify(usage);
    }

    const lines = text.split('\\n').map(l => l.trim()).filter(Boolean);
    const labels = ['Current session','All models','Sonnet only','Extra usage',
                    'Weekly limit','Daily limit','Monthly limit','Standard','Advanced'];

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (!labels.some(l => l.toLowerCase() === line.toLowerCase())) continue;
        let percentage = 0, resetInfo = '';
        for (let j = i + 1; j < Math.min(i + 6, lines.length); j++) {
            const nl = lines[j];
            if (nl.toLowerCase().startsWith('reset')) resetInfo = nl;
            const m = nl.match(/(\\d+)%\\s*used/i);
            if (m) { percentage = parseInt(m[1], 10); break; }
        }
        usage.bars.push({ label: line, percentage, resetInfo });
    }

    // Fallback: grab any "X% used" if no bars found
    if (usage.bars.length === 0) {
        let idx = 0;
        const fallback = ['Current Session','All models','Sonnet only','Extra usage'];
        for (const m of text.matchAll(/(\\d+)%\\s*used/gi)) {
            const pct = parseInt(m[1], 10);
            if (pct >= 0 && pct <= 100 && !usage.bars.some(b => b.percentage === pct)) {
                usage.bars.push({ label: fallback[idx] || 'Usage ' + (idx+1), percentage: pct, resetInfo: '' });
                idx++;
            }
        }
    }

    for (const pat of [/Claude\\s+(Max|Pro|Team|Enterprise|Free)/i, /(Max|Pro|Team|Enterprise)\\s+Plan/i]) {
        const m = text.match(pat);
        if (m) { usage.plan = m[1]; break; }
    }
    if (!usage.plan && (text.includes('Extra usage') || text.includes('All models'))) usage.plan = 'Max';

    return JSON.stringify(usage);
})();
"""

private let billingJS = """
(function() {
    const billing = { creditBalance: null, currency: 'USD', needsLogin: false };
    const text = document.body.innerText;
    if (text.includes('Sign in or create a developer account') ||
        (text.includes('Continue with Google') && text.includes('Continue with email'))) {
        billing.needsLogin = true;
        return JSON.stringify(billing);
    }
    for (const pat of [
        /(?:Credit\\s*balance|Balance|Remaining)[:\\s]*\\$?([\\d,]+\\.\\d{2})/i,
        /\\$([\\d,]+\\.\\d{2})\\s*(?:remaining|credit|balance)/i,
        /US\\$([\\d,]+\\.\\d{2})/,
        /\\$([\\d,]+\\.\\d{2})/
    ]) {
        const m = text.match(pat);
        if (m) { billing.creditBalance = parseFloat(m[1].replace(/,/g, '')); break; }
    }
    return JSON.stringify(billing);
})();
"""

// MARK: - WebScraper helper

/// Wraps a single WKWebView + navigation delegate lifecycle into an async call.
@MainActor
private final class WebScraper: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let js: String
    private var cont: CheckedContinuation<String?, Never>?
    private var resolved = false
    private var timeoutTask: Task<Void, Never>?

    init(js: String) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()      // persistent session = stays logged in
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: cfg)
        self.js = js
        super.init()
        webView.navigationDelegate = self
    }

    func load(url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            self.cont = continuation
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.finish(nil)
            }
            webView.load(URLRequest(url: url))
        }
    }

    // Called on main thread by WKWebView
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let url = webView.url?.absoluteString ?? ""
            if url.contains("/login") || url.contains("/signup") {
                self.finish(nil); return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let result = try? await webView.evaluateJavaScript(self.js)
            self.finish(result as? String)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.finish(nil) }
    }

    private func finish(_ value: String?) {
        guard !resolved else { return }
        resolved = true
        timeoutTask?.cancel()
        cont?.resume(returning: value)
        cont = nil
    }
}

// MARK: - ScraperService

@MainActor
final class ScraperService {
    static let shared = ScraperService()
    private init() {}

    private var usageScraper: WebScraper?
    private var billingScraper: WebScraper?
    private var isScrapingUsage = false
    private var isScrapingBilling = false

    func scrapeUsage() async -> ClaudeUsage? {
        guard !isScrapingUsage else { return nil }
        isScrapingUsage = true
        defer { isScrapingUsage = false; usageScraper = nil }

        let scraper = WebScraper(js: usageJS)
        usageScraper = scraper
        let raw = await scraper.load(url: URL(string: "https://claude.ai/settings/usage")!)
        return parseUsage(raw)
    }

    func scrapeBilling() async -> BillingInfo? {
        guard !isScrapingBilling else { return nil }
        isScrapingBilling = true
        defer { isScrapingBilling = false; billingScraper = nil }

        let scraper = WebScraper(js: billingJS)
        billingScraper = scraper
        let raw = await scraper.load(url: URL(string: "https://platform.claude.com/settings/billing")!)
        return parseBilling(raw)
    }

    // MARK: - Parsers

    private func parseUsage(_ raw: String?) -> ClaudeUsage? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let isAuth = json["isAuthenticated"] as? Bool ?? false
        guard isAuth else {
            return ClaudeUsage(bars: [], isAuthenticated: false, plan: nil)
        }

        let rawBars = json["bars"] as? [[String: Any]] ?? []
        let bars = rawBars.compactMap { b -> UsageBar? in
            guard let label = b["label"] as? String else { return nil }
            let pct = b["percentage"] as? Double ?? (b["percentage"] as? Int).map(Double.init) ?? 0
            let reset = b["resetInfo"] as? String ?? ""
            return UsageBar(label: label, percentage: pct, resetInfo: reset)
        }

        let validPlans: Set<String> = ["Max", "Pro", "Team", "Enterprise", "Free"]
        let plan = (json["plan"] as? String).flatMap { validPlans.contains($0) ? $0 : nil }

        return ClaudeUsage(
            bars: bars,
            isAuthenticated: true,
            plan: plan
        )
    }

    private func parseBilling(_ raw: String?) -> BillingInfo? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if json["needsLogin"] as? Bool == true { return nil }
        let balance = json["creditBalance"] as? Double
        let currency = json["currency"] as? String ?? "USD"
        return BillingInfo(creditBalance: balance, currency: currency)
    }
}
