import Carbon
import Foundation

struct PinRecoveryShortcut: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let defaultShortcut = PinRecoveryShortcut(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )
}

enum PinShortcutError: Error, Equatable, Sendable {
    case alreadyInUse
    case registrationFailed(Int32)
}

protocol PinShortcutRegistering: Sendable {
    func register(
        _ shortcut: PinRecoveryShortcut,
        handler: @escaping @Sendable () -> Void
    ) throws
    func unregister()
}

final class PinShortcutController: PinShortcutRegistering, @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handler: (@Sendable () -> Void)?

    func register(
        _ shortcut: PinRecoveryShortcut,
        handler: @escaping @Sendable () -> Void
    ) throws {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                PinShortcutController.sharedHandler?()
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard installStatus == noErr else {
            self.handler = nil
            throw PinShortcutError.registrationFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 2)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            unregister()
            if registerStatus == eventHotKeyExistsErr { throw PinShortcutError.alreadyInUse }
            throw PinShortcutError.registrationFailed(registerStatus)
        }
        PinShortcutController.sharedHandler = handler
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        handler = nil
        PinShortcutController.sharedHandler = nil
    }

    private static var sharedHandler: (@Sendable () -> Void)?
    private static let signature = "TAS2".utf8.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
}
