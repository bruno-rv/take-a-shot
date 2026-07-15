import AppKit
import XCTest
@testable import TakeAShot

final class AppRuntimeTests: XCTestCase {
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

    func testSceneActionsAreInstalledByAlwaysInstantiatedMenuBarLabel() throws {
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

        XCTAssertTrue(
            appSource.contains(
                "MenuBarSceneBridge(sceneActions: runtime.sceneActions)"
            ),
            "The persistent menu-bar label must install scene actions at launch"
        )
        XCTAssertFalse(
            menuSource.contains("runtime.sceneActions.openEditor ="),
            "Lazy menu content must not own scene-action installation"
        )
    }

    private func makeCapture() throws -> CapturedImage {
        let image = try TestImage.solid(width: 2, height: 2, color: .blue)
        return CapturedImage(
            id: UUID(),
            kind: .area,
            title: "Capture",
            createdAt: Date(),
            image: image,
            pixelSize: PixelSize(width: 2, height: 2)
        )
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
            copyCapture: { true },
            saveCapture: { true },
            activateApp: activateApp
        )
    }
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
