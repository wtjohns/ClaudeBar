import SwiftUI

@main
struct ClaudeBarApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(appState)
        } label: {
            Text(appState.trayTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
