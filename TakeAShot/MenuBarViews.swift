import AppKit
import SwiftUI

struct MenuBarContent<Registrar: HotKeyRegistering>: View {
    @ObservedObject var runtime: AppRuntime<Registrar>
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Capture Area", systemImage: "camera.viewfinder") {
            runtime.beginAreaCapture()
        }
        .keyboardShortcut("1", modifiers: [.command, .shift])
        .accessibilityHint("Dismisses the preview panel and starts an area selection")

        Button("Open Editor", systemImage: "pencil.and.outline") {
            runtime.openEditor()
        }

        Divider()

        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }

        Divider()

        Button("Quit Take a Shot", systemImage: "power") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
        .onAppear {
            runtime.sceneActions.openEditor = { openWindow(id: "editor") }
            runtime.sceneActions.openSettings = { openSettings() }
        }
    }
}
