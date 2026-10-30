import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var trayTitle: String = "–"
    /// Two-line "C 44% / X 12%" label used when both services are shown; a single
    /// line that wide gets hidden behind the notch on MacBooks with busy menu bars.
    @Published var trayImage: NSImage?
    @Published var claudeUsage: ClaudeUsage?
    @Published var codexUsage: CodexUsage?
    @Published var billingInfo: BillingInfo?
    @Published var adminApiData: AdminApiData?
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var logs: [LogEntry] = []

    // MARK: Display settings (persisted). Disabling a section also stops fetching its data.

    @Published var showClaude: Bool { didSet { settingChanged(showClaude, key: Keys.showClaude) } }
    @Published var showCodex: Bool { didSet { settingChanged(showCodex, key: Keys.showCodex) } }
    @Published var showBilling: Bool { didSet { settingChanged(showBilling, key: Keys.showBilling) } }
    @Published var showLog: Bool { didSet { settingChanged(showLog, key: Keys.showLog) } }

    private enum Keys {
        static let showClaude = "showClaude"
        static let showCodex = "showCodex"
        static let showBilling = "showBilling"
        static let showLog = "showLog"
    }

    /// Last known tray value per service, kept across failed refreshes.
    private var claudeTray: String?
    private var codexTray: String?

    private let scraper = ScraperService.shared
    private let oauth = OAuthService()
    private let codex = CodexService()
    private let adminApi = AdminApiService()
    private var timer: Timer?
    private var billingTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.showClaude: true,
            // Codex is opt-in for existing installs unless Codex is set up on this Mac
            Keys.showCodex: CodexService().isSignedIn,
            Keys.showBilling: true,
            Keys.showLog: true,
        ])
        showClaude = defaults.bool(forKey: Keys.showClaude)
        showCodex = defaults.bool(forKey: Keys.showCodex)
        showBilling = defaults.bool(forKey: Keys.showBilling)
        showLog = defaults.bool(forKey: Keys.showLog)

        scraper.logger = { [weak self] msg in
            Task { @MainActor in self?.addLog(msg) }
        }
        codex.log = { [weak self] msg in self?.addLog("[codex] \(msg)") }
        startTimer()
        Task { await startupRefresh() }
    }

    var isCodexSignedIn: Bool { codex.isSignedIn }

    private func settingChanged(_ enabled: Bool, key: String) {
        UserDefaults.standard.set(enabled, forKey: key)
        updateTrayTitle()
        if enabled { Task { await refresh() } }
    }

    /// On startup the Keychain prompt for session cookies may not be approved yet,
    /// causing the first scrape to fail. Retry up to 3 times with short delays.
    private func startupRefresh() async {
        await refresh()
        for _ in 0..<3 {
            // Billing loads asynchronously and has its own lifecycle; only usage gates retries
            guard showClaude, claudeUsage == nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refresh()
        }
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        addLog("Refreshing…")

        // Codex is fast (one HTTP call or a file read); run it alongside the Claude fetch,
        // which can take up to 30s when it has to fall back to scraping.
        async let codexDone: Void = refreshCodex()
        await refreshClaude()
        await codexDone

        if showBilling { startBillingRefresh() }

        // Admin API (best-effort; enabled by saving a key in Settings)
        if showBilling, let key = KeychainService.shared.readAdminKey() {
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

    private func refreshClaude() async {
        guard showClaude else { return }
        // Prefer the structured OAuth endpoint (needs a Claude Code login);
        // fall back to scraping claude.ai/settings/usage.
        var source = "oauth"
        var usage = await oauth.fetchUsage()
        if usage == nil {
            source = "scraper"
            usage = await scraper.scrapeUsage()
        }

        guard let usage else {
            // Transient failure — keep showing the last good data rather than a login prompt
            addLog("Claude: OAuth and scraper both failed — keeping last value")
            return
        }
        claudeUsage = usage
        if usage.isAuthenticated, !usage.bars.isEmpty {
            let bar = usage.bars.first(where: { $0.label.lowercased().contains("session") }) ?? usage.bars[0]
            claudeTray = "\(Int(bar.percentage))%"
        } else if !usage.isAuthenticated {
            claudeTray = "?"
        }
        updateTrayTitle()
        let authStatus = usage.isAuthenticated ? "authed" : "unauthed"
        addLog("Claude (\(source)): \(usage.bars.count) bars (\(authStatus)), tray=\(trayTitle)")
    }

    private func refreshCodex() async {
        guard showCodex else { return }
        guard let (usage, source) = await codex.fetchUsage() else {
            addLog("Codex: live and session log both failed — keeping last value")
            return
        }
        codexUsage = usage
        if let bar = usage.bars.first {
            codexTray = "\(Int(bar.percentage))%"
        }
        updateTrayTitle()
        addLog("Codex (\(source == .live ? "live" : "log")): \(usage.bars.map { "\(Int($0.percentage))%" }.joined(separator: "/"))")
    }

    /// Billing is secondary — fetched independently so a timeout doesn't delay the tray.
    /// Skipped if the previous billing scrape is still running.
    private func startBillingRefresh() {
        guard billingTask == nil else { return }
        billingTask = Task {
            let billing = await scraper.scrapeBilling()
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
            billingTask = nil
        }
    }

    /// One service shows a bare percentage; both show a stacked "C 44%" / "X 12%" image.
    private func updateTrayTitle() {
        switch (showClaude, showCodex) {
        case (true, true):
            let claude = "C \(claudeTray ?? "–")", codex = "X \(codexTray ?? "–")"
            trayTitle = "\(claude) · \(codex)"
            trayImage = Self.stackedLabel(claude, codex)
        case (true, false): trayTitle = claudeTray ?? "–"; trayImage = nil
        case (false, true): trayTitle = codexTray ?? "–"; trayImage = nil
        case (false, false): trayTitle = "–"; trayImage = nil
        }
    }

    private static func stackedLabel(_ top: String, _ bottom: String) -> NSImage? {
        let view = VStack(alignment: .leading, spacing: -1) {
            Text(top)
            Text(bottom)
        }
        .font(.system(size: 9, weight: .semibold).monospacedDigit())
        .foregroundStyle(.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = true   // menu bar tints it for light/dark appearance
        return image
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
