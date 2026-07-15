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

        Window("Take a Shot", id: "editor") {
            MacContentView(shortcutController: runtime.hotKeyController)
                .frame(minWidth: 1040, minHeight: 720)
                .environmentObject(runtime.appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)

        Settings {
            ShortcutSettingsView(controller: runtime.hotKeyController)
        }
    }
}

extension AppDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
