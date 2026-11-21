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
    @Published var availableUpdate: AppUpdate?
    /// Shown in the footer/Settings while checking or installing; nil when idle
    @Published var updateStatus: String?

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

    // MARK: Refresh policy
    //
    // The tray refreshes every 60s, but each refresh should be a few small HTTPS requests.
    // Anything that loads a page in WebKit (the scrapers) is throttled hard, because each
    // load spins up WebKit's content and networking processes.

    private enum Interval {
        static let refresh: TimeInterval = 60
        /// Lets macOS batch our wakeups with other work; the cadence stays ~1/min.
        static let refreshTolerance: TimeInterval = 10
        /// WebKit scrape of claude.ai — only when both JSON sources fail.
        static let usageScrape: TimeInterval = 10 * 60
        /// WebKit scrape of the billing page in the background (no JSON endpoint known).
        static let billingBackground: TimeInterval = 30 * 60
        /// ...but opening the popover refreshes billing if it's older than this.
        static let billingOnOpen: TimeInterval = 5 * 60
        /// Admin API: 30-day aggregates, three requests per fetch.
        static let adminApi: TimeInterval = 5 * 60
        /// Opening the popover triggers a refresh if the data is older than this.
        static let staleOnOpen: TimeInterval = 20
    }

    /// Retry schedule after failures: next tick, then 2, 5 and 10 minutes.
    private struct Backoff {
        private static let delays: [TimeInterval] = [60, 120, 300, 600]
        /// Timer tolerance means a tick can land a few seconds early.
        private static let slack: TimeInterval = 15
        private(set) var failures = 0
        private var nextAttempt = Date.distantPast

        var isReady: Bool { Date() >= nextAttempt.addingTimeInterval(-Self.slack) }

        mutating func succeeded() {
            failures = 0
            nextAttempt = .distantPast
        }

        /// Returns the delay until the next attempt.
        @discardableResult
        mutating func failed() -> TimeInterval {
            let delay = Self.delays[min(failures, Self.delays.count - 1)]
            failures += 1
            nextAttempt = Date().addingTimeInterval(delay)
            return delay
        }
    }

    /// Last known tray value per service, kept across failed refreshes.
    private var claudeTray: String?
    private var codexTray: String?

    private let web = ClaudeWebService()
    private let scraper = ScraperService.shared
    private let oauth = OAuthService()
    private let codex = CodexService()
    private let adminApi = AdminApiService()
    private let updater = UpdateService()
    private var timer: Timer?
    private var updateTimer: Timer?
    private var billingTask: Task<Void, Never>?

    private var claudeBackoff = Backoff()
    private var nextUsageScrape = Date.distantPast
    private var lastBillingAttempt = Date.distantPast
    private var nextAdminFetch = Date.distantPast

    /// Why refreshing is paused (system asleep, display off, screen locked, user switched out).
    /// The timer runs only while this is empty.
    private var pauseReasons: Set<String> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

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
        web.log = { [weak self] msg in self?.addLog("[web] \(msg)") }
        codex.log = { [weak self] msg in self?.addLog("[codex] \(msg)") }
        startTimer()
        observeSystemState()
        Task { await startupRefresh() }
        startUpdateChecks()
    }

    var isCodexSignedIn: Bool { codex.isSignedIn }

    private func settingChanged(_ enabled: Bool, key: String) {
        UserDefaults.standard.set(enabled, forKey: key)
        updateTrayTitle()
        if enabled { Task { await refresh(userInitiated: true) } }
    }

    /// On startup the Keychain prompt may not be approved yet, causing the first fetch to fail.
    /// Retry up to 3 times with short delays.
    private func startupRefresh() async {
        await refresh(userInitiated: true)
        for _ in 0..<3 {
            // Billing has its own lifecycle; only usage gates retries
            guard showClaude, claudeUsage == nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refresh(userInitiated: true)
        }
    }

    // MARK: - Refresh

    /// `userInitiated` (refresh button, login, settings change, startup) skips backoff and
    /// the throttles on the slower sources.
    func refresh(userInitiated: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true

        // Codex is fast (one HTTP call or a file read); run it alongside the Claude fetch.
        async let codexDone: Void = refreshCodex()
        await refreshClaude(userInitiated: userInitiated)
        await codexDone

        if showBilling {
            await refreshAdminApiIfDue(userInitiated: userInitiated)
            refreshBillingIfDue(maxAge: userInitiated ? Interval.refresh : Interval.billingBackground)
        }

        lastUpdated = Date()
        isLoading = false
    }

    /// Call when the popover opens: brings stale data up to date while you're looking at it.
    func popoverOpened() {
        // You're clearly at the Mac; recover if a resume notification was missed.
        if !pauseReasons.isEmpty {
            pauseReasons.removeAll()
            startTimer()
        }
        if Date().timeIntervalSince(lastUpdated ?? .distantPast) > Interval.staleOnOpen {
            Task { await refresh() }
        }
        if showBilling { refreshBillingIfDue(maxAge: Interval.billingOnOpen) }
    }

    private func refreshClaude(userInitiated: Bool) async {
        guard showClaude else { return }
        guard userInitiated || claudeBackoff.isReady else { return }

        // 1. claude.ai JSON API with the WebKit session cookie (one HTTPS request)
        // 2. Claude Code's OAuth endpoint (works while Claude Code's token is fresh)
        // 3. Last resort: load claude.ai/settings/usage in WebKit — throttled
        var usage: ClaudeUsage?
        var source = "web"
        var webUnauthorized = false
        switch await web.fetchUsage() {
        case .usage(let u): usage = u
        case .unauthorized: webUnauthorized = true
        case .failed: break
        }
        if usage == nil, let u = await oauth.fetchUsage() {
            usage = u
            source = "oauth"
        }
        if usage == nil, userInitiated || Date() >= nextUsageScrape {
            nextUsageScrape = Date().addingTimeInterval(Interval.usageScrape)
            source = "scraper"
            usage = await scraper.scrapeUsage()
        }

        guard let usage else {
            let delay = claudeBackoff.failed()
            if webUnauthorized {
                // Signed out of claude.ai and no Claude Code token: show the login button
                claudeUsage = ClaudeUsage(bars: [], isAuthenticated: false, plan: nil)
                claudeTray = "?"
                updateTrayTitle()
                addLog("Claude: not signed in — retry in \(Int(delay / 60)) min")
            } else {
                addLog("Claude: all sources failed — keeping last value, retry in \(Int(delay / 60)) min")
            }
            return
        }

        claudeBackoff.succeeded()
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

    /// Admin API (best-effort; enabled by saving a key in Settings). Plain HTTPS, but it pulls
    /// 30 days of aggregates, so it runs every few minutes rather than every tick.
    private func refreshAdminApiIfDue(userInitiated: Bool) async {
        guard userInitiated || Date() >= nextAdminFetch else { return }
        nextAdminFetch = Date().addingTimeInterval(Interval.adminApi)
        guard let key = KeychainService.shared.readAdminKey() else { return }
        do {
            adminApiData = try await adminApi.fetchData(adminKey: key)
            addLog("Admin API: fetched")
        } catch {
            addLog("Admin API: \(error.localizedDescription)")
        }
    }

    /// Billing has no known JSON endpoint, so it still loads the billing page in WebKit.
    /// It runs in the background every 30 min and when the popover opens with data older
    /// than 5 min. Skipped entirely when the Admin API already supplies the balance.
    private func refreshBillingIfDue(maxAge: TimeInterval) {
        guard billingTask == nil else { return }
        guard adminApiData?.creditBalance == nil else { return }
        guard Date().timeIntervalSince(lastBillingAttempt) >= maxAge else { return }
        lastBillingAttempt = Date()
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
    /// Skips the update (and the image render) when nothing changed.
    private func updateTrayTitle() {
        let title: String
        var stacked: (String, String)?
        switch (showClaude, showCodex) {
        case (true, true):
            let claude = "C \(claudeTray ?? "–")", codex = "X \(codexTray ?? "–")"
            title = "\(claude) · \(codex)"
            stacked = (claude, codex)
        case (true, false): title = claudeTray ?? "–"
        case (false, true): title = codexTray ?? "–"
        case (false, false): title = "–"
        }
        guard title != trayTitle || (stacked != nil) != (trayImage != nil) else { return }
        trayTitle = title
        trayImage = stacked.flatMap { Self.stackedLabel($0.0, $0.1) }
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
        timer?.invalidate()
        let timer = Timer(timeInterval: Interval.refresh, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer.tolerance = Interval.refreshTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stop polling while nobody can see the menu bar: system asleep, display asleep,
    /// screen locked, or the user switched to another account. Refresh on return.
    private func observeSystemState() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pairs: [(center: NotificationCenter, reason: String, pause: Notification.Name, resume: Notification.Name)] = [
            (workspace, "sleep", NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            (workspace, "display", NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            (workspace, "session", NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
            (distributed, "lock", Notification.Name("com.apple.screenIsLocked"), Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for pair in pairs {
            let reason = pair.reason
            let pauseToken = pair.center.addObserver(forName: pair.pause, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pause(reason) }
            }
            let resumeToken = pair.center.addObserver(forName: pair.resume, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resume(reason) }
            }
            observers.append((pair.center, pauseToken))
            observers.append((pair.center, resumeToken))
        }
    }

    private func pause(_ reason: String) {
        let wasRunning = pauseReasons.isEmpty
        pauseReasons.insert(reason)
        guard wasRunning else { return }
        timer?.invalidate()
        timer = nil
        addLog("Paused (\(reason))")
    }

    private func resume(_ reason: String) {
        guard pauseReasons.remove(reason) != nil, pauseReasons.isEmpty else { return }
        startTimer()
        addLog("Resumed (\(reason))")
        guard Date().timeIntervalSince(lastUpdated ?? .distantPast) > Interval.staleOnOpen else { return }
        Task {
            // Give Wi-Fi a moment to reconnect after wake
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refresh()
        }
    }

    // MARK: - Updates

    var currentVersion: String { updater.currentVersion }

    private func startUpdateChecks() {
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)   // let usage load first
            await checkForUpdates()
        }
        let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdates() }
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    /// Background checks stay quiet on failure; user-initiated ones report the result.
    func checkForUpdates(userInitiated: Bool = false) async {
        if userInitiated { updateStatus = "Checking…" }
        do {
            availableUpdate = try await updater.check()
            if let update = availableUpdate {
                addLog("Update available: \(update.version)")
                if userInitiated { updateStatus = nil }
            } else if userInitiated {
                updateStatus = "ClaudeBar \(currentVersion) is up to date"
            }
        } catch {
            addLog("Update check failed: \(error.localizedDescription)")
            if userInitiated { updateStatus = "Update check failed" }
        }
    }

    func installUpdate() async {
        guard let update = availableUpdate else { return }
        do {
            try await updater.install(update) { [weak self] message in self?.updateStatus = message }
        } catch {
            addLog("Update failed: \(error.localizedDescription)")
            updateStatus = "Update failed — opening release page"
            NSWorkspace.shared.open(update.releasePage)
        }
    }

    // MARK: - Login windows

    func openClaudeLogin() {
        LoginWindowController.openClaude { [weak self] in
            Task { @MainActor in
                self?.web.invalidate()
                await self?.refresh(userInitiated: true)
            }
        }
    }

    func openPlatformLogin() {
        LoginWindowController.openPlatform { [weak self] in
            Task { @MainActor in
                self?.lastBillingAttempt = .distantPast
                await self?.refresh(userInitiated: true)
            }
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
