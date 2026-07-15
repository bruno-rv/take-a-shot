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

    func testEditorGuidanceMatchesDefaultShortcut() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "TakeAShot/MacContentView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            #"Text("Global shortcut: Shift Command 1")"#
        ))
        XCTAssertTrue(source.contains(
            #"return "Press Shift Command 1 to capture""#
        ))
    }
}
