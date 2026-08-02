import Carbon
import XCTest
@testable import TakeAShot

final class HotKeyControllerTests: XCTestCase {
    @MainActor
    func testSuccessfulReplacementRegistersBeforePersistingAndUnregistering() {
        let fixture = HotKeyFixture(initial: .default)
        fixture.controller.start()
        let replacement = ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_2),
            modifiers: UInt32(optionKey | cmdKey)
        )

        XCTAssertTrue(fixture.controller.replace(with: replacement))
        XCTAssertEqual(fixture.registrar.events, [
            .register(.default), .register(replacement), .unregister(1)
        ])
        XCTAssertEqual(fixture.store.load(), replacement)
        XCTAssertEqual(fixture.controller.currentShortcut, replacement)
    }

    @MainActor
    func testFailedReplacementKeepsRegistrationAndPreference() {
        let fixture = HotKeyFixture(initial: .default)
        fixture.controller.start()
        fixture.registrar.failNextRegistration = true
        let rejected = ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_3),
            modifiers: UInt32(controlKey | cmdKey)
        )

        XCTAssertFalse(fixture.controller.replace(with: rejected))
        XCTAssertEqual(fixture.registrar.events, [
            .register(.default), .register(rejected)
        ])
        XCTAssertEqual(fixture.store.load(), .default)
        XCTAssertEqual(fixture.controller.currentShortcut, .default)
        XCTAssertNotNil(fixture.controller.registrationError)
    }

    @MainActor
    func testInvalidShortcutNeverReachesRegistrar() {
        let fixture = HotKeyFixture(initial: .default)
        fixture.controller.start()
        let invalid = ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_4), modifiers: 0
        )

        XCTAssertFalse(fixture.controller.replace(with: invalid))
        XCTAssertEqual(fixture.registrar.events, [.register(.default)])
        XCTAssertEqual(fixture.store.load(), .default)
        XCTAssertEqual(fixture.controller.registrationError, .invalidShortcut)
    }

    @MainActor
    func testReplacingWithTheSameShortcutRetriesAfterAFailedStart() {
        let fixture = HotKeyFixture(initial: .default)
        fixture.registrar.failNextRegistration = true
        fixture.controller.start()
        XCTAssertNotNil(fixture.controller.registrationError)

        XCTAssertTrue(fixture.controller.replace(with: .default))
        XCTAssertEqual(fixture.registrar.events, [
            .register(.default), .register(.default)
        ])
        XCTAssertNil(fixture.controller.registrationError)
    }

    @MainActor
    func testReplacingWithTheSameShortcutStaysANoOpWhileRegistered() {
        let fixture = HotKeyFixture(initial: .default)
        fixture.controller.start()

        XCTAssertTrue(fixture.controller.replace(with: .default))
        XCTAssertEqual(fixture.registrar.events, [.register(.default)])
    }

    @MainActor
    func testReleasingControllerUnregistersActiveTokenOnce() {
        let registrar = RecordingHotKeyRegistrar()
        let suite = "HotKeyControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = ShortcutPreferenceStore(defaults: defaults, key: "shortcut")
        var controller: HotKeyController<RecordingHotKeyRegistrar>? =
            HotKeyController(registrar: registrar, store: store, action: {})
        controller?.start()

        controller = nil

        XCTAssertEqual(registrar.events, [
            .register(.default), .unregister(1)
        ])
    }
}

private enum RecordingHotKeyEvent: Equatable {
    case register(ShortcutPreference)
    case unregister(Int)
}

private final class RecordingHotKeyRegistrar: HotKeyRegistering {
    struct Token {
        let value: Int
    }

    var events: [RecordingHotKeyEvent] = []
    var failNextRegistration = false
    private var nextToken = 1

    func register(
        _ shortcut: ShortcutPreference,
        action: @escaping @MainActor () -> Void
    ) throws -> Token {
        events.append(.register(shortcut))
        if failNextRegistration {
            failNextRegistration = false
            throw HotKeyRegistrationError.registrationFailed(-1)
        }
        defer { nextToken += 1 }
        return Token(value: nextToken)
    }

    func unregister(_ token: Token) {
        events.append(.unregister(token.value))
    }
}

@MainActor
private struct HotKeyFixture {
    let registrar: RecordingHotKeyRegistrar
    let store: ShortcutPreferenceStore
    let controller: HotKeyController<RecordingHotKeyRegistrar>

    init(initial: ShortcutPreference) {
        registrar = RecordingHotKeyRegistrar()
        let suite = "HotKeyControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = ShortcutPreferenceStore(defaults: defaults, key: "shortcut")
        try! store.save(initial)
        controller = HotKeyController(
            registrar: registrar, store: store, action: {}
        )
    }
}

