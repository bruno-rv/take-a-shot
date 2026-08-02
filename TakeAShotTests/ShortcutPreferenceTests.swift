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

    func testRecordingStateIgnoresCancellationFromAReplacedSession() throws {
        var state = ShortcutRecordingState()
        state.begin(.area)
        let stale = try XCTUnwrap(state.session)
        state.begin(.window)

        XCTAssertFalse(state.cancel(stale))
        XCTAssertEqual(state.session?.action, .window)
    }

    func testRecordingStateIgnoresCancellationFromAnEarlierArmingOfTheSameRow() throws {
        var state = ShortcutRecordingState()
        state.begin(.area)
        let stale = try XCTUnwrap(state.session)
        state.begin(.window)
        state.begin(.area)

        XCTAssertFalse(state.cancel(stale))
        XCTAssertEqual(state.session?.action, .area)
    }

    func testRecordingStateCancelsItsOwnSession() throws {
        var state = ShortcutRecordingState()
        state.begin(.record)
        let session = try XCTUnwrap(state.session)

        XCTAssertTrue(state.cancel(session))
        XCTAssertNil(state.session)
        XCTAssertNil(state.session(for: .record))
    }

    func testRecordingStateExposesOnlyTheArmedRow() {
        var state = ShortcutRecordingState()
        state.begin(.fullscreen)

        XCTAssertEqual(state.session(for: .fullscreen)?.action, .fullscreen)
        XCTAssertNil(state.session(for: .area))
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

    func testUnmappedKeyCodesAreNotRecordable() {
        let functionKey = ShortcutPreference(
            keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey)
        )

        XCTAssertTrue(functionKey.isValid)
        XCTAssertFalse(functionKey.hasSupportedKey)
        XCTAssertFalse(functionKey.isRecordable)
        XCTAssertTrue(ShortcutAction.area.defaultPreference.isRecordable)
    }

    func testConflictReportsTheActionAlreadyHoldingTheShortcut() {
        var assignments = Dictionary(
            uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultPreference) }
        )
        assignments[.captureGlobal] = ShortcutPreference.default

        XCTAssertEqual(
            ShortcutConflict.holder(
                of: ShortcutAction.area.defaultPreference,
                excluding: .record,
                in: assignments
            ),
            .action(.area)
        )
        XCTAssertNil(
            ShortcutConflict.holder(
                of: ShortcutAction.area.defaultPreference,
                excluding: .area,
                in: assignments
            )
        )
    }

    @MainActor
    func testCarbonBackedActionsAcceptKeysWithoutACharacterEquivalent() throws {
        let suite = "ShortcutPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutPreferencesStore(defaults: defaults)
        let functionKey = ShortcutPreference(
            keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey)
        )
        let arrow = ShortcutPreference(
            keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | optionKey)
        )

        // Manual Scroll finishes its session through a Carbon hotkey.
        XCTAssertFalse(ShortcutAction.scrollingManual.requiresMappableKey)
        XCTAssertTrue(store.save(functionKey, for: .scrollingManual))
        XCTAssertEqual(store.preference(for: .scrollingManual), functionKey)
        XCTAssertTrue(store.save(arrow, for: .scrollingManual))

        // The editor-only actions have nothing but `keyboardShortcut`.
        XCTAssertTrue(ShortcutAction.area.requiresMappableKey)
        XCTAssertFalse(store.save(functionKey, for: .area))
    }

    func testEditingCommandsAreReserved() {
        let copy = ShortcutPreference(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))
        let selectAll = ShortcutPreference(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey))

        XCTAssertEqual(
            ShortcutConflict.holder(of: copy, excluding: .area, in: [:]), .reserved("Copy")
        )
        XCTAssertEqual(
            ShortcutConflict.holder(of: selectAll, excluding: .area, in: [:]),
            .reserved("Select All")
        )
    }

    func testStandardWindowCommandsAreReserved() {
        let closeWindow = ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey)
        )
        let quit = ShortcutPreference(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey))

        XCTAssertEqual(
            ShortcutConflict.holder(of: closeWindow, excluding: .area, in: [:]),
            .reserved("Close Window")
        )
        XCTAssertEqual(
            ShortcutConflict.holder(of: quit, excluding: .record, in: [:]),
            .reserved("Quit")
        )
    }

    func testNoDefaultShortcutTouchesAReservedCommand() {
        for action in ShortcutAction.allCases {
            XCTAssertNil(
                ShortcutConflict.holder(
                    of: action.defaultPreference, excluding: action, in: [:]
                ),
                "\(action.displayLabel) default collides with a reserved command"
            )
        }
    }

    func testFirstConflictReportsAStoredDuplicateInActionOrder() throws {
        var assignments = Dictionary(
            uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultPreference) }
        )
        assignments[.record] = ShortcutAction.area.defaultPreference

        let conflict = try XCTUnwrap(ShortcutConflict.firstConflict(in: assignments))

        XCTAssertEqual(conflict.action, .record)
        XCTAssertEqual(conflict.holder, .action(.area))
        XCTAssertEqual(conflict.preference, ShortcutAction.area.defaultPreference)
    }

    func testFirstConflictReportsAStoredReservedCommand() throws {
        var assignments = Dictionary(
            uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultPreference) }
        )
        assignments[.window] = ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey)
        )

        let conflict = try XCTUnwrap(ShortcutConflict.firstConflict(in: assignments))

        XCTAssertEqual(conflict.action, .window)
        XCTAssertEqual(conflict.holder, .reserved("Undo"))
    }

    func testDefaultAssignmentsReportNoConflict() {
        let assignments = Dictionary(
            uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultPreference) }
        )

        XCTAssertNil(ShortcutConflict.firstConflict(in: assignments))
    }

    func testKeysWithoutACharacterEquivalentStillReadable() {
        let functionKey = ShortcutPreference(
            keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey)
        )

        XCTAssertEqual(functionKey.displayName, "⌘F5")
    }

    func testFixedEditorCommandsAreReservedAgainstRecording() {
        let undo = ShortcutPreference(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey))

        XCTAssertEqual(
            ShortcutConflict.holder(of: undo, excluding: .area, in: [:]),
            .reserved("Undo")
        )
    }

    @MainActor
    func testPreferencesStoreKeepsStoredUnmappedKeysButRefusesNewOnes() throws {
        let suite = "ShortcutPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let functionKey = ShortcutPreference(
            keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey)
        )
        // A value an earlier build accepted, written straight to the domain.
        try ShortcutPreferenceStore(
            defaults: defaults, key: ShortcutAction.scrollingManual.storageKey
        ).save(functionKey)

        let store = ShortcutPreferencesStore(defaults: defaults)

        // Manual Scroll registers its session hotkey through Carbon, so the
        // stored value survives an upgrade even though it can't drive the
        // editor button.
        XCTAssertEqual(store.preference(for: .scrollingManual), functionKey)
        XCTAssertFalse(store.save(functionKey, for: .record))
    }

    func testDefaultShortcutsDoNotCollide() {
        let defaults = ShortcutAction.allCases.map(\.defaultPreference)

        XCTAssertEqual(Set(defaults.map(\.displayName)).count, defaults.count)
    }

    func testRecordingStateRejectsShortcutsFromAReplacedSession() throws {
        var state = ShortcutRecordingState()
        state.begin(.record)
        let stale = try XCTUnwrap(state.session)
        state.begin(.area)
        let current = try XCTUnwrap(state.session)

        XCTAssertFalse(state.isActive(stale))
        XCTAssertTrue(state.isActive(current))
    }

    /// The settings window advertises a Record shortcut, so something has to
    /// honour it — the recording bar's start/stop buttons are the only place
    /// that can.
    func testRecordingBarHonoursTheConfiguredRecordShortcut() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let editorSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "TakeAShot/MacContentView.swift"
            ),
            encoding: .utf8
        )
        let barSource = try XCTUnwrap(
            editorSource.range(of: "struct MacRecordingBar: View {")
                .map { String(editorSource[$0.lowerBound...]) }
        )

        XCTAssertEqual(
            barSource.components(
                separatedBy: ".keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)"
            ).count - 1,
            2,
            "both the start and stop buttons should carry the Record shortcut"
        )
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
