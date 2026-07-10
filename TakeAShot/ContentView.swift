import SwiftUI

struct ContentView: View {
    @State private var selectedMode: CaptureMode = .area
    @State private var selectedTool: AnnotationTool = .arrow
    @State private var uploaded = true
    @State private var showShareSheet = false
    @State private var hideDesktopIcons = true
    @State private var showCursor = true
    @State private var delayedCapture = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        CaptureModePicker(selectedMode: $selectedMode)

                        EditorCanvas(selectedTool: selectedTool)

                        AnnotationToolBar(selectedTool: $selectedTool)

                        CaptureOptions(
                            hideDesktopIcons: $hideDesktopIcons,
                            showCursor: $showCursor,
                            delayedCapture: $delayedCapture
                        )

                        RecordingControls()

                        SharePanel(uploaded: $uploaded)

                        RecentCaptureList()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 110)
                }

                CaptureDock(selectedMode: selectedMode) {
                    showShareSheet = true
                }
            }
            .navigationTitle("Take a Shot")
            .inlineNavigationTitleForIOS()
            .toolbar {
                ToolbarItem {
                    Button {
                    } label: {
                        Image(systemName: "scissors")
                    }
                    .accessibilityLabel("Capture history")
                }

                ToolbarItem {
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: uploaded ? "checkmark.icloud.fill" : "icloud.and.arrow.up")
                    }
                    .accessibilityLabel(uploaded ? "Uploaded" : "Upload")
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ExportSheet(uploaded: $uploaded)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
