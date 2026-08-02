import AppKit
import SwiftUI

struct CaptureShortcutGuidance: Equatable {
    let railText: String
    let emptyCanvasText: String

    init(shortcut: ShortcutPreference) {
        railText = "Global shortcut: \(shortcut.displayName)"
        emptyCanvasText = "Press \(shortcut.displayName) to capture"
    }
}

extension CaptureMode {
    var shortcutAction: ShortcutAction {
        switch self {
        case .area: return .area
        case .window: return .window
        case .fullScreen: return .fullscreen
        case .scrolling: return .scrolling
        case .scrollingManual: return .scrollingManual
        case .record: return .record
        }
    }
}

struct MacContentView<Registrar: HotKeyRegistering>: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var shortcutController: HotKeyController<Registrar>
    @ObservedObject var shortcutPreferencesStore: ShortcutPreferencesStore

    @State private var selectedMode: CaptureMode = .area
    @State private var selectedTool: AnnotationTool = .select
    @State private var hideDesktopIcons = true
    @State private var showCursor = false
    @State private var delayCapture = false

    var body: some View {
        HStack(spacing: 14) {
            MacCaptureRail(
                shortcutGuidance: shortcutGuidance,
                shortcutPreferencesStore: shortcutPreferencesStore,
                selectedMode: $selectedMode,
                hideDesktopIcons: $hideDesktopIcons,
                showCursor: $showCursor,
                delayCapture: $delayCapture
            )

            VStack(spacing: 14) {
                MacToolbar(
                    selectedTool: $selectedTool,
                    editorModel: appState.annotationEditor
                )
                MacEditorCanvas(
                    shortcutGuidance: shortcutGuidance,
                    selectedTool: selectedTool,
                    editorModel: appState.annotationEditor
                )
                MacRecordingBar(
                    shortcut: shortcutPreferencesStore.preference(for: .record)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MacInspector(
                selectedTool: selectedTool,
                editorModel: appState.annotationEditor
            )
        }
        .padding(18)
        .background {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.09),
                    Color(red: 0.09, green: 0.12, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
    }

    private var shortcutGuidance: CaptureShortcutGuidance {
        CaptureShortcutGuidance(shortcut: shortcutController.currentShortcut)
    }
}

struct MacCaptureRail: View {
    @EnvironmentObject private var appState: AppState

    let shortcutGuidance: CaptureShortcutGuidance
    @ObservedObject var shortcutPreferencesStore: ShortcutPreferencesStore
    @Binding var selectedMode: CaptureMode
    @Binding var hideDesktopIcons: Bool
    @Binding var showCursor: Bool
    @Binding var delayCapture: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "scissors")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(.white)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Take a Shot")
                        .font(.headline.weight(.bold))
                    Text("Capture Studio")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.58))
                }
            }

            Divider().overlay(.white.opacity(0.16))

            VStack(spacing: 7) {
                ForEach(CaptureMode.allCases.filter { $0 != .record }) { mode in
                    Button {
                        selectedMode = mode
                    } label: {
                        HStack {
                            Image(systemName: mode.symbol)
                                .frame(width: 22)
                            Text(mode.rawValue)
                            Spacer()
                            Text(shortcut(for: mode))
                                .font(.caption.weight(.heavy))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 11)
                        .frame(height: 42)
                        .foregroundStyle(.white.opacity(selectedMode == mode ? 1 : 0.72))
                        .background(selectedMode == mode ? Color.white.opacity(0.13) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(
                        preference(for: mode).keyEquivalent,
                        modifiers: preference(for: mode).eventModifiers
                    )
                    .accessibilityLabel("Select \(mode.rawValue) capture mode")
                    .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
                }
            }

            Divider().overlay(.white.opacity(0.16))

            VStack(spacing: 12) {
                Toggle("Hide desktop icons", isOn: $hideDesktopIcons)
                Toggle("Show cursor", isOn: $showCursor)
                Toggle("Delay 3 seconds", isOn: $delayCapture)
            }
            .toggleStyle(.switch)
            .font(.caption.weight(.semibold))

            Spacer()

            Button {
                triggerCapture()
            } label: {
                Label(primaryButtonTitle, systemImage: primaryButtonSymbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryCapsuleButtonStyle(tint: .accentColor))
            .disabled(!appState.canStartCapture && !appState.isScrollingCaptureActive)

            if appState.isScrollingCaptureActive {
                Text(scrollingProgressLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Text(shortcutGuidance.railText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.56))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .frame(width: 250)
        .foregroundStyle(.white)
        .background(Color(red: 0.08, green: 0.12, blue: 0.19).opacity(0.93))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 22, y: 14)
    }

    private func shortcut(for mode: CaptureMode) -> String {
        preference(for: mode).displayName
    }

    private func preference(for mode: CaptureMode) -> ShortcutPreference {
        shortcutPreferencesStore.preference(for: mode.shortcutAction)
    }

    private func triggerCapture() {
        if appState.isScrollingCaptureActive {
            appState.cancelCaptureOperation()
            return
        }
        let options = CaptureOptions(
            showsCursor: showCursor,
            excludesDesktopWindows: hideDesktopIcons,
            delay: delayCapture ? .seconds(3) : .zero
        )
        appState.capture(mode: selectedMode, options: options)
    }

    private var selectedIntent: CaptureIntent {
        CaptureIntent(mode: selectedMode)
    }

    private var primaryButtonTitle: String {
        appState.isScrollingCaptureActive
            ? "Cancel Scrolling Capture"
            : selectedIntent.captureButtonTitle
    }

    private var primaryButtonSymbol: String {
        appState.isScrollingCaptureActive ? "xmark" : "sparkles"
    }

    private var scrollingProgressLabel: String {
        guard let progress = appState.progress else {
            return "Preparing scrolling capture…"
        }
        return "\(progress.capturedFrames) frames · \(progress.pixelHeight) px"
    }
}

struct MacToolbar: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedTool: AnnotationTool
    @ObservedObject var editorModel: AnnotationEditorModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(.red).frame(width: 12, height: 12)
                Circle().fill(.yellow).frame(width: 12, height: 12)
                Circle().fill(.green).frame(width: 12, height: 12)
            }
            .padding(.horizontal, 5)

            toolbarIcon(
                "Undo annotation",
                "arrow.uturn.backward",
                isDisabled: appState.activeCapture == nil || !editorModel.canUndo,
                action: appState.undoAnnotation
            )
                .keyboardShortcut("z", modifiers: .command)
            toolbarIcon(
                "Redo annotation",
                "arrow.uturn.forward",
                isDisabled: appState.activeCapture == nil || !editorModel.canRedo,
                action: appState.redoAnnotation
            )
                .keyboardShortcut("z", modifiers: [.command, .shift])

            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    selectedTool = tool
                } label: {
                    Label(tool.rawValue, systemImage: tool.symbol)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                        .foregroundStyle(selectedTool == tool ? .white : .white.opacity(0.78))
                        .background(selectedTool == tool ? Color.accentColor : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tool.rawValue) annotation tool")
                .accessibilityAddTraits(selectedTool == tool ? .isSelected : [])
            }

            Spacer()

            Image(systemName: "magnifyingglass")
                .frame(width: 24)
            Slider(value: $editorModel.zoom, in: 0.25...4)
                .frame(width: 86)
                .help("Zoom from 25% to 400%")
                .accessibilityLabel("Editor zoom")
                .accessibilityValue("\(Int((editorModel.zoom * 100).rounded())) percent")
            Text("\(Int((editorModel.zoom * 100).rounded()))%")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .frame(width: 44)
                .frame(height: 36)
                .background(.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .foregroundStyle(.white)
        .background(Color(red: 0.08, green: 0.12, blue: 0.19).opacity(0.93))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 22, y: 14)
    }

    private func toolbarIcon(
        _ label: String,
        _ symbol: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct MacEditorCanvas: View {
    @EnvironmentObject private var appState: AppState

    let shortcutGuidance: CaptureShortcutGuidance
    let selectedTool: AnnotationTool
    @ObservedObject var editorModel: AnnotationEditorModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label(captureTitle, systemImage: "photo")
                    .font(.subheadline.weight(.bold))
                Text(captureMetadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Tool: \(selectedTool.rawValue)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)

            ZStack {
                DottedCanvasBackground()
                if let capture = appState.activeCapture {
                    AnnotationEditor(
                        capture: capture,
                        selectedTool: selectedTool,
                        model: editorModel
                    )
                        .padding(32)
                } else {
                    EditableShotPreview()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 22, y: 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var captureTitle: String {
        appState.activeCapture?.title ?? "No capture yet"
    }

    private var captureMetadata: String {
        guard let capture = appState.activeCapture else {
            return shortcutGuidance.emptyCanvasText
        }
        return "\(capture.pixelSize.width) x \(capture.pixelSize.height) - ready to copy or edit"
    }
}

struct MacRecordingBar: View {
    @EnvironmentObject private var appState: AppState

    /// The Record shortcut is configurable in Settings, so the bar has to be
    /// the thing that honours it — nothing else listens for it.
    let shortcut: ShortcutPreference

    @State private var format: RecordingFormat = .mp4
    @State private var includesSystemAudio = true
    @State private var includesMicrophone = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                appState.startRecording(
                    format: format,
                    includesSystemAudio: includesSystemAudio,
                    includesMicrophone: includesMicrophone
                )
            } label: {
                Label(startLabel, systemImage: "record.circle.fill")
            }
            .buttonStyle(PrimaryCapsuleButtonStyle(tint: .red))
            .disabled(!canStart)
            .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
            .accessibilityLabel("Start \(format == .mp4 ? "video" : "GIF") recording")

            Picker("Recording format", selection: $format) {
                Text("MP4").tag(RecordingFormat.mp4)
                Text("GIF").tag(RecordingFormat.gif)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            .disabled(!canStart)

            Toggle("System audio", isOn: $includesSystemAudio)
                .disabled(format == .gif || !canStart)
                .help(format == .gif ? "GIF recording does not support audio." : "Include system audio")
            Toggle("Microphone", isOn: $includesMicrophone)
                .disabled(format == .gif || !canStart)
                .help(format == .gif ? "GIF recording does not support audio." : "Include microphone audio")

            recordingStatus

            if appState.recordingState.kind == .recording {
                Button(action: appState.stopRecording) {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .buttonStyle(DarkCapsuleButtonStyle())
                .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
                .accessibilityLabel("Stop recording")
            }

            if appState.canCancelRecording {
                Button(action: appState.cancelRecording) {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(DarkCapsuleButtonStyle())
                .accessibilityLabel("Cancel recording")
            }

            Spacer()
        }
        .padding(8)
        .background(Color(red: 0.08, green: 0.12, blue: 0.19).opacity(0.93))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 22, y: 14)
    }

    private var canStart: Bool {
        appState.canStartRecording
    }

    private var startLabel: String {
        format == .mp4 ? "Record Video" : "Record GIF"
    }

    @ViewBuilder
    private var recordingStatus: some View {
        switch appState.recordingState {
        case .idle:
            Text("Ready")
        case .preparing:
            ProgressView().controlSize(.small).help("Preparing recording")
        case .recording(let startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Label(elapsed(from: startedAt, to: context.date), systemImage: "timer")
                    .monospacedDigit()
            }
        case .stopping:
            Label("Finalizing…", systemImage: "hourglass")
        case .completed:
            Label("Saved locally", systemImage: "checkmark.circle")
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
        }
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct MacInspector: View {
    @EnvironmentObject private var appState: AppState

    let selectedTool: AnnotationTool
    @ObservedObject var editorModel: AnnotationEditorModel

    var body: some View {
        VStack(spacing: 12) {
            inspectorPanel {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Style")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(selectedTool.rawValue)
                            .font(.headline.weight(.bold))
                    }
                    Spacer()
                    Image(systemName: "paintpalette")
                }

                if selectedTool != .steps {
                    HStack {
                        ForEach(AnnotationPalette.options) { entry in
                            Button {
                                updateStyle { $0.color = entry.color }
                            } label: {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(entry.displayColor)
                                    .frame(height: 30)
                                    .overlay {
                                        if editorModel.style.color == entry.color {
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .stroke(.white, lineWidth: 2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Annotation color \(entry.accessibilityLabel)")
                            .accessibilityAddTraits(
                                editorModel.style.color == entry.color ? .isSelected : []
                            )
                        }
                    }
                }

                styleControls

                if selectedTool.allowsItemManipulation,
                   editorModel.hasSelection {
                    Button(role: .destructive, action: editorModel.deleteSelection) {
                        Label("Delete selected annotation", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            inspectorPanel {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.55))
                        Text("Export")
                            .font(.headline.weight(.bold))
                    }
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                }

                Button(action: appState.copyActiveCapture) {
                    Label("Copy screenshot", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DarkCapsuleButtonStyle())
                .disabled(appState.activeCapture == nil)

                HStack {
                    Button("Export PNG") { appState.saveActiveCapture(format: .png) }
                    Button("Export JPEG") { appState.saveActiveCapture(format: .jpeg) }
                }
                .buttonStyle(.bordered)
                .disabled(appState.activeCapture == nil)
            }

            inspectorPanel {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Library")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.55))
                        Text("Recent captures")
                            .font(.headline.weight(.bold))
                    }
                    Spacer()
                    Image(systemName: "photo.stack")
                }

                TextField(
                    "Search title, OCR, kind, or tags",
                    text: Binding(
                        get: { appState.searchText },
                        set: appState.search
                    )
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search capture library")

                if appState.records.isEmpty {
                    Text(appState.searchText.isEmpty ? "No local captures yet." : "No matching captures.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(appState.records) { record in
                                LibraryRecordRow(record: record)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
            }

            Spacer()
        }
        .padding(12)
        .frame(width: 310)
        .foregroundStyle(.white)
        .background(Color(red: 0.08, green: 0.12, blue: 0.19).opacity(0.93))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 22, y: 14)
    }

    private func inspectorPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(13)
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var styleControls: some View {
        switch selectedTool {
        case .select:
            Text("Click an annotation to move, resize, or delete it.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
        case .arrow:
            LabeledContent("Stroke", value: "\(Int(editorModel.style.strokeWidth.rounded())) px")
            Slider(value: styleBinding(\.strokeWidth), in: 1...20)
                .accessibilityLabel("Annotation stroke width")
        case .text:
            LabeledContent("Font size", value: "\(Int(editorModel.style.fontSize.rounded())) px")
            Slider(value: styleBinding(\.fontSize), in: 10...96)
                .accessibilityLabel("Annotation font size")
        case .highlight:
            LabeledContent("Opacity", value: "\(Int((editorModel.style.opacity * 100).rounded()))%")
            Slider(value: styleBinding(\.opacity), in: 0.1...1)
                .accessibilityLabel("Annotation highlight opacity")
        case .blur:
            LabeledContent("Radius", value: "\(Int(editorModel.style.blurRadius.rounded())) px")
            Slider(value: styleBinding(\.blurRadius), in: 1...30)
                .accessibilityLabel("Annotation blur radius")
        case .crop:
            Text("Drag across the image to set the export crop.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
        case .rect, .ellipse:
            LabeledContent("Stroke", value: "\(Int(editorModel.style.strokeWidth.rounded())) px")
            Slider(value: styleBinding(\.strokeWidth), in: 1...20)
                .accessibilityLabel("Annotation stroke width")
        case .steps:
            Text("Click to place a numbered step badge.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
        case .emoji:
            Text("Pick an emoji, then click to place it.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 6) {
                ForEach(AnnotationPalette.emojiOptions, id: \.self) { emoji in
                    Button {
                        updateStyle { $0.emoji = emoji }
                    } label: {
                        Text(emoji)
                            .font(.title2)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(
                                editorModel.style.emoji == emoji
                                    ? Color.accentColor.opacity(0.35)
                                    : Color.white.opacity(0.06)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Emoji \(emoji)")
                    .accessibilityAddTraits(editorModel.style.emoji == emoji ? .isSelected : [])
                }
            }
        }
    }

    private func styleBinding(_ keyPath: WritableKeyPath<AnnotationStyle, Double>) -> Binding<Double> {
        Binding(
            get: { editorModel.style[keyPath: keyPath] },
            set: { value in
                updateStyle { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func updateStyle(_ update: (inout AnnotationStyle) -> Void) {
        var style = editorModel.style
        update(&style)
        editorModel.style = style
    }

}

private struct LibraryRecordRow: View {
    @EnvironmentObject private var appState: AppState
    let record: CaptureRecord

    @State private var confirmsDelete = false
    @FocusState private var tagsFieldIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                LibraryThumbnail(recordID: record.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Text(metadata)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
            }

            TextField(
                "Tags, comma separated",
                text: Binding(
                    get: { appState.tagDraft(for: record) },
                    set: { appState.setTagDraft($0, for: record.id) }
                )
            )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($tagsFieldIsFocused)
                .onSubmit {
                    persistTags()
                    tagsFieldIsFocused = false
                }
                .onChange(of: tagsFieldIsFocused) {
                    if !tagsFieldIsFocused {
                        persistTags()
                    }
                }
                .accessibilityLabel("Tags for \(record.title)")

            HStack(spacing: 5) {
                recordButton("Open", symbol: "arrow.up.forward.app") {
                    appState.openRecord(record.id)
                }
                recordButton("Copy", symbol: "doc.on.doc") {
                    appState.copyRecord(record.id)
                }
                Menu {
                    if record.kind == .video || record.kind == .gif {
                        Button("Original \(record.kind == .gif ? "GIF" : "MP4")") {
                            appState.exportRecord(record.id, format: .png)
                        }
                    } else {
                        Button("PNG") { appState.exportRecord(record.id, format: .png) }
                        Button("JPEG") { appState.exportRecord(record.id, format: .jpeg) }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Export capture")
                .help(record.kind == .video || record.kind == .gif ? "Export original media" : "Export image format")
                recordButton("Reveal in Finder", symbol: "folder") {
                    appState.revealRecord(record.id)
                }
                recordButton("Delete", symbol: "trash", role: .destructive) {
                    confirmsDelete = true
                }
            }
        }
        .padding(9)
        .background(.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { appState.beginTagDraft(for: record) }
        .onChange(of: record.tags) { appState.beginTagDraft(for: record) }
        .confirmationDialog(
            "Delete \(record.title)?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { appState.deleteRecord(record.id) }
            Button("Cancel", role: .cancel) { confirmsDelete = false }
        } message: {
            Text("This permanently removes the local original, thumbnail, saved annotations, and metadata.")
        }
    }

    private func persistTags() {
        appState.persistTagDraft(for: record.id)
    }

    private var metadata: String {
        let dimensions = "\(record.pixelSize.width) × \(record.pixelSize.height)"
        if let duration = record.duration {
            return "\(record.kind.rawValue.capitalized) · \(dimensions) · \(duration.formatted(.number.precision(.fractionLength(1))))s"
        }
        return "\(record.kind.rawValue.capitalized) · \(dimensions)"
    }

    private func recordButton(
        _ label: String,
        symbol: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct LibraryThumbnail: View {
    @EnvironmentObject private var appState: AppState
    let recordID: UUID
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: 52, height: 36)
        .background(.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: recordID) {
            guard let url = await appState.thumbnailURL(for: recordID),
                  let data = try? await Task.detached(priority: .utility, operation: {
                      try Data(contentsOf: url)
                  }).value else { return }
            image = NSImage(data: data)
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    MacContentView(
        shortcutController: HotKeyController(
            registrar: PreviewHotKeyRegistrar(),
            action: {}
        ),
        shortcutPreferencesStore: ShortcutPreferencesStore()
    )
        .environmentObject(AppState.live())
}

private final class PreviewHotKeyRegistrar: HotKeyRegistering {
    struct Token {}

    func register(
        _ shortcut: ShortcutPreference,
        action: @escaping @MainActor () -> Void
    ) throws -> Token {
        Token()
    }

    func unregister(_ token: Token) {}
}
