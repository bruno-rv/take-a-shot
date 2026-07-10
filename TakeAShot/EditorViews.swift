import SwiftUI

struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.91, green: 0.95, blue: 0.99),
                Color(red: 0.78, green: 0.84, blue: 0.91)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct CaptureModePicker: View {
    @Binding var selectedMode: CaptureMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Capture", subtitle: "Choose what to grab")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(CaptureMode.allCases) { mode in
                    Button {
                        selectedMode = mode
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: mode.symbol)
                                .font(.system(size: 18, weight: .semibold))
                            Text(mode.rawValue)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                        .foregroundStyle(selectedMode == mode ? .white : Color.primary.opacity(0.76))
                        .background(selectedMode == mode ? Color.accentColor : Color.white.opacity(0.74))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.rawValue)
                }
            }
        }
        .cardSurface()
    }
}

struct EditorCanvas: View {
    let selectedTool: AnnotationTool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("billing-flow.png", systemImage: "photo")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Tool: \(selectedTool.rawValue)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            ZStack {
                DottedCanvasBackground()

                EditableShotPreview()
            }
            .frame(height: 430)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .top) {
                FloatingQuickActions()
                    .padding(.top, 14)
            }
        }
        .cardSurface(padding: 12)
    }
}

struct AnnotationToolBar: View {
    @Binding var selectedTool: AnnotationTool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(AnnotationTool.allCases) { tool in
                    Button {
                        selectedTool = tool
                    } label: {
                        Label(tool.rawValue, systemImage: tool.symbol)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .foregroundStyle(selectedTool == tool ? .white : Color.primary.opacity(0.74))
                            .background(selectedTool == tool ? Color.accentColor : Color.white.opacity(0.78))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .cardSurface(padding: 10)
    }
}

struct CaptureOptions: View {
    @Binding var hideDesktopIcons: Bool
    @Binding var showCursor: Bool
    @Binding var delayedCapture: Bool

    var body: some View {
        VStack(spacing: 12) {
            Toggle("Hide desktop icons", isOn: $hideDesktopIcons)
            Toggle("Show cursor", isOn: $showCursor)
            Toggle("Delay 3 seconds", isOn: $delayedCapture)
        }
        .font(.subheadline.weight(.medium))
        .cardSurface()
    }
}

struct RecordingControls: View {
    var body: some View {
        HStack(spacing: 8) {
            Button {
            } label: {
                Label("Record", systemImage: "record.circle.fill")
            }
            .buttonStyle(PrimaryCapsuleButtonStyle(tint: .red))

            Button {
            } label: {
                Label("Screen", systemImage: "rectangle.dashed")
            }
            .buttonStyle(DarkCapsuleButtonStyle())

            Button {
            } label: {
                Label("GIF", systemImage: "film")
            }
            .buttonStyle(DarkCapsuleButtonStyle())

            Button {
            } label: {
                Label("00:12", systemImage: "timer")
            }
            .buttonStyle(DarkCapsuleButtonStyle())
        }
        .labelStyle(.titleAndIcon)
        .minimumScaleFactor(0.75)
    }
}

struct SharePanel: View {
    @Binding var uploaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Share", subtitle: "Cloud link")

            Button {
                uploaded.toggle()
            } label: {
                Label(uploaded ? "Uploaded" : "Upload", systemImage: uploaded ? "checkmark.icloud.fill" : "icloud.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryCapsuleButtonStyle(tint: uploaded ? .green : .accentColor))

            HStack {
                Image(systemName: "link")
                Text(uploaded ? "shot.link/tas/billing-flow" : "Upload to create link")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "doc.on.doc")
            }
            .foregroundStyle(.secondary)
            .padding(12)
            .background(Color.white.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                ForEach(["PNG", "JPG", "GIF", "MP4"], id: \.self) { format in
                    Button(format) {
                    }
                    .buttonStyle(FormatButtonStyle())
                }
            }
        }
        .cardSurface()
    }
}

struct RecentCaptureList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Library", subtitle: "Recent captures")

            ForEach(recentCaptures) { capture in
                HStack(spacing: 12) {
                    Image(systemName: capture.symbol)
                        .font(.headline)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(capture.title)
                            .font(.subheadline.weight(.bold))
                        Text(capture.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(capture.status)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.white.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .cardSurface()
    }
}

struct CaptureDock: View {
    let selectedMode: CaptureMode
    let exportAction: () -> Void

    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: 10) {
                Button {
                } label: {
                    Label("Capture \(selectedMode.rawValue)", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(tint: .accentColor))

                Button(action: exportAction) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color(red: 0.1, green: 0.14, blue: 0.22))
                .clipShape(Circle())
                .accessibilityLabel("Export")
            }
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }
}

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var uploaded: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    uploaded = true
                    dismiss()
                } label: {
                    Label("Upload and copy link", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(tint: .accentColor))

                Button {
                    dismiss()
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryCapsuleButtonStyle())

                Button {
                    dismiss()
                } label: {
                    Label("Copy image", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryCapsuleButtonStyle())

                Spacer()
            }
            .padding()
            .navigationTitle("Export")
            .inlineNavigationTitleForIOS()
        }
    }
}
