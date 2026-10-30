import AppKit
import SwiftUI

/// Manages a standalone Settings window for display options and the Admin API key.
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    private init(state: AppState) {
        let view = SettingsView().environmentObject(state)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClaudeBar Settings"
        window.contentView = host
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func open(state: AppState) {
        if shared == nil { shared = SettingsWindowController(state: state) }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activateCompat()
    }
}

extension NSApplication {
    /// `activate(ignoringOtherApps:)` is deprecated on macOS 14+.
    func activateCompat() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var adminKey: String = KeychainService.shared.readAdminKey() ?? ""
    // Last persisted value — compared against instead of hitting the Keychain on every render
    @State private var storedKey: String = KeychainService.shared.readAdminKey() ?? ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 6) {
                Text("Display")
                    .font(.system(size: 13, weight: .medium))
                // At least one usage service stays on so the menu bar has something to show
                Toggle("Claude usage", isOn: $state.showClaude)
                    .disabled(state.showClaude && !state.showCodex)
                Toggle("Codex usage", isOn: $state.showCodex)
                    .disabled(state.showCodex && !state.showClaude)
                if state.showCodex && !state.isCodexSignedIn {
                    Text("Codex isn't signed in on this Mac (no ~/.codex/auth.json).")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Toggle("API credit balance", isOn: $state.showBilling)
                Toggle("Debug log", isOn: $state.showLog)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Anthropic Admin API Key")
                    .font(.system(size: 13, weight: .medium))
                Text("Optional. Enables 30-day token usage and cost reporting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                SecureField("sk-ant-admin-…", text: $adminKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                if !adminKey.isEmpty {
                    Button("Clear") {
                        KeychainService.shared.deleteAdminKey()
                        adminKey = ""
                        storedKey = ""
                        saved = false
                    }
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("Save") {
                    if adminKey.isEmpty {
                        KeychainService.shared.deleteAdminKey()
                    } else {
                        KeychainService.shared.saveAdminKey(adminKey)
                    }
                    storedKey = adminKey
                    saved = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(adminKey == storedKey)
            }

            if saved {
                Text("Saved. Refresh ClaudeBar to apply.")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
