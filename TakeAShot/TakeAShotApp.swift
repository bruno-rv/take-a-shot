import AppKit
import SwiftUI

@MainActor
final class ApplicationTerminationCoordinator {
    private let flush: @MainActor () async throws -> Void
    private let onFailure: @MainActor (Error) -> Void
    private var task: Task<Void, Never>?

    init(
        flush: @escaping @MainActor () async throws -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.flush = flush
        self.onFailure = onFailure
    }

    func beginTermination(reply: @escaping @MainActor (Bool) -> Void) {
        guard task == nil else { return }
        task = Task { [weak self, flush, onFailure] in
            defer { self?.task = nil }
            do {
                try await flush()
                reply(true)
            } catch {
                onFailure(error)
                reply(false)
            }
        }
    }
}

@MainActor
private enum ApplicationLifecycle {
    static var terminationCoordinator: ApplicationTerminationCoordinator?
}

@main
struct TakeAShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var runtime: AppRuntime<CarbonHotKeyRegistrar>

    init() {
        let runtime = AppRuntime<CarbonHotKeyRegistrar>.live()
        _runtime = StateObject(wrappedValue: runtime)
        ApplicationLifecycle.terminationCoordinator = ApplicationTerminationCoordinator(
            flush: runtime.appState.prepareForTermination,
            onFailure: { error in
                runtime.appState.present(error, title: "Could Not Quit Safely")
            }
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(runtime: runtime)
        } label: {
            MenuBarSceneBridge(sceneActions: runtime.sceneActions)
        }

        EditorWindowScene(runtime: runtime)

        Settings {
            ShortcutSettingsView(
                controller: runtime.hotKeyController,
                preferencesStore: runtime.shortcutPreferencesStore
            )
        }
    }
}

/// The editor `Window` scene, isolated in its own `Scene` for clarity.
///
/// SwiftUI presents `Window` scenes automatically at launch unless told
/// otherwise. `.defaultLaunchBehavior(.suppressed)` (macOS 15+) would be the
/// scene-level fix, but this project's deployment target is macOS 14, and
/// guarding that call with `#available`/`#unavailable` inside a `Scene`'s
/// body crashes the Swift 6/Xcode 26.5 type-checker on this toolchain
/// ("failed to produce diagnostic for expression") — reproduced in isolation
/// with a minimal `Window` + `#unavailable` scene, independent of this file.
/// `SceneBuilder` also has no `buildEither`, so `if/else` isn't an option
/// either. Instead, `AppDelegate.applicationDidFinishLaunching` closes the
/// window synchronously before the run loop's first pass (see below) — an
/// availability-safe alternative that works identically on every macOS
/// version, so there's no untested branch.
private struct EditorWindowScene: Scene {
    let runtime: AppRuntime<CarbonHotKeyRegistrar>

    var body: some Scene {
        Window("Take a Shot", id: "editor") {
            editorContent
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)
    }

    private var editorContent: some View {
        MacContentView(
            shortcutController: runtime.hotKeyController,
            shortcutPreferencesStore: runtime.shortcutPreferencesStore
        )
        .frame(minWidth: 1040, minHeight: 720)
        .environmentObject(runtime.appState)
    }
}

extension AppDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        suppressAutomaticEditorWindow()
    }

    // ponytail: `.defaultLaunchBehavior(.suppressed)` (macOS 15+) can't be
    // used — see the comment on EditorWindowScene in this file for why.
    // Close the auto-presented editor window here, before the run loop has
    // a chance to draw it, so only the menu bar icon appears at launch.
    @MainActor
    private func suppressAutomaticEditorWindow() {
        for window in NSApp.windows
        where window.title == "Take a Shot" || window.identifier?.rawValue.contains("editor") == true {
            window.close()
        }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = ApplicationLifecycle.terminationCoordinator else {
            return .terminateNow
        }
        coordinator.beginTermination { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }
}
