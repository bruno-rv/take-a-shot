import Carbon
import Foundation
import SwiftUI

struct ShortcutPreference: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let `default` = ShortcutPreference(
        keyCode: UInt32(kVK_ANSI_1),
        modifiers: UInt32(shiftKey | cmdKey)
    )

    var isValid: Bool {
        let supported = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return modifiers & supported != 0
    }

    /// Whether the key half of the shortcut maps to a `KeyEquivalent`. In-app
    /// shortcuts are dispatched through SwiftUI's `keyboardShortcut`, which
    /// silently never matches an unmapped key code, so recording one would
    /// persist a shortcut that can't fire.
    var hasSupportedKey: Bool {
        ShortcutKeyMapping.charactersByKeyCode[keyCode] != nil
    }

    var isRecordable: Bool {
        isValid && hasSupportedKey
    }

    var displayName: String {
        ShortcutDisplayName.make(keyCode: keyCode, modifiers: modifiers)
    }

    var keyEquivalent: KeyEquivalent {
        guard let character = ShortcutKeyMapping.charactersByKeyCode[keyCode] else {
            return KeyEquivalent(Character(UnicodeScalar(0)))
        }
        return KeyEquivalent(character)
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
        return result
    }
}

enum ShortcutAction: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case captureGlobal
    case area
    case window
    case fullscreen
    case scrolling
    case scrollingManual
    case record

    var id: String { rawValue }

    var storageKey: String {
        self == .captureGlobal ? "captureShortcut" : "shortcut.\(rawValue)"
    }

    var displayLabel: String {
        switch self {
        case .captureGlobal: return "Global capture"
        case .area: return "Area"
        case .window: return "Window"
        case .fullscreen: return "Fullscreen"
        case .scrolling: return "Auto Scrolling"
        case .scrollingManual: return "Manual Scroll"
        case .record: return "Record"
        }
    }

    var symbol: String {
        switch self {
        case .captureGlobal: return "command"
        case .area: return "selection.pin.in.out"
        case .window: return "macwindow"
        case .fullscreen: return "viewfinder"
        case .scrolling: return "arrow.up.and.down.and.arrow.left.and.right"
        case .scrollingManual: return "hand.draw"
        case .record: return "video"
        }
    }

    /// Whether the shortcut is dispatched only through SwiftUI's
    /// `keyboardShortcut`, which cannot match a key outside the character
    /// mapping. Global capture and Manual Scroll also register a Carbon hotkey
    /// by raw key code, so a function or arrow key still does something there.
    var requiresMappableKey: Bool {
        switch self {
        case .captureGlobal, .scrollingManual: return false
        case .area, .window, .fullscreen, .scrolling, .record: return true
        }
    }

    var section: ShortcutSection {
        switch self {
        case .captureGlobal: return .global
        case .area, .window, .fullscreen, .scrolling, .scrollingManual: return .capture
        case .record: return .recording
        }
    }

    var defaultPreference: ShortcutPreference {
        switch self {
        case .captureGlobal: return .default
        case .area: return ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey)
        )
        case .window: return ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(controlKey | optionKey)
        )
        case .fullscreen: return ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey)
        )
        case .scrolling: return ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey)
        )
        case .scrollingManual: return ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey | shiftKey)
        )
        case .record: return ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey)
        )
        }
    }
}

/// Grouping used by the settings window so each shortcut sits under the part
/// of the app it drives, instead of one flat list.
enum ShortcutSection: String, CaseIterable, Hashable, Identifiable, Sendable {
    case global
    case capture
    case recording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .global: return "Global"
        case .capture: return "Capture"
        case .recording: return "Recording"
        }
    }

    var caption: String {
        switch self {
        case .global: return "Starts an area capture from any app, without Take a Shot in front."
        case .capture: return "Picks the matching mode in the editor window."
        case .recording: return "Starts and stops screen recording."
        }
    }

    var actions: [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.section == self }
    }
}

struct ShortcutPreferenceStore {
    private let defaults: UserDefaults
    private let key: String
    private let defaultPreference: ShortcutPreference
    /// In-app shortcuts go through `keyboardShortcut`, which cannot match a key
    /// code outside the character mapping, so those stores refuse to *record*
    /// one. Loading stays permissive either way: a value an earlier build
    /// accepted is still what the user chose, and Manual Scroll's session
    /// hotkey registers it through Carbon by raw key code. Settings flags such
    /// a value instead of rewriting it.
    private let requiresSupportedKey: Bool

    init(defaults: UserDefaults = .standard,
         key: String = "captureShortcut",
         defaultPreference: ShortcutPreference = .default,
         requiresSupportedKey: Bool = false) {
        self.defaults = defaults
        self.key = key
        self.defaultPreference = defaultPreference
        self.requiresSupportedKey = requiresSupportedKey
    }

    func load() -> ShortcutPreference {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(
                  ShortcutPreference.self, from: data
              ), value.isValid else { return defaultPreference }
        return value
    }

    func save(_ value: ShortcutPreference) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }

    func accepts(_ value: ShortcutPreference) -> Bool {
        requiresSupportedKey ? value.isRecordable : value.isValid
    }
}

/// Persists and publishes a shortcut per capture mode (area, window,
/// fullscreen, scrolling, record). The global capture shortcut is not
/// managed here — it remains owned by `HotKeyController`, which is the
/// single source of truth for the Carbon-registered global hotkey.
@MainActor
final class ShortcutPreferencesStore: ObservableObject {
    @Published private(set) var preferences: [ShortcutAction: ShortcutPreference]

    private var stores: [ShortcutAction: ShortcutPreferenceStore]

    static let managedActions = ShortcutAction.allCases.filter { $0 != .captureGlobal }

    init(defaults: UserDefaults = .standard) {
        var stores: [ShortcutAction: ShortcutPreferenceStore] = [:]
        for action in Self.managedActions {
            stores[action] = ShortcutPreferenceStore(
                defaults: defaults,
                key: action.storageKey,
                defaultPreference: action.defaultPreference,
                requiresSupportedKey: action.requiresMappableKey
            )
        }
        self.stores = stores
        self.preferences = stores.mapValues { $0.load() }
    }

    func preference(for action: ShortcutAction) -> ShortcutPreference {
        preferences[action] ?? action.defaultPreference
    }

    @discardableResult
    func save(_ preference: ShortcutPreference, for action: ShortcutAction) -> Bool {
        guard let store = stores[action], store.accepts(preference) else { return false }
        do {
            try store.save(preference)
        } catch {
            return false
        }
        preferences[action] = preference
        return true
    }

    func resetToDefaults() {
        for action in Self.managedActions {
            _ = save(action.defaultPreference, for: action)
        }
    }
}

enum ShortcutHolder: Equatable {
    case action(ShortcutAction)
    case reserved(String)

    var displayLabel: String {
        switch self {
        case let .action(action): return action.displayLabel
        case let .reserved(name): return name
        }
    }
}

/// Two commands bound to the same keys is ambiguous — both claim the event and
/// one silently loses. The domain covers the configurable actions plus the
/// editor commands that are always bound.
enum ShortcutConflict {
    /// Editor commands and the standard window/application commands macOS
    /// binds for every app. A recorded shortcut that matches one of these wins
    /// or loses unpredictably, so recording refuses it.
    static let reserved: [(name: String, preference: ShortcutPreference)] = [
        ("Undo", ShortcutPreference(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey))),
        (
            "Redo",
            ShortcutPreference(
                keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey | shiftKey)
            )
        ),
        ("Close Window", ShortcutPreference(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey))),
        ("Minimize", ShortcutPreference(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey))),
        ("Hide", ShortcutPreference(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey))),
        (
            "Settings",
            ShortcutPreference(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey))
        ),
        ("Quit", ShortcutPreference(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey))),
        ("Select All", ShortcutPreference(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey))),
        ("Cut", ShortcutPreference(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey))),
        ("Copy", ShortcutPreference(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))),
        ("Paste", ShortcutPreference(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey))),
    ]

    /// The first collision already present in a stored set, in action order.
    /// Values written by earlier builds were never checked against each other,
    /// so the settings window reports them instead of silently rewriting what
    /// the user chose.
    static func firstConflict(
        in assignments: [ShortcutAction: ShortcutPreference]
    ) -> (action: ShortcutAction, holder: ShortcutHolder, preference: ShortcutPreference)? {
        var seen: [ShortcutAction: ShortcutPreference] = [:]
        for action in ShortcutAction.allCases {
            guard let preference = assignments[action] else { continue }
            if let holder = holder(of: preference, excluding: action, in: seen) {
                return (action, holder, preference)
            }
            seen[action] = preference
        }
        return nil
    }

    static func holder(
        of preference: ShortcutPreference,
        excluding action: ShortcutAction,
        in assignments: [ShortcutAction: ShortcutPreference]
    ) -> ShortcutHolder? {
        if let reserved = reserved.first(where: { $0.preference == preference }) {
            return .reserved(reserved.name)
        }
        let owner = assignments
            .filter { $0.key != action && $0.value == preference }
            .keys
            .min { $0.rawValue < $1.rawValue }
        return owner.map(ShortcutHolder.action)
    }
}

private enum ShortcutDisplayName {
    static func make(keyCode: UInt32, modifiers: UInt32) -> String {
        var name = ""
        if modifiers & UInt32(controlKey) != 0 { name += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { name += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { name += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { name += "⌘" }
        name += keyName(for: keyCode)
        return name
    }

    private static func keyName(for keyCode: UInt32) -> String {
        if let character = ShortcutKeyMapping.charactersByKeyCode[keyCode] {
            return String(character).uppercased()
        }
        // Keys with no character equivalent can still be registered globally
        // through Carbon, so they need a readable name here.
        return ShortcutKeyMapping.namesByKeyCode[keyCode] ?? "[\(keyCode)]"
    }
}

private enum ShortcutKeyMapping {
    static let namesByKeyCode: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab", UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Home): "Home", UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up", UInt32(kVK_PageDown): "Page Down",
    ]

    static let charactersByKeyCode: [UInt32: Character] = [
        UInt32(kVK_ANSI_A): "a", UInt32(kVK_ANSI_B): "b", UInt32(kVK_ANSI_C): "c",
        UInt32(kVK_ANSI_D): "d", UInt32(kVK_ANSI_E): "e", UInt32(kVK_ANSI_F): "f",
        UInt32(kVK_ANSI_G): "g", UInt32(kVK_ANSI_H): "h", UInt32(kVK_ANSI_I): "i",
        UInt32(kVK_ANSI_J): "j", UInt32(kVK_ANSI_K): "k", UInt32(kVK_ANSI_L): "l",
        UInt32(kVK_ANSI_M): "m", UInt32(kVK_ANSI_N): "n", UInt32(kVK_ANSI_O): "o",
        UInt32(kVK_ANSI_P): "p", UInt32(kVK_ANSI_Q): "q", UInt32(kVK_ANSI_R): "r",
        UInt32(kVK_ANSI_S): "s", UInt32(kVK_ANSI_T): "t", UInt32(kVK_ANSI_U): "u",
        UInt32(kVK_ANSI_V): "v", UInt32(kVK_ANSI_W): "w", UInt32(kVK_ANSI_X): "x",
        UInt32(kVK_ANSI_Y): "y", UInt32(kVK_ANSI_Z): "z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
    ]
}
