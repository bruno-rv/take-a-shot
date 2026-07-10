import AppKit
import SwiftUI

struct MacContentView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedMode: CaptureMode = .area
    @State private var selectedTool: AnnotationTool = .select
    @State private var hideDesktopIcons = true
    @State private var showCursor = true
    @State private var delayCapture = false
    @StateObject private var editorModel = AnnotationEditorModel()

    var body: some View {
        HStack(spacing: 14) {
            MacCaptureRail(
                selectedMode: $selectedMode,
                hideDesktopIcons: $hideDesktopIcons,
                showCursor: $showCursor,
                delayCapture: $delayCapture
            )

            VStack(spacing: 14) {
                MacToolbar(
                    selectedTool: $selectedTool,
                    editorModel: editorModel
                )
                MacEditorCanvas(
                    selectedTool: selectedTool,
                    editorModel: editorModel
                )
                MacRecordingBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MacInspector(
                selectedTool: selectedTool,
                editorModel: editorModel
            )
        }
        .padding(18)
        .background {
            LinearGradient(
                colors: [
                    Color(red: 0.88, green: 0.92, blue: 0.98),
                    Color(red: 0.74, green: 0.81, blue: 0.9)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .onAppear(perform: loadActiveCapture)
        .onChange(of: appState.activeCapture?.id) {
            loadActiveCapture()
        }
    }

    private func loadActiveCapture() {
        if let capture = appState.activeCapture {
            editorModel.load(capture)
        }
    }
}

struct MacCaptureRail: View {
    @EnvironmentObject private var appState: AppState

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
                ForEach(CaptureMode.allCases) { mode in
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
            .disabled(!appState.isScrollingCaptureActive && !selectedIntent.isAvailable)

            if appState.isScrollingCaptureActive {
                Text(scrollingProgressLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Text("Global shortcut: Shift Option 5")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.56))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .frame(width: 250)
        .foregroundStyle(.white)
        .background(Color(red: 0.08, green: 0.12, blue: 0.19).opacity(0.93))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 14)
    }

    private func shortcut(for mode: CaptureMode) -> String {
        switch mode {
        case .area: "A"
        case .window: "W"
        case .fullScreen: "F"
        case .scrolling: "S"
        case .record: "R"
        }
    }

    private func triggerCapture() {
        if appState.isScrollingCaptureActive {
            ScreenCaptureController.shared.cancelScrollingCapture()
            return
        }
        guard selectedIntent.isAvailable else { return }
        let options = CaptureOptions(
            showsCursor: showCursor,
            excludesDesktopWindows: hideDesktopIcons,
            delay: delayCapture ? .seconds(3) : .zero
        )
        ScreenCaptureController.shared.scheduleCapture(mode: selectedMode, options: options)
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
        guard let progress = appState.scrollingCaptureProgress else {
            return "Preparing scrolling capture…"
        }
        return "\(progress.capturedFrames) frames · \(progress.pixelHeight) px"
    }
}

struct MacToolbar: View {
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

            toolbarIcon("Undo", "arrow.uturn.backward", action: editorModel.undo)
                .keyboardShortcut("z", modifiers: .command)
            toolbarIcon("Redo", "arrow.uturn.forward", action: editorModel.redo)
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
            }

            Spacer()

            Image(systemName: "magnifyingglass")
                .frame(width: 24)
            Slider(value: $editorModel.zoom, in: 0.25...4)
                .frame(width: 86)
                .help("Zoom from 25% to 400%")
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
    }

    private func toolbarIcon(
        _ label: String,
        _ symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

struct MacEditorCanvas: View {
    @EnvironmentObject private var appState: AppState

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
            .overlay(alignment: .bottomLeading) {
                Button {
                } label: {
                    Label("Clean up background", systemImage: "wand.and.sparkles")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                }
                .buttonStyle(.plain)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(12)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var captureTitle: String {
        appState.capturedImage == nil ? "Demo screenshot" : appState.capturedTitle
    }

    private var captureMetadata: String {
        guard let capture = appState.activeCapture else {
            return "Press Shift Option 5 to capture"
        }
        return "\(capture.pixelSize.width) x \(capture.pixelSize.height) - ready to copy or edit"
    }
}

struct MacRecordingBar: View {
    var body: some View {
        HStack(spacing: 8) {
            Button {
            } label: {
                Label("Record", systemImage: "record.circle.fill")
            }
            .buttonStyle(PrimaryCapsuleButtonStyle(tint: .red))

            ForEach([("Screen", "rectangle.dashed"), ("GIF", "film"), ("00:12", "timer"), ("Stop", "stop.circle")], id: \.0) { item in
                Button {
                } label: {
                    Label(item.0, systemImage: item.1)
                }
                .buttonStyle(DarkCapsuleButtonStyle())
            }

            Spacer()
        }
        .padding(8)
        .background(Color(red: 0.08, green: 0.12, blue: 0.19).opacity(0.93))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

                HStack {
                    ForEach(Array(styleColors.enumerated()), id: \.offset) { _, entry in
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
                    }
                }

                styleControls

                if selectedTool.allowsItemManipulation,
                   editorModel.selectedItemID != nil {
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
                        Text("Cloud")
                            .font(.headline.weight(.bold))
                    }
                    Spacer()
                    Image(systemName: "icloud")
                }

                Button {
                } label: {
                    Text("Cloud upload — Coming later")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DarkCapsuleButtonStyle())
                .disabled(true)

                Button {
                    copyRenderedCapture()
                } label: {
                    Label("Copy screenshot", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DarkCapsuleButtonStyle())
                .disabled(appState.capturedImage == nil)

                if let message = appState.editorErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
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

                ForEach(recentCaptures) { capture in
                    HStack(spacing: 10) {
                        Image(systemName: capture.symbol)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capture.title)
                                .font(.caption.weight(.bold))
                            Text(capture.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.54))
                        }
                        Spacer()
                        Text(capture.status)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.64))
                    }
                    .padding(9)
                    .background(.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            Spacer()
        }
        .padding(12)
        .frame(width: 310)
        .foregroundStyle(.white)
        .background(Color(red: 0.08, green: 0.12, blue: 0.19).opacity(0.93))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        case .text:
            LabeledContent("Font size", value: "\(Int(editorModel.style.fontSize.rounded())) px")
            Slider(value: styleBinding(\.fontSize), in: 10...96)
        case .highlight:
            LabeledContent("Opacity", value: "\(Int((editorModel.style.opacity * 100).rounded()))%")
            Slider(value: styleBinding(\.opacity), in: 0.1...1)
        case .blur:
            LabeledContent("Radius", value: "\(Int(editorModel.style.blurRadius.rounded())) px")
            Slider(value: styleBinding(\.blurRadius), in: 1...30)
        case .crop:
            Text("Drag across the image to set the export crop.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    private var styleColors: [(color: RGBAColor, displayColor: Color)] {
        [
            (.red, .red),
            (RGBAColor(red: 0.16, green: 0.5, blue: 1, alpha: 1), .accentColor),
            (RGBAColor(red: 1, green: 0.82, blue: 0.12, alpha: 1), .yellow),
            (RGBAColor(red: 0.13, green: 0.17, blue: 0.25, alpha: 1), Color(red: 0.13, green: 0.17, blue: 0.25)),
        ]
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

    private func copyRenderedCapture() {
        guard let capture = editorModel.capture else { return }
        let document = editorModel.document
        let coordinator = AnnotationExportCoordinator(
            renderService: DetachedAnnotationRenderService(),
            clipboard: SystemAnnotationClipboardPublisher()
        )
        appState.setEditorError(nil)

        Task {
            do {
                try await coordinator.copy(capture: capture, document: document)
            } catch {
                appState.setEditorError("Couldn’t copy annotated screenshot.")
            }
        }
    }
}

@MainActor
private final class SystemAnnotationClipboardPublisher: AnnotationClipboardPublishing {
    func publish(_ rendered: CGImage) {
        let image = NSImage(
            cgImage: rendered,
            size: CGSize(width: rendered.width, height: rendered.height)
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

#Preview {
    MacContentView()
        .environmentObject(AppState.shared)
}
