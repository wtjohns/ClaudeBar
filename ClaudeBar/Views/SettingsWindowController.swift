import AppKit
import SwiftUI

/// Manages a standalone Settings window for entering the Admin API key.
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    private init() {
        let view = SettingsView()
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
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

    static func open() {
        if shared == nil { shared = SettingsWindowController() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @State private var adminKey: String = KeychainService.shared.readAdminKey() ?? ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)

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
                    saved = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(adminKey == (KeychainService.shared.readAdminKey() ?? ""))
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
