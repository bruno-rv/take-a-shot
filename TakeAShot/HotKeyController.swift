import Carbon
import Combine
import Foundation

protocol HotKeyRegistering: AnyObject {
    associatedtype Token

    func register(
        _ shortcut: ShortcutPreference,
        action: @escaping @MainActor () -> Void
    ) throws -> Token
    func unregister(_ token: Token)
}

enum HotKeyRegistrationError: LocalizedError, Equatable {
    case invalidShortcut
    case registrationFailed(OSStatus)
    case preferenceSaveFailed

    var errorDescription: String? {
        switch self {
        case .invalidShortcut:
            return "The selected shortcut must include a supported modifier."
        case let .registrationFailed(status):
            return "The shortcut could not be registered (\(status))."
        case .preferenceSaveFailed:
            return "The shortcut preference could not be saved."
        }
    }
}

@MainActor
final class HotKeyController<Registrar: HotKeyRegistering>: ObservableObject {
    @Published private(set) var currentShortcut: ShortcutPreference
    @Published private(set) var registrationError: HotKeyRegistrationError?

    var captureAction: (@MainActor () -> Void)?

    private let registrar: Registrar
    private let store: ShortcutPreferenceStore
    private var activeToken: Registrar.Token?

    init(
        registrar: Registrar,
        store: ShortcutPreferenceStore = ShortcutPreferenceStore(),
        action: @escaping @MainActor () -> Void
    ) {
        self.registrar = registrar
        self.store = store
        captureAction = action
        currentShortcut = store.load()
    }

    func start() {
        guard activeToken == nil else { return }
        do {
            activeToken = try register(currentShortcut)
            registrationError = nil
        } catch {
            registrationError = normalizedRegistrationError(error)
        }
    }

    @discardableResult
    func replace(with shortcut: ShortcutPreference) -> Bool {
        guard shortcut.isValid else {
            registrationError = .invalidShortcut
            return false
        }
        guard shortcut != currentShortcut else {
            registrationError = nil
            return true
        }

        let newToken: Registrar.Token
        do {
            newToken = try register(shortcut)
        } catch {
            registrationError = normalizedRegistrationError(error)
            return false
        }

        do {
            try store.save(shortcut)
        } catch {
            registrar.unregister(newToken)
            registrationError = .preferenceSaveFailed
            return false
        }

        let oldToken = activeToken
        activeToken = newToken
        if let oldToken {
            registrar.unregister(oldToken)
        }
        currentShortcut = shortcut
        registrationError = nil
        return true
    }

    deinit {
        if let activeToken {
            registrar.unregister(activeToken)
        }
    }

    private func register(_ shortcut: ShortcutPreference) throws -> Registrar.Token {
        try registrar.register(shortcut) { [weak self] in
            self?.captureAction?()
        }
    }

    private func normalizedRegistrationError(_ error: Error) -> HotKeyRegistrationError {
        if let error = error as? HotKeyRegistrationError {
            return error
        }
        return .registrationFailed(OSStatus(paramErr))
    }
}

final class CarbonHotKeyRegistrar: HotKeyRegistering {
    final class Token {
        fileprivate let identifier: UInt32
        fileprivate var reference: EventHotKeyRef?

        fileprivate init(identifier: UInt32, reference: EventHotKeyRef) {
            self.identifier = identifier
            self.reference = reference
        }
    }

    private static let signature: OSType = 0x5441_5331

    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var activeTokens: [UInt32: Token] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextIdentifier: UInt32 = 1

    func register(
        _ shortcut: ShortcutPreference,
        action: @escaping @MainActor () -> Void
    ) throws -> Token {
        try installHandlerIfNeeded()
        guard nextIdentifier < UInt32.max else {
            throw HotKeyRegistrationError.registrationFailed(OSStatus(paramErr))
        }

        let identifier = nextIdentifier
        nextIdentifier += 1
        let hotKeyID = EventHotKeyID(
            signature: Self.signature, id: identifier
        )
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw HotKeyRegistrationError.registrationFailed(status)
        }

        let token = Token(identifier: identifier, reference: reference)
        actions[identifier] = action
        activeTokens[identifier] = token
        return token
    }

    func unregister(_ token: Token) {
        guard let reference = token.reference else { return }
        token.reference = nil
        actions[token.identifier] = nil
        activeTokens[token.identifier] = nil
        let status = UnregisterEventHotKey(reference)
        if status != noErr {
            assertionFailure("UnregisterEventHotKey failed with status \(status)")
        }
    }

    deinit {
        for token in Array(activeTokens.values) {
            unregister(token)
        }
        if let handlerRef {
            let status = RemoveEventHandler(handlerRef)
            if status != noErr {
                assertionFailure("RemoveEventHandler failed with status \(status)")
            }
        }
    }

    private func installHandlerIfNeeded() throws {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else {
                return OSStatus(eventNotHandledErr)
            }
            let registrar = Unmanaged<CarbonHotKeyRegistrar>
                .fromOpaque(userData)
                .takeUnretainedValue()
            return registrar.handle(event)
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else {
            handlerRef = nil
            throw HotKeyRegistrationError.registrationFailed(status)
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == Self.signature,
              let action = actions[hotKeyID.id] else {
            return status == noErr ? OSStatus(eventNotHandledErr) : status
        }
        Task { @MainActor in action() }
        return noErr
    }
}

@MainActor
private enum LegacyHotKeyController {
    static let shared = HotKeyController(
        registrar: CarbonHotKeyRegistrar(), action: {}
    )
}

extension HotKeyController where Registrar == CarbonHotKeyRegistrar {
    @MainActor
    static var shared: HotKeyController<CarbonHotKeyRegistrar> {
        LegacyHotKeyController.shared
    }
}
