import SwiftUI

@main
struct ClaudeBarApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(appState)
        } label: {
            if let image = appState.trayImage {
                Image(nsImage: image)
                    .accessibilityLabel(appState.trayTitle)
            } else {
                Text(appState.trayTitle)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
