import AppKit
import XCTest
@testable import TakeAShot

final class AppRuntimeTests: XCTestCase {
    @MainActor
    func testRuntimePresentsStateErrorsWithoutAnEditor() {
        let presenter = RuntimeErrorPresenterSpy()
        let fixture = RuntimeFixture(errorPresenter: presenter)

        fixture.runtime.appState.present(
            CocoaError(.fileWriteUnknown),
            title: "Capture Failed"
        )

        XCTAssertEqual(presenter.presentedErrors.map(\.title), ["Capture Failed"])
        presenter.dismissAction?()
        XCTAssertNil(fixture.runtime.appState.presentedError)
    }

    @MainActor
    func testBeginningCaptureDismissesPanelBeforeAreaCapture() {
        var events: [RuntimeEvent] = []
        let fixture = RuntimeFixture(
            dismissPanel: { events.append(.dismissPanel) },
            captureArea: { events.append(.captureArea) }
        )

        fixture.runtime.beginAreaCapture()

        XCTAssertEqual(events, [.dismissPanel, .captureArea])
    }

    @MainActor
    func testEditorActionActivatesAfterCaptureIsInstalled() async throws {
        var events: [RuntimeEvent] = []
        var presentedActions: PostCaptureActions?
        let fixture = RuntimeFixture(
            presentPanel: { _, _, actions in
                events.append(.presentPanel)
                presentedActions = actions
            },
            activateApp: { events.append(.activateApp) }
        )
        fixture.sceneActions.openEditor = { events.append(.openEditor) }
        let capture = try makeCapture()
        let selection = AreaSelection(
            localRect: CGRect(x: 10, y: 20, width: 30, height: 40),
            display: DisplayGeometry(
                id: 1,
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                scale: 2
            )
        )

        fixture.runtime.presentPostCapture(capture: capture, selection: selection)
        let actions = try XCTUnwrap(presentedActions)

        let didEdit = await actions.edit()
        XCTAssertTrue(didEdit)
        XCTAssertEqual(events, [.presentPanel, .activateApp, .openEditor])
    }

    /// Seam test for the PostCapturePanel preview bug: `capture.image` (raw) must NOT be what
    /// gets shown when a Baked render is available — `presentPostCapture`'s `previewImage` must
    /// flow all the way into the presented `PostCaptureActions`, exactly like Copy/Save already do
    /// via `document`.
    @MainActor
    func testPresentPostCaptureUsesBakedRenderedImageForPreviewWhenProvided() async throws {
        var presentedActions: PostCaptureActions?
        let fixture = RuntimeFixture(
            presentPanel: { _, _, actions in presentedActions = actions }
        )
        let capture = try makeCapture()
        let rendered = try TestImage.solid(width: 2, height: 2, color: .red)

        fixture.runtime.presentPostCapture(
            capture: capture,
            selection: makeSelection(),
            previewImage: rendered
        )

        let actions = try XCTUnwrap(presentedActions)
        XCTAssertTrue(actions.previewImage === rendered)
        XCTAssertFalse(actions.previewImage === capture.image)
    }

    /// The empty-payload/no-annotation path must keep showing the raw capture — unchanged
    /// behavior when there's nothing to Bake.
    @MainActor
    func testPresentPostCaptureFallsBackToRawCaptureImageWhenNoRenderedImage() async throws {
        var presentedActions: PostCaptureActions?
        let fixture = RuntimeFixture(
            presentPanel: { _, _, actions in presentedActions = actions }
        )
        let capture = try makeCapture()

        fixture.runtime.presentPostCapture(capture: capture, selection: makeSelection())

        let actions = try XCTUnwrap(presentedActions)
        XCTAssertTrue(actions.previewImage === capture.image)
    }

    @MainActor
    func testPanelActionsKeepPresentedCaptureAndDocumentAfterActiveCaptureChanges() async throws {
        var presentedActions: PostCaptureActions?
        var copied: (UUID, UUID)?
        var saved: (UUID, UUID)?
        let fixture = RuntimeFixture(
            presentPanel: { _, _, actions in presentedActions = actions },
            copyCapture: { capture, document in
                copied = (capture.id, document.captureID)
                return true
            },
            saveCapture: { capture, document in
                saved = (capture.id, document.captureID)
                return true
            }
        )
        let captureA = try makeCapture(title: "A")
        let captureB = try makeCapture(title: "B")
        fixture.runtime.appState.receiveCapture(captureA)
        fixture.runtime.presentPostCapture(
            capture: captureA,
            selection: makeSelection()
        )
        fixture.runtime.appState.receiveCapture(captureB)
        try await waitUntil {
            fixture.runtime.appState.activeCapture?.id == captureB.id
        }

        let actions = try XCTUnwrap(presentedActions)
        _ = await actions.copy()
        _ = await actions.save()

        XCTAssertEqual(copied?.0, captureA.id)
        XCTAssertEqual(copied?.1, captureA.id)
        XCTAssertEqual(saved?.0, captureA.id)
        XCTAssertEqual(saved?.1, captureA.id)
    }

    @MainActor
    func testRuntimeStartsHotKeyControllerExactlyOnce() {
        let fixture = RuntimeFixture()

        XCTAssertEqual(fixture.registrar.registrationCount, 1)
        fixture.runtime.start()
        XCTAssertEqual(fixture.registrar.registrationCount, 1)
    }

    func testRecordingUsagePlistMarksApplicationAsUIElement() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let plistURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("TakeAShot/RecordingUsage.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
    }

    @MainActor
    func testInstallingSceneActionsInstallsEditorAndSettingsTogether() {
        let actions = AppSceneActions()
        var events: [String] = []

        actions.install(
            openEditor: { events.append("editor") },
            openSettings: { events.append("settings") }
        )
        actions.openEditor()
        actions.openSettings()

        XCTAssertEqual(events, ["editor", "settings"])
    }

    func testMenuBarLabelInstallsBothSceneActionsWhenItAppears() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TakeAShot")
        let appSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("TakeAShotApp.swift"),
            encoding: .utf8
        )
        let menuSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("MenuBarViews.swift"),
            encoding: .utf8
        )

        XCTAssertNotNil(
            appSource.range(
                of: #"(?s)MenuBarExtra\s*\{.*?\}\s*label:\s*\{\s*MenuBarSceneBridge\(sceneActions:\s*runtime\.sceneActions\)\s*\}"#,
                options: .regularExpression
            ),
            "MenuBarSceneBridge must remain directly inside the persistent label closure"
        )
        XCTAssertNotNil(
            menuSource.range(
                of: #"(?s)struct\s+MenuBarSceneBridge:\s*View\s*\{.*?var\s+body:\s*some\s+View\s*\{.*?\.onAppear\s*\{\s*sceneActions\.install\(\s*openEditor:\s*\{\s*openWindow\(id:\s*\"editor\"\)\s*\},\s*openSettings:\s*\{\s*openSettings\(\)\s*\}\s*\)"#,
                options: .regularExpression
            ),
            "The persistent bridge must install editor and settings actions from onAppear"
        )
    }

    private func makeCapture(title: String = "Capture") throws -> CapturedImage {
        let image = try TestImage.solid(width: 2, height: 2, color: .blue)
        return CapturedImage(
            id: UUID(),
            kind: .area,
            title: title,
            createdAt: Date(),
            image: image,
            pixelSize: PixelSize(width: 2, height: 2)
        )
    }

    private func makeSelection() -> AreaSelection {
        AreaSelection(
            localRect: CGRect(x: 10, y: 20, width: 30, height: 40),
            display: DisplayGeometry(
                id: 1,
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                scale: 2
            )
        )
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 200,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        throw CocoaError(.coderValueNotFound)
    }
}

private enum RuntimeEvent: Equatable {
    case dismissPanel
    case captureArea
    case presentPanel
    case activateApp
    case openEditor
}

@MainActor
private final class RuntimeFixture {
    let registrar = RuntimeHotKeyRegistrar()
    let sceneActions = AppSceneActions()
    let runtime: AppRuntime<RuntimeHotKeyRegistrar>

    init(
        dismissPanel: @escaping () -> Void = {},
        captureArea: @escaping () -> Void = {},
        presentPanel: @escaping (CapturedImage, AreaSelection, PostCaptureActions) -> Void = { _, _, _ in },
        copyCapture: @escaping (CapturedImage, AnnotationDocument) async -> Bool = { _, _ in true },
        saveCapture: @escaping (CapturedImage, AnnotationDocument) async -> Bool = { _, _ in true },
        errorPresenter: (any RuntimeErrorPresenting)? = nil,
        activateApp: @escaping () -> Void = {}
    ) {
        let suite = "AppRuntimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = ShortcutPreferenceStore(defaults: defaults, key: "shortcut")
        let controller = HotKeyController(
            registrar: registrar,
            store: store,
            action: {}
        )
        runtime = AppRuntime(
            appState: .live(),
            hotKeyController: controller,
            postCapturePanel: PostCapturePanelCoordinator(),
            shortcutStore: store,
            sceneActions: sceneActions,
            dismissPanel: dismissPanel,
            captureArea: captureArea,
            presentPanel: presentPanel,
            copyCapture: copyCapture,
            saveCapture: saveCapture,
            errorPresenter: errorPresenter ?? RuntimeErrorPresenterSpy(),
            activateApp: activateApp
        )
    }
}

@MainActor
private final class RuntimeErrorPresenterSpy: RuntimeErrorPresenting {
    private(set) var presentedErrors: [PresentedError] = []
    var recoveryAction: (() -> Void)?
    var dismissAction: (() -> Void)?

    func present(
        _ error: PresentedError,
        recovery: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        presentedErrors.append(error)
        recoveryAction = recovery
        dismissAction = dismiss
    }

    func dismiss() {}
}

private final class RuntimeHotKeyRegistrar: HotKeyRegistering {
    struct Token {}
    private(set) var registrationCount = 0

    func register(
        _ shortcut: ShortcutPreference,
        action: @escaping @MainActor () -> Void
    ) throws -> Token {
        registrationCount += 1
        return Token()
    }

    func unregister(_ token: Token) {}
}
