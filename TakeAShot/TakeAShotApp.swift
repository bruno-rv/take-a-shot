import SwiftUI

@main
struct TakeAShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.live()

    var body: some Scene {
        WindowGroup {
            MacContentView()
                .frame(minWidth: 1040, minHeight: 720)
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)
    }
}
