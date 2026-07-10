import SwiftUI

@main
struct TakeAShotApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    #endif

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            MacContentView()
                .frame(minWidth: 1040, minHeight: 720)
                .environmentObject(appState)
            #else
            ContentView()
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)
        #endif
    }
}
