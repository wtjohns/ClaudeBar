import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Plain stack rather than a ScrollView: content is bounded, and a ScrollView in a
            // MenuBarExtra either collapses (macOS Tahoe) or clips at a fixed height.
            VStack(spacing: 0) {
                if state.showClaude {
                    usageSection
                }
                if state.showCodex {
                    if state.showClaude { Divider().padding(.horizontal, 12) }
                    codexSection
                }
                if state.showBilling, state.billingInfo != nil || state.adminApiData != nil {
                    Divider().padding(.horizontal, 12)
                    billingSection
                }
                if state.showBilling, state.adminApiData != nil {
                    Divider().padding(.horizontal, 12)
                    adminApiSection
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if state.showLog {
                Divider()
                logSection
            }
            Divider()
            footer
        }
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(state.showCodex ? "Usage" : "Claude Usage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let updated = state.lastUpdated {
                Text(updated, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await state.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(state.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }


    // MARK: - Usage Section

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Claude")
            if state.isLoading && state.claudeUsage == nil {
                loadingRow
            } else if state.claudeUsage?.isAuthenticated == false || state.claudeUsage == nil {
                loginPrompt("Login to Claude to see usage") {
                    state.openClaudeLogin()
                }
            } else if let bars = state.claudeUsage?.bars, !bars.isEmpty {
                ForEach(bars) { bar in
                    UsageBarRow(bar: bar)
                }
            } else {
                Text("No usage data")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Codex Section

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(state.codexUsage?.plan.map { "Codex · \($0.capitalized)" } ?? "Codex")
            if let usage = state.codexUsage {
                ForEach(usage.bars) { bar in
                    UsageBarRow(bar: bar)
                }
                if let asOf = usage.snapshotDate {
                    // Fallback data from Codex's session log, not a live reading
                    Text("From Codex session log · as of \(asOf.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
            } else if state.isLoading {
                loadingRow
            } else {
                Text(state.isCodexSignedIn ? "Codex usage unavailable" : "Sign in to Codex to see usage")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Billing Section

    private var billingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("API Credit Balance")
            if let billing = state.billingInfo {
                HStack {
                    if let balance = billing.creditBalance {
                        Text(String(format: "$%.2f", balance))
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        Text("remaining")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Balance unavailable")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Admin API Section

    private var adminApiSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Admin API — Last 30 Days")
            if let data = state.adminApiData {
                AdminApiView(data: data)
            }
        }
    }

    // MARK: - Log Section

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Auto-refreshes every 60s")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
            if !state.logs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(state.logs) { log in
                            HStack(spacing: 4) {
                                Text(log.timestamp, style: .time)
                                    .monospacedDigit()
                                Text(log.message)
                            }
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
                }
                .frame(height: 60)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if state.showClaude, state.claudeUsage?.isAuthenticated != true {
                Button("Login to Claude") { state.openClaudeLogin() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
            }

            if state.showBilling, state.billingInfo == nil {
                Button("Connect Platform") { state.openPlatformLogin() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let status = state.updateStatus, state.availableUpdate != nil {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let update = state.availableUpdate {
                Button("Update to \(update.version)") {
                    Task { await state.installUpdate() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.blue)
            }

            Button("Settings") { openSettings() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button("Quit") { state.quit() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private var loadingRow: some View {
        HStack {
            ProgressView().scaleEffect(0.7)
            Text("Loading…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func loginPrompt(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                Text(text)
                    .font(.system(size: 12))
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func openSettings() {
        SettingsWindowController.open(state: state)
    }
}

// MARK: - UsageBarRow

struct UsageBarRow: View {
    let bar: UsageBar

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(bar.label)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(bar.percentage))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(barColor)
            }
            ProgressView(value: min(bar.percentage / 100, 1.0))
                .tint(barColor)
                .scaleEffect(x: 1, y: 1.5, anchor: .center)
            if !bar.resetInfo.isEmpty {
                Text(bar.resetInfo)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var barColor: Color {
        switch bar.percentage {
        case ..<50: return .green
        case ..<80: return .yellow
        default: return .red
        }
    }
}

// MARK: - AdminApiView

struct AdminApiView: View {
    let data: AdminApiData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Token totals
            HStack(spacing: 16) {
                statPill("Input", value: formatTokens(data.usage.totalInputTokens))
                statPill("Output", value: formatTokens(data.usage.totalOutputTokens))
                statPill("Cached", value: formatTokens(data.usage.totalCachedTokens))
            }
            .padding(.horizontal, 12)

            // Cost + credit
            HStack {
                Text(String(format: "Cost: $%.2f", data.cost.totalCost))
                    .font(.system(size: 12, design: .monospaced))
                if let credit = data.creditBalance {
                    Spacer()
                    Text(String(format: "Credit: $%.2f", credit))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)

            // Top models
            if !data.usage.byModel.isEmpty {
                Text("Top models")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                    .padding(.horizontal, 12)
                ForEach(data.usage.byModel.prefix(3), id: \.model) { entry in
                    HStack {
                        Text(shortModelName(entry.model))
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer()
                        Text(formatTokens(entry.tokens))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func statPill(_ label: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func formatTokens(_ n: Int) -> String {
        switch n {
        case 0..<1_000: return "\(n)"
        case 0..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    private func shortModelName(_ model: String) -> String {
        // "claude-3-5-sonnet-20241022" -> "claude-3-5-sonnet"
        let parts = model.split(separator: "-")
        if parts.count > 4, parts.last?.count == 8 {
            return parts.dropLast().joined(separator: "-")
        }
        return model
    }
}
