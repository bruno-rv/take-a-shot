import AppKit
import Carbon
import SwiftUI

struct ShortcutSettingsView<Registrar: HotKeyRegistering>: View {
    @ObservedObject var controller: HotKeyController<Registrar>
    @ObservedObject var preferencesStore: ShortcutPreferencesStore

    @State private var recording = ShortcutRecordingState()
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
        let session = recording.session(for: action)
        return ShortcutRow(
            action: action,
            shortcut: current,
            session: session,
            isCustomized: current != action.defaultPreference,
            onRecord: { beginRecording(action) },
            onCancel: { cancelRecording($0) },
            onShortcut: { accept($1, for: action, in: $0) },
            onRevert: { revert(action) }
        )
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(status.message)
                .font(.footnote)
                .foregroundStyle(status.isError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(status.message)

            Button("Reset All") {
                resetToDefaults()
            }
            .accessibilityHint("Restores every shortcut to its default")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// A refused registration leaves the window showing a global shortcut that
    /// does nothing, so the warning stands until a retry clears it — an
    /// unrelated success elsewhere in the window must not bury it. Recording
    /// or resetting the global row is the retry.
    private var status: ShortcutAnnouncement {
        guard let error = controller.registrationError, !announcement.isError else {
            return announcement
        }
        return .error("Global shortcut inactive. \(error.localizedDescription)")
    }

    private func shortcut(for action: ShortcutAction) -> ShortcutPreference {
        action == .captureGlobal
            ? controller.currentShortcut
            : preferencesStore.preference(for: action)
    }

    private func beginRecording(_ action: ShortcutAction) {
        recording.begin(action)
        announcement = .recording
    }

    private func cancelRecording(_ session: ShortcutRecordingSession) {
        guard recording.cancel(session) else { return }
        announcement = .idle
    }

    /// Acceptance is session-scoped for the same reason cancellation is: a key
    /// event delivered from a row the user has already left must not overwrite
    /// that row's shortcut, nor disarm the row now recording.
    private func accept(
        _ shortcut: ShortcutPreference?,
        for action: ShortcutAction,
        in session: ShortcutRecordingSession
    ) {
        guard recording.isActive(session) else { return }
        guard let shortcut else {
            announcement = .error("Shortcut rejected. Include at least one modifier key.")
            return
        }
        guard shortcut.hasSupportedKey else {
            announcement = .error("Unsupported key. Use a letter or a number.")
            return
        }
        if let owner = conflict(with: shortcut, excluding: action) {
            announcement = .error(
                "\(shortcut.displayName) is already assigned to \(owner.displayLabel)."
            )
            return
        }
        guard apply(shortcut, to: action) else {
            announcement = .error(rejectionMessage(for: action))
            return
        }
        recording.finish()
        announcement = .accepted("\(action.displayLabel) shortcut set to \(shortcut.displayName).")
    }

    private func revert(_ action: ShortcutAction) {
        let fallback = action.defaultPreference
        guard apply(fallback, to: action) else {
            announcement = .error(rejectionMessage(for: action))
            return
        }
        recording.finish()
        announcement = .accepted("\(action.displayLabel) shortcut reset to \(fallback.displayName).")
    }

    private func conflict(
        with shortcut: ShortcutPreference,
        excluding action: ShortcutAction
    ) -> ShortcutAction? {
        var assignments = preferencesStore.preferences
        assignments[.captureGlobal] = controller.currentShortcut
        return ShortcutConflict.owner(of: shortcut, excluding: action, in: assignments)
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
        recording.finish()
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

/// One armed recording. The identifier lets late callbacks tell the session
/// they belong to apart from one the user has since started.
struct ShortcutRecordingSession: Equatable {
    let action: ShortcutAction
    let id: Int
}

/// Which row, if any, is currently listening for a keystroke.
///
/// `resignFirstResponder` reports asynchronously, so a cancellation can land
/// after the user has already armed another row — or re-armed the same one.
/// Every session carries an identifier and cancellation only applies to the
/// session that raised it, which keeps a stale callback from disarming a live
/// recording.
struct ShortcutRecordingState: Equatable {
    private(set) var session: ShortcutRecordingSession?
    private var lastID = 0

    func session(for action: ShortcutAction) -> ShortcutRecordingSession? {
        session?.action == action ? session : nil
    }

    func isActive(_ session: ShortcutRecordingSession) -> Bool {
        self.session == session
    }

    mutating func begin(_ action: ShortcutAction) {
        lastID += 1
        session = ShortcutRecordingSession(action: action, id: lastID)
    }

    @discardableResult
    mutating func cancel(_ session: ShortcutRecordingSession) -> Bool {
        guard self.session == session else { return false }
        self.session = nil
        return true
    }

    mutating func finish() {
        session = nil
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    let shortcut: ShortcutPreference
    let session: ShortcutRecordingSession?
    let isCustomized: Bool
    let onRecord: () -> Void
    let onCancel: (ShortcutRecordingSession) -> Void
    let onShortcut: (ShortcutRecordingSession, ShortcutPreference?) -> Void
    let onRevert: () -> Void

    private var isRecording: Bool { session != nil }

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
                session: session,
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
    let session: ShortcutRecordingSession?
    let onShortcut: (ShortcutRecordingSession, ShortcutPreference?) -> Void
    let onCancel: (ShortcutRecordingSession) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        configure(nsView)
        guard session != nil else {
            if nsView.window?.firstResponder === nsView {
                nsView.window?.makeFirstResponder(nil)
            }
            return
        }
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, nsView.session != nil else { return }
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    private func configure(_ view: ShortcutRecorderView) {
        view.onShortcut = onShortcut
        view.onCancel = onCancel
        view.session = session
    }
}

private final class ShortcutRecorderView: NSView {
    var onShortcut: ((ShortcutRecordingSession, ShortcutPreference?) -> Void)?
    var onCancel: ((ShortcutRecordingSession) -> Void)?
    /// Mirrors the SwiftUI recording state so losing focus to another row (or
    /// to a click elsewhere in the window) disarms this one — only one row may
    /// show "Type shortcut…" at a time, and a key press that arrives while
    /// this view is a stale first responder is ignored rather than recorded.
    var session: ShortcutRecordingSession?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didResignKeyNotification, object: nil
        )
        guard let window else { return }
        // Recording ends when the settings window goes away, matching the rest
        // of macOS: a row left armed behind another app would otherwise eat the
        // first shortcut typed after coming back.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowDidResignKey() {
        cancelActiveSession()
    }

    /// The recorder only ever reads `keyDown` after being made first responder
    /// programmatically. It sits behind the keycap button as a SwiftUI
    /// background, and AppKit hit-tests the real view tree — so without this
    /// it would swallow the click that arms the row.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resignFirstResponder() -> Bool {
        cancelActiveSession()
        return true
    }

    private func cancelActiveSession() {
        guard let session else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onCancel?(session)
        }
    }

    /// AppKit offers key equivalents to the view tree before the main menu, so
    /// claiming them here is what stops ⌘W from closing the window (or ⌘Q from
    /// quitting) when the user is trying to record that very combination.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard session != nil, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let session else {
            super.keyDown(with: event)
            return
        }
        guard event.keyCode != UInt16(kVK_Escape) else {
            onCancel?(session)
            return
        }
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            onShortcut?(session, nil)
            NSSound.beep()
            return
        }
        onShortcut?(
            session,
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
