import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var trayTitle: String = "–"
    @Published var claudeUsage: ClaudeUsage?
    @Published var billingInfo: BillingInfo?
    @Published var adminApiData: AdminApiData?
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var logs: [LogEntry] = []

    private let scraper = ScraperService.shared
    private let oauth = OAuthService()
    private let adminApi = AdminApiService()
    private var timer: Timer?

    init() {
        scraper.logger = { [weak self] msg in
            Task { @MainActor in self?.addLog(msg) }
        }
        startTimer()
        Task { await startupRefresh() }
    }

    /// On startup the Keychain prompt for session cookies may not be approved yet,
    /// causing the first scrape to fail. Retry up to 3 times with short delays.
    private func startupRefresh() async {
        await refresh()
        for _ in 0..<3 {
            guard claudeUsage == nil || billingInfo == nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refresh()
        }
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        addLog("Refreshing…")

        // Fetch usage first — it drives the tray title
        let usage = await scraper.scrapeUsage()
        claudeUsage = usage

        if let bars = usage?.bars, !bars.isEmpty, usage?.isAuthenticated == true {
            let bar = bars.first(where: {
                $0.label.lowercased().contains("current session") ||
                $0.label.lowercased().contains("session")
            }) ?? bars[0]
            trayTitle = "\(Int(bar.percentage))%"
        } else if usage?.isAuthenticated == false {
            trayTitle = "?"
        } else {
            let oauthTitle = await oauth.getFiveHourUtilization()
            trayTitle = oauthTitle == "–" ? "?" : oauthTitle
        }

        let authStatus = usage.map { $0.isAuthenticated ? "authed" : "unauthed" } ?? "nil"
        addLog("Usage: \(usage?.bars.count ?? 0) bars (\(authStatus)), tray=\(trayTitle)")

        // Billing is secondary — fetch independently so a timeout doesn't delay the tray
        Task {
            let billing = await scraper.scrapeBilling()
            await MainActor.run {
                billingInfo = billing
                if let billing {
                    if let balance = billing.creditBalance {
                        addLog(String(format: "Billing: $%.2f", balance))
                    } else {
                        addLog("Billing: no balance data")
                    }
                } else {
                    addLog("Billing: failed/timeout")
                }
            }
        }

        // Admin API (non-blocking, best-effort)
        if let key = KeychainService.shared.readAdminKey() {
            do {
                adminApiData = try await adminApi.fetchData(adminKey: key)
                addLog("Admin API: fetched")
            } catch {
                addLog("Admin API: \(error.localizedDescription)")
            }
        }

        lastUpdated = Date()
        isLoading = false
    }

    // MARK: - Logging

    func addLog(_ message: String) {
        logs.insert(LogEntry(message: message), at: 0)
        if logs.count > 50 { logs = Array(logs.prefix(50)) }
    }

    // MARK: - Auto-refresh

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // MARK: - Login windows

    func openClaudeLogin() {
        LoginWindowController.openClaude { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func openPlatformLogin() {
        LoginWindowController.openPlatform { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
