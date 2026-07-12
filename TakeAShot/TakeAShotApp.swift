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
    @StateObject private var appState: AppState

    init() {
        let state = AppState.live()
        _appState = StateObject(wrappedValue: state)
        ApplicationLifecycle.terminationCoordinator = ApplicationTerminationCoordinator(
            flush: state.prepareForTermination,
            onFailure: { error in
                state.present(error, title: "Could Not Quit Safely")
            }
        )
    }

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

extension AppDelegate {
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
