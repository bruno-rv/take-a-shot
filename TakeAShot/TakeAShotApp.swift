import AppKit
import SwiftUI

@MainActor
final class ApplicationTerminationCoordinator {
    private let flush: @MainActor () async -> Void
    private var task: Task<Void, Never>?

    init(flush: @escaping @MainActor () async -> Void) {
        self.flush = flush
    }

    func beginTermination(reply: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        task = Task { [flush] in
            await flush()
            reply()
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
        ApplicationLifecycle.terminationCoordinator = ApplicationTerminationCoordinator {
            await state.flushPendingAnnotations()
        }
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
        coordinator.beginTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
