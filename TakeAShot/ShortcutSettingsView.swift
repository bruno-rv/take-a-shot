import AppKit
import Carbon
import SwiftUI

struct ShortcutSettingsView<Registrar: HotKeyRegistering>: View {
    @ObservedObject var controller: HotKeyController<Registrar>
    @State private var isRecording = false
    @State private var announcement = "Select Record New Shortcut to make a change."

    var body: some View {
        Form {
            LabeledContent("Current shortcut") {
                Text(controller.currentShortcut.displayName)
                    .font(.body.monospaced())
                    .accessibilityLabel(
                        "Current capture shortcut, \(controller.currentShortcut.displayName)"
                    )
            }

            ShortcutRecorder(
                isRecording: isRecording,
                onShortcut: accept
            )
            .frame(height: 36)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isRecording ? Color.accentColor : .secondary)
            }
            .overlay {
                Text(isRecording ? "Type shortcut now" : "Record New Shortcut")
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isRecording = true
                announcement = "Recording. Type a shortcut with at least one modifier."
            }
            .accessibilityLabel(isRecording ? "Recording shortcut" : "Record new shortcut")
            .accessibilityHint("Shortcuts must include Command, Option, Control, or Shift")

            Text(announcement)
                .font(.footnote)
                .foregroundStyle(
                    controller.registrationError == nil ? Color.secondary : Color.red
                )
                .accessibilityLabel(announcement)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }

    private func accept(_ shortcut: ShortcutPreference?) {
        guard let shortcut else {
            announcement = "Shortcut rejected. Include at least one modifier key."
            return
        }
        if controller.replace(with: shortcut) {
            isRecording = false
            announcement = "Shortcut accepted: \(shortcut.displayName)."
        } else {
            announcement = controller.registrationError?.localizedDescription
                ?? "Shortcut rejected. Choose another shortcut."
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let isRecording: Bool
    let onShortcut: (ShortcutPreference?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onShortcut = onShortcut
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.onShortcut = onShortcut
        guard isRecording else {
            if nsView.window?.firstResponder === nsView {
                nsView.window?.makeFirstResponder(nil)
            }
            return
        }
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class ShortcutRecorderView: NSView {
    var onShortcut: ((ShortcutPreference?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            onShortcut?(nil)
            NSSound.beep()
            return
        }
        onShortcut?(
            ShortcutPreference(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers
            )
        )
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}
