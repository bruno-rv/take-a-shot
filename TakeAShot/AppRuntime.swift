import AppKit
import Foundation

@MainActor
final class AppSceneActions {
    var openEditor: () -> Void = {}
    var openSettings: () -> Void = {}
}

@MainActor
final class AppRuntime<Registrar: HotKeyRegistering>: ObservableObject {
    let appState: AppState
    let hotKeyController: HotKeyController<Registrar>
    let postCapturePanel: PostCapturePanelCoordinator
    let shortcutStore: ShortcutPreferenceStore
    let sceneActions: AppSceneActions

    private let dismissPanel: () -> Void
    private let captureArea: () -> Void
    private let presentPanel: (CapturedImage, AreaSelection, PostCaptureActions) -> Void
    private let copyCapture: () async -> Bool
    private let saveCapture: () async -> Bool
    private let activateApp: () -> Void

    init(
        appState: AppState,
        hotKeyController: HotKeyController<Registrar>,
        postCapturePanel: PostCapturePanelCoordinator,
        shortcutStore: ShortcutPreferenceStore,
        sceneActions: AppSceneActions,
        dismissPanel: (() -> Void)? = nil,
        captureArea: (() -> Void)? = nil,
        presentPanel: ((CapturedImage, AreaSelection, PostCaptureActions) -> Void)? = nil,
        copyCapture: (() async -> Bool)? = nil,
        saveCapture: (() async -> Bool)? = nil,
        activateApp: (() -> Void)? = nil
    ) {
        self.appState = appState
        self.hotKeyController = hotKeyController
        self.postCapturePanel = postCapturePanel
        self.shortcutStore = shortcutStore
        self.sceneActions = sceneActions
        self.dismissPanel = dismissPanel ?? { postCapturePanel.dismiss() }
        self.captureArea = captureArea ?? {
            appState.capture(mode: .area, options: CaptureOptions())
        }
        self.presentPanel = presentPanel ?? { capture, selection, actions in
            postCapturePanel.present(
                capture: capture,
                selection: selection,
                actions: actions
            )
        }
        self.copyCapture = copyCapture ?? {
            await appState.copyActiveCaptureForPostCapture()
        }
        self.saveCapture = saveCapture ?? {
            await appState.saveActiveCaptureForPostCapture(format: .png)
        }
        self.activateApp = activateApp ?? {
            NSApp.activate(ignoringOtherApps: true)
        }
        start()
    }

    func start() {
        hotKeyController.start()
    }

    func beginAreaCapture() {
        dismissPanel()
        captureArea()
    }

    func openEditor() {
        activateApp()
        sceneActions.openEditor()
    }

    func presentPostCapture(capture: CapturedImage, selection: AreaSelection) {
        let actions = PostCaptureActions(
            copy: copyCapture,
            save: saveCapture,
            edit: { [weak self] in
                guard let self else { return false }
                self.openEditor()
                return true
            }
        )
        presentPanel(capture, selection, actions)
    }
}

extension AppRuntime where Registrar == CarbonHotKeyRegistrar {
    static func live() -> AppRuntime<CarbonHotKeyRegistrar> {
        let sceneActions = AppSceneActions()
        let panel = PostCapturePanelCoordinator()
        let store = ShortcutPreferenceStore()
        var presentPostCapture: ((CapturedImage, AreaSelection) -> Void)?
        var beginAreaCapture: (() -> Void)?
        let appState = AppState.live { capture, selection in
            presentPostCapture?(capture, selection)
        }
        let hotKeyController = HotKeyController(
            registrar: CarbonHotKeyRegistrar(),
            store: store,
            action: { beginAreaCapture?() }
        )
        let runtime = AppRuntime(
            appState: appState,
            hotKeyController: hotKeyController,
            postCapturePanel: panel,
            shortcutStore: store,
            sceneActions: sceneActions
        )
        presentPostCapture = { [weak runtime] capture, selection in
            runtime?.presentPostCapture(capture: capture, selection: selection)
        }
        beginAreaCapture = { [weak runtime] in
            runtime?.beginAreaCapture()
        }
        return runtime
    }
}
