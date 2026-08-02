import AppKit
import Carbon
import SwiftUI

struct ShortcutSettingsView<Registrar: HotKeyRegistering>: View {
    @ObservedObject var controller: HotKeyController<Registrar>
    @ObservedObject var preferencesStore: ShortcutPreferencesStore

    @State private var recordingAction: ShortcutAction?
    @State private var announcement = ShortcutAnnouncement.idle

    var body: some View {
        Form {
            ForEach(ShortcutSection.allCases) { section in
                Section {
                    ForEach(section.actions) { action in
                        row(for: action)
                    }
                } header: {
                    header(for: section)
                }
            }
        }
        .formStyle(.grouped)
        // `safeAreaInset` rather than a `VStack`: a grouped `Form` keeps its
        // full content height, so a sibling footer gets pushed out of the
        // window instead of pinned. As an inset it stays put and the form's
        // scroll view reserves room for it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                footer
            }
            .background(.bar)
        }
        // The Settings scene sizes its window to the content's ideal size and
        // isn't user-resizable, so the height has to be bounded here — without
        // it the form grows past the screen instead of scrolling internally.
        // 580 fits every row at the default text size; larger accessibility
        // sizes overflow into the form's own scroll view instead of clipping.
        .frame(width: 460, height: 580)
    }

    private func header(for section: ShortcutSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
                .font(.headline)
            Text(section.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }

    private func row(for action: ShortcutAction) -> some View {
        let current = shortcut(for: action)
        return ShortcutRow(
            action: action,
            shortcut: current,
            isRecording: recordingAction == action,
            isCustomized: current != action.defaultPreference,
            onRecord: { beginRecording(action) },
            onCancel: { cancelRecording(action) },
            onShortcut: { accept($0, for: action) },
            onRevert: { revert(action) }
        )
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(announcement.message)
                .font(.footnote)
                .foregroundStyle(announcement.isError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(announcement.message)

            Button("Reset All") {
                resetToDefaults()
            }
            .accessibilityHint("Restores every shortcut to its default")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func shortcut(for action: ShortcutAction) -> ShortcutPreference {
        action == .captureGlobal
            ? controller.currentShortcut
            : preferencesStore.preference(for: action)
    }

    private func beginRecording(_ action: ShortcutAction) {
        recordingAction = action
        announcement = .recording
    }

    private func cancelRecording(_ action: ShortcutAction) {
        guard recordingAction == action else { return }
        recordingAction = nil
        announcement = .idle
    }

    private func accept(_ shortcut: ShortcutPreference?, for action: ShortcutAction) {
        guard let shortcut else {
            announcement = .error("Shortcut rejected. Include at least one modifier key.")
            return
        }
        guard apply(shortcut, to: action) else {
            announcement = .error(rejectionMessage(for: action))
            return
        }
        recordingAction = nil
        announcement = .accepted("\(action.displayLabel) shortcut set to \(shortcut.displayName).")
    }

    private func revert(_ action: ShortcutAction) {
        let fallback = action.defaultPreference
        guard apply(fallback, to: action) else {
            announcement = .error(rejectionMessage(for: action))
            return
        }
        recordingAction = nil
        announcement = .accepted("\(action.displayLabel) shortcut reset to \(fallback.displayName).")
    }

    /// The global shortcut is owned by `HotKeyController` (it holds the Carbon
    /// registration and can be refused by the OS); every other action is a
    /// stored preference. Both funnel through here so the rows stay identical.
    private func apply(_ shortcut: ShortcutPreference, to action: ShortcutAction) -> Bool {
        action == .captureGlobal
            ? controller.replace(with: shortcut)
            : preferencesStore.save(shortcut, for: action)
    }

    private func rejectionMessage(for action: ShortcutAction) -> String {
        guard action == .captureGlobal else {
            return "Shortcut rejected. Choose another shortcut."
        }
        return controller.registrationError?.localizedDescription
            ?? "Shortcut rejected. Choose another shortcut."
    }

    private func resetToDefaults() {
        recordingAction = nil
        let globalReset = controller.replace(with: ShortcutAction.captureGlobal.defaultPreference)
        preferencesStore.resetToDefaults()
        announcement = globalReset
            ? .accepted("Shortcuts reset to defaults.")
            : .error("Capture shortcuts reset. \(rejectionMessage(for: .captureGlobal))")
    }
}

private struct ShortcutAnnouncement: Equatable {
    let message: String
    let isError: Bool

    static let idle = ShortcutAnnouncement(
        message: "Click a shortcut to record a new one.",
        isError: false
    )

    static let recording = ShortcutAnnouncement(
        message: "Recording. Type a shortcut with at least one modifier, or press Escape.",
        isError: false
    )

    static func accepted(_ message: String) -> ShortcutAnnouncement {
        ShortcutAnnouncement(message: message, isError: false)
    }

    static func error(_ message: String) -> ShortcutAnnouncement {
        ShortcutAnnouncement(message: message, isError: true)
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    let shortcut: ShortcutPreference
    let isRecording: Bool
    let isCustomized: Bool
    let onRecord: () -> Void
    let onCancel: () -> Void
    let onShortcut: (ShortcutPreference?) -> Void
    let onRevert: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Button(action: onRevert) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .opacity(isCustomized ? 1 : 0)
                .disabled(!isCustomized)
                .accessibilityLabel("Reset \(action.displayLabel) shortcut to default")
                .accessibilityHidden(!isCustomized)

                keyCap
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: action.symbol)
                    .frame(width: 22)
                Text(action.displayLabel)
            }
        }
    }

    private var keyCap: some View {
        Button(action: onRecord) {
            Text(isRecording ? "Type shortcut…" : shortcut.displayName)
                .font(.body.monospaced())
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                // Wide enough that arming a row doesn't resize the keycap.
                .frame(minWidth: 116)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isRecording
                            ? Color.accentColor.opacity(0.14)
                            : Color(nsColor: .controlBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isRecording ? Color.accentColor : Color.secondary.opacity(0.35),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .background {
            ShortcutRecorder(
                isRecording: isRecording,
                onShortcut: onShortcut,
                onCancel: onCancel
            )
        }
        .accessibilityLabel(
            isRecording
                ? "Recording shortcut for \(action.displayLabel)"
                : "\(action.displayLabel) shortcut, \(shortcut.displayName)"
        )
        .accessibilityHint("Activate to record a new shortcut. Shortcuts must include Command, Option, Control, or Shift")
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let isRecording: Bool
    let onShortcut: (ShortcutPreference?) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onShortcut = onShortcut
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.onShortcut = onShortcut
        nsView.onCancel = onCancel
        nsView.isArmed = isRecording
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
    var onCancel: (() -> Void)?
    /// Mirrors the SwiftUI recording state so losing focus to another row (or
    /// to a click elsewhere in the window) disarms this one — only one row may
    /// show "Type shortcut…" at a time.
    var isArmed = false

    override var acceptsFirstResponder: Bool { true }

    /// The recorder only ever reads `keyDown` after being made first responder
    /// programmatically. It sits behind the keycap button as a SwiftUI
    /// background, and AppKit hit-tests the real view tree — so without this
    /// it would swallow the click that arms the row.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resignFirstResponder() -> Bool {
        guard isArmed else { return true }
        DispatchQueue.main.async { [weak self] in
            self?.onCancel?()
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode != UInt16(kVK_Escape) else {
            onCancel?()
            return
        }
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
