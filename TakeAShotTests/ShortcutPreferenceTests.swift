import Carbon
import XCTest
@testable import TakeAShot

final class ShortcutPreferenceTests: XCTestCase {
    func testDefaultIsShiftCommandOne() {
        XCTAssertEqual(ShortcutPreference.default.keyCode,
                       UInt32(kVK_ANSI_1))
        XCTAssertEqual(ShortcutPreference.default.modifiers,
                       UInt32(shiftKey | cmdKey))
        XCTAssertEqual(ShortcutPreference.default.displayName, "⇧⌘1")
    }

    func testValidationRequiresASupportedModifier() {
        XCTAssertFalse(ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_1), modifiers: 0
        ).isValid)
        XCTAssertTrue(ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey)
        ).isValid)
    }

    func testStoreRoundTripsAndFallsBackToDefault() throws {
        let suite = "ShortcutPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutPreferenceStore(defaults: defaults,
                                            key: "captureShortcut")

        XCTAssertEqual(store.load(), .default)
        let custom = ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_2),
            modifiers: UInt32(optionKey | cmdKey)
        )
        try store.save(custom)
        XCTAssertEqual(store.load(), custom)
    }

    @MainActor
    func testCustomShortcutUpdatesBothEditorGuidanceLocations() throws {
        let suite = "ShortcutGuidanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = HotKeyController(
            registrar: ShortcutGuidanceRegistrar(),
            store: ShortcutPreferenceStore(defaults: defaults, key: "shortcut"),
            action: {}
        )
        controller.start()
        let custom = ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_2),
            modifiers: UInt32(optionKey | cmdKey)
        )
        XCTAssertTrue(controller.replace(with: custom))

        let guidance = CaptureShortcutGuidance(
            shortcut: controller.currentShortcut
        )

        XCTAssertEqual(guidance.railText, "Global shortcut: ⌥⌘2")
        XCTAssertEqual(guidance.emptyCanvasText, "Press ⌥⌘2 to capture")
    }

    @MainActor
    func testPreferencesStoreRoundTripsPerActionAndFallsBackToDefault() throws {
        let suite = "ShortcutPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.preference(for: .area), ShortcutAction.area.defaultPreference)

        let custom = ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_9),
            modifiers: UInt32(controlKey | shiftKey)
        )
        XCTAssertTrue(store.save(custom, for: .area))
        XCTAssertEqual(store.preference(for: .area), custom)
        XCTAssertEqual(store.preference(for: .window), ShortcutAction.window.defaultPreference)

        let reloaded = ShortcutPreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.preference(for: .area), custom)
    }

    @MainActor
    func testPreferencesStoreRejectsModifierlessShortcut() throws {
        let suite = "ShortcutPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutPreferencesStore(defaults: defaults)

        let invalid = ShortcutPreference(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)
        XCTAssertFalse(store.save(invalid, for: .area))
        XCTAssertEqual(store.preference(for: .area), ShortcutAction.area.defaultPreference)
    }

    @MainActor
    func testPreferencesStoreResetToDefaults() throws {
        let suite = "ShortcutPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutPreferencesStore(defaults: defaults)
        _ = store.save(
            ShortcutPreference(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey)),
            for: .record
        )

        store.resetToDefaults()

        for action in ShortcutPreferencesStore.managedActions {
            XCTAssertEqual(store.preference(for: action), action.defaultPreference)
        }
    }

    func testCaptureGlobalStorageKeyMigratesLegacyKey() {
        XCTAssertEqual(ShortcutAction.captureGlobal.storageKey, "captureShortcut")
    }

    func testManualScrollDefaultShortcutIsControlOptionShiftS() {
        let preference = ShortcutAction.scrollingManual.defaultPreference
        XCTAssertEqual(preference.keyCode, UInt32(kVK_ANSI_S))
        XCTAssertEqual(preference.modifiers, UInt32(controlKey | optionKey | shiftKey))
        XCTAssertEqual(preference.displayName, "⌃⌥⇧S")
        XCTAssertTrue(ShortcutPreferencesStore.managedActions.contains(.scrollingManual))
    }

    func testMenuDoesNotAdvertiseStaleDefaultShortcutEquivalent() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let editorSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "TakeAShot/MacContentView.swift"
            ),
            encoding: .utf8
        )
        let menuSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "TakeAShot/MenuBarViews.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(editorSource.contains("Shift Command 1"))
        XCTAssertFalse(menuSource.contains(#".keyboardShortcut("1""#))
    }
}

private final class ShortcutGuidanceRegistrar: HotKeyRegistering {
    struct Token {}

    func register(
        _ shortcut: ShortcutPreference,
        action: @escaping @MainActor () -> Void
    ) throws -> Token {
        Token()
    }

    func unregister(_ token: Token) {}
}
