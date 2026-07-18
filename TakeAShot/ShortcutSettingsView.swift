import AppKit
import Carbon
import SwiftUI

struct ShortcutSettingsView<Registrar: HotKeyRegistering>: View {
    @ObservedObject var controller: HotKeyController<Registrar>
    @ObservedObject var preferencesStore: ShortcutPreferencesStore

    @State private var recordingAction: ShortcutAction?
    @State private var announcement = "Select Record New Shortcut to make a change."
    @State private var announcementIsError = false

    var body: some View {
        Form {
            Section("Global") {
                shortcutRow(
                    for: .captureGlobal,
                    current: controller.currentShortcut,
                    onShortcut: acceptGlobal
                )
            }

            Section("Capture modes") {
                ForEach(ShortcutPreferencesStore.managedActions) { action in
                    shortcutRow(
                        for: action,
                        current: preferencesStore.preference(for: action),
                        onShortcut: { accept($0, for: action) }
                    )
                }
            }

            Text(announcement)
                .font(.footnote)
                .foregroundStyle(announcementIsError ? Color.red : Color.secondary)
                .accessibilityLabel(announcement)

            Button("Reset to Defaults") {
                resetToDefaults()
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }

    @ViewBuilder
    private func shortcutRow(
        for action: ShortcutAction,
        current: ShortcutPreference,
        onShortcut: @escaping (ShortcutPreference?) -> Void
    ) -> some View {
        let isRecording = recordingAction == action
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(action.displayLabel) {
                Text(current.displayName)
                    .font(.body.monospaced())
                    .accessibilityLabel("\(action.displayLabel) shortcut, \(current.displayName)")
            }

            ShortcutRecorder(isRecording: isRecording, onShortcut: onShortcut)
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
                    recordingAction = action
                    announcementIsError = false
                    announcement = "Recording. Type a shortcut with at least one modifier."
                }
                .accessibilityLabel(
                    isRecording ? "Recording shortcut" : "Record new shortcut for \(action.displayLabel)"
                )
                .accessibilityHint("Shortcuts must include Command, Option, Control, or Shift")
        }
    }

    private func acceptGlobal(_ shortcut: ShortcutPreference?) {
        guard let shortcut else {
            reject()
            return
        }
        if controller.replace(with: shortcut) {
            accept(shortcut, label: ShortcutAction.captureGlobal.displayLabel)
        } else {
            announcementIsError = true
            announcement = controller.registrationError?.localizedDescription
                ?? "Shortcut rejected. Choose another shortcut."
        }
    }

    private func accept(_ shortcut: ShortcutPreference?, for action: ShortcutAction) {
        guard let shortcut else {
            reject()
            return
        }
        if preferencesStore.save(shortcut, for: action) {
            accept(shortcut, label: action.displayLabel)
        } else {
            announcementIsError = true
            announcement = "Shortcut rejected. Choose another shortcut."
        }
    }

    private func accept(_ shortcut: ShortcutPreference, label: String) {
        recordingAction = nil
        announcementIsError = false
        announcement = "\(label) shortcut accepted: \(shortcut.displayName)."
    }

    private func reject() {
        announcementIsError = true
        announcement = "Shortcut rejected. Include at least one modifier key."
    }

    private func resetToDefaults() {
        recordingAction = nil
        _ = controller.replace(with: ShortcutAction.captureGlobal.defaultPreference)
        preferencesStore.resetToDefaults()
        announcementIsError = false
        announcement = "Shortcuts reset to defaults."
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
