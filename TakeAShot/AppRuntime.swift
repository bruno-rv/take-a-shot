import AppKit
import Combine
import Foundation

@MainActor
protocol RuntimeErrorPresenting: AnyObject {
    func present(
        _ error: PresentedError,
        recovery: @escaping () -> Void,
        dismiss: @escaping () -> Void
    )
    func dismiss()
}

@MainActor
final class RuntimeErrorPresenter: RuntimeErrorPresenting {
    private var alert: NSAlert?

    func present(
        _ error: PresentedError,
        recovery: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.dismiss()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error.title
        alert.informativeText = error.message
        if let recovery = error.recovery {
            alert.addButton(withTitle: recovery.title)
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }
        alert.window.level = .floating
        self.alert = alert
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor [weak self, weak alert] in
            guard let self, let alert, self.alert === alert else { return }
            let response = alert.runModal()
            guard self.alert === alert else { return }
            self.alert = nil
            if error.recovery != nil, response == .alertFirstButtonReturn {
                recovery()
            } else {
                dismiss()
            }
        }
    }

    func dismiss() {
        guard let alert else { return }
        self.alert = nil
        if NSApp.modalWindow === alert.window {
            NSApp.stopModal(withCode: .abort)
        }
        alert.window.close()
    }
}

@MainActor
final class AppSceneActions {
    var openEditor: () -> Void = {}
    var openSettings: () -> Void = {}

    func install(
        openEditor: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.openEditor = openEditor
        self.openSettings = openSettings
    }
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
    private let copyCapture: (CapturedImage, AnnotationDocument) async -> Bool
    private let saveCapture: (CapturedImage, AnnotationDocument) async -> Bool
    private let errorPresenter: any RuntimeErrorPresenting
    private let activateApp: () -> Void
    private var errorSubscription: AnyCancellable?

    init(
        appState: AppState,
        hotKeyController: HotKeyController<Registrar>,
        postCapturePanel: PostCapturePanelCoordinator,
        shortcutStore: ShortcutPreferenceStore,
        sceneActions: AppSceneActions,
        dismissPanel: (() -> Void)? = nil,
        captureArea: (() -> Void)? = nil,
        presentPanel: ((CapturedImage, AreaSelection, PostCaptureActions) -> Void)? = nil,
        copyCapture: ((CapturedImage, AnnotationDocument) async -> Bool)? = nil,
        saveCapture: ((CapturedImage, AnnotationDocument) async -> Bool)? = nil,
        errorPresenter: (any RuntimeErrorPresenting)? = nil,
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
        self.copyCapture = copyCapture ?? { capture, document in
            await appState.copyCaptureForPostCapture(capture, document: document)
        }
        self.saveCapture = saveCapture ?? { capture, document in
            await appState.saveCaptureForPostCapture(
                capture,
                document: document,
                format: .png
            )
        }
        self.errorPresenter = errorPresenter ?? RuntimeErrorPresenter()
        self.activateApp = activateApp ?? {
            NSApp.activate(ignoringOtherApps: true)
        }
        bindErrorPresentation()
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
        let document = appState.annotationHistory
        let actions = PostCaptureActions(
            copy: { [copyCapture] in await copyCapture(capture, document) },
            save: { [saveCapture] in await saveCapture(capture, document) },
            edit: { [weak self] in
                guard let self else { return false }
                self.openEditor()
                return true
            }
        )
        presentPanel(capture, selection, actions)
    }

    private func bindErrorPresentation() {
        errorSubscription = appState.$presentedError.sink { [weak self] error in
            guard let self else { return }
            guard let error else {
                errorPresenter.dismiss()
                return
            }
            errorPresenter.present(
                error,
                recovery: { [weak appState] in
                    appState?.performPresentedErrorRecovery()
                },
                dismiss: { [weak appState] in
                    appState?.dismissPresentedError()
                }
            )
        }
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
