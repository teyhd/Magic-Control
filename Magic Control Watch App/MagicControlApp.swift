import SwiftUI

@main
struct MagicControlApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    await appState.onLaunch()
                }
        }
    }
}
