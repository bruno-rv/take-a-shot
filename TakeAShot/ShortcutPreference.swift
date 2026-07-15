import Carbon
import Foundation

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

    var displayName: String {
        ShortcutDisplayName.make(keyCode: keyCode, modifiers: modifiers)
    }
}

struct ShortcutPreferenceStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard,
         key: String = "captureShortcut") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> ShortcutPreference {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(
                  ShortcutPreference.self, from: data
              ), value.isValid else { return .default }
        return value
    }

    func save(_ value: ShortcutPreference) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
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
        switch keyCode {
        case UInt32(kVK_ANSI_0): return "0"
        case UInt32(kVK_ANSI_1): return "1"
        case UInt32(kVK_ANSI_2): return "2"
        case UInt32(kVK_ANSI_3): return "3"
        case UInt32(kVK_ANSI_4): return "4"
        case UInt32(kVK_ANSI_5): return "5"
        case UInt32(kVK_ANSI_6): return "6"
        case UInt32(kVK_ANSI_7): return "7"
        case UInt32(kVK_ANSI_8): return "8"
        case UInt32(kVK_ANSI_9): return "9"
        default: return "[\(keyCode)]"
        }
    }
}
