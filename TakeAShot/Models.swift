import CoreGraphics
import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum CaptureMode: String, CaseIterable, Identifiable {
    case area = "Area"
    case window = "Window"
    case fullScreen = "Fullscreen"
    case scrolling = "Scrolling"
    case record = "Record"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .area: "selection.pin.in.out"
        case .window: "macwindow"
        case .fullScreen: "viewfinder"
        case .scrolling: "arrow.up.and.down.and.arrow.left.and.right"
        case .record: "video"
        }
    }
}

enum CaptureIntent: Equatable, Sendable {
    case areaSelection
    case windowPicker
    case display
    case scrollingWindowPicker
    case recordingPicker

    init(mode: CaptureMode) {
        switch mode {
        case .area:
            self = .areaSelection
        case .window:
            self = .windowPicker
        case .fullScreen:
            self = .display
        case .scrolling:
            self = .scrollingWindowPicker
        case .record:
            self = .recordingPicker
        }
    }

    var isAvailable: Bool {
        true
    }

    var captureButtonTitle: String {
        switch self {
        case .areaSelection:
            "Capture Area"
        case .windowPicker:
            "Capture Window"
        case .display:
            "Capture Fullscreen"
        case .scrollingWindowPicker:
            "Capture Scrolling Window"
        case .recordingPicker:
            "Choose Recording Source"
        }
    }
}

struct CaptureSource: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case display(DisplayGeometry)
        case window(CGWindowID, CGRect)
    }

    let id: String
    let title: String
    let kind: Kind
}

struct CaptureSources: Equatable, Sendable {
    let displays: [CaptureSource]
    let windows: [CaptureSource]
}

struct AreaSelection: Equatable, Sendable {
    let rect: CGRect
    let display: DisplayGeometry

    var displayID: CGDirectDisplayID { display.id }

    init(localRect: CGRect, display: DisplayGeometry) {
        rect = localRect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
        self.display = display
    }
}

enum CaptureError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case sourceUnavailable
    case invalidSelection
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen recording permission is required."
        case .sourceUnavailable:
            "The selected capture source is no longer available."
        case .invalidSelection:
            "The selected area is not valid."
        case .captureFailed(let message):
            message
        }
    }
}

protocol ScreenshotCapturing: Sendable {
    func sources() async throws -> CaptureSources
    func captureArea(
        _ rect: CGRect,
        display: DisplayGeometry,
        options: CaptureOptions
    ) async throws -> CapturedImage
    func captureDisplay(
        _ displayID: CGDirectDisplayID,
        options: CaptureOptions
    ) async throws -> CapturedImage
    func captureWindow(
        _ windowID: CGWindowID,
        options: CaptureOptions
    ) async throws -> CapturedImage
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select = "Select"
    case arrow = "Arrow"
    case text = "Text"
    case highlight = "Highlight"
    case blur = "Blur"
    case crop = "Crop"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .text: "text.cursor"
        case .highlight: "highlighter"
        case .blur: "drop.degreesign"
        case .crop: "crop"
        }
    }

    var allowsItemManipulation: Bool { self == .select }
}

#if os(macOS)
struct PresentedError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let recoveryTitle: String?

    static func == (lhs: PresentedError, rhs: PresentedError) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.message == rhs.message
            && lhs.recoveryTitle == rhs.recoveryTitle
    }
}

protocol AppCaptureExporting: Sendable {
    func copy(capture: CapturedImage, document: AnnotationDocument) async throws
    func save(
        capture: CapturedImage,
        document: AnnotationDocument,
        format: ExportFormat
    ) async throws
    func inspectRecording(
        at url: URL,
        format: RecordingFormat,
        createdAt: Date
    ) async throws -> RecordedMedia
    func copyFile(at url: URL) async throws
    func saveFile(at url: URL) async throws
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var activeCapture: CapturedImage?
    @Published private(set) var annotationHistory: AnnotationDocument
    @Published private(set) var records: [CaptureRecord] = []
    @Published private(set) var searchText = ""
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var progress: ScrollingCaptureProgress?
    @Published private(set) var isScrollingCaptureActive = false
    @Published var presentedError: PresentedError?

    let annotationEditor: AnnotationEditorModel

    private let library: CaptureLibraryStore
    private let recording: RecordingEngine
    private let exporter: any AppCaptureExporting
    private let captureAction: @MainActor (CaptureMode, CaptureOptions) -> Void
    private let cancelCaptureAction: @MainActor () -> Void
    private let recordingTargetPicker: @MainActor () async throws -> RecordingTarget?
    private var annotationSubscription: AnyCancellable?
    private var recordingTask: Task<Void, Never>?
    private var recordingMonitor: Task<Void, Never>?
    private var activeRecordingFormat: RecordingFormat?
    private var recordingCreatedAt: Date?

    init(
        library: CaptureLibraryStore,
        recording: RecordingEngine,
        exporter: any AppCaptureExporting,
        captureAction: @escaping @MainActor (CaptureMode, CaptureOptions) -> Void,
        cancelCaptureAction: @escaping @MainActor () -> Void,
        recordingTargetPicker: @escaping @MainActor () async throws -> RecordingTarget?
    ) {
        self.library = library
        self.recording = recording
        self.exporter = exporter
        self.captureAction = captureAction
        self.cancelCaptureAction = cancelCaptureAction
        self.recordingTargetPicker = recordingTargetPicker
        let editor = AnnotationEditorModel()
        annotationEditor = editor
        annotationHistory = editor.document
        annotationSubscription = editor.$state.sink { [weak self] state in
            self?.annotationHistory = state.document
        }
        reloadLibrary()
    }

    static func live() -> AppState {
        let rootURL = defaultLibraryURL
        let library = CaptureLibraryStore(rootURL: rootURL, ocr: VisionOCRService())
        let publisher = AppCapturePublisher()
        let controller = ScreenCaptureController(
            capturer: ScreenCaptureEngine(),
            persistence: library,
            publisher: publisher,
            reporter: publisher
        )
        let state = AppState(
            library: library,
            recording: RecordingEngine(),
            exporter: LiveAppCaptureExporter(),
            captureAction: { mode, options in
                controller.scheduleCapture(mode: mode, options: options)
            },
            cancelCaptureAction: {
                controller.cancelCurrentOperation()
            },
            recordingTargetPicker: {
                try await controller.chooseRecordingTarget()
            }
        )
        publisher.onCapture = { [weak state] capture in state?.receiveCapture(capture) }
        publisher.onProgress = { [weak state] progress in state?.updateScrollingCapture(progress) }
        publisher.onScrollingChanged = { [weak state] active in
            if active { state?.beginScrollingCapture() } else { state?.endScrollingCapture() }
        }
        publisher.onError = { [weak state] error in state?.present(error, title: "Capture Failed") }
        HotKeyController.shared.captureAction = { [weak state] in
            state?.capture(mode: .area, options: CaptureOptions())
        }
        return state
    }

    func capture(mode: CaptureMode, options: CaptureOptions) {
        captureAction(mode, options)
    }

    func receiveCapture(_ capture: CapturedImage) {
        activeCapture = capture
        annotationEditor.load(capture)
        annotationHistory = annotationEditor.document
        reloadLibrary()
    }

    func stopRecording() {
        guard recordingState.kind == .recording, recordingTask == nil else { return }
        recordingTask = Task { [weak self] in
            guard let self else { return }
            defer { recordingTask = nil }
            do {
                recordingState = .stopping
                let output = try await recording.stop()
                guard let format = activeRecordingFormat,
                      let createdAt = recordingCreatedAt else { return }
                let media = try await exporter.inspectRecording(
                    at: output,
                    format: format,
                    createdAt: createdAt
                )
                _ = try await library.register(media: media)
                records = await library.search(searchText)
                recordingState = .completed(output)
                recordingMonitor?.cancel()
            } catch is CancellationError {
                recordingState = .idle
            } catch {
                recordingState = .failed(error.localizedDescription)
                present(error, title: "Recording Failed")
            }
        }
    }

    func startRecording(
        format: RecordingFormat,
        includesSystemAudio: Bool,
        includesMicrophone: Bool
    ) {
        guard recordingTask == nil,
              [.idle, .completed, .failed].contains(recordingState.kind) else { return }
        recordingTask = Task { [weak self] in
            guard let self else { return }
            defer { recordingTask = nil }
            do {
                guard let target = try await recordingTargetPicker() else { return }
                let allowsAudio = format == .mp4
                let request = RecordingRequest(
                    target: target,
                    format: format,
                    includesSystemAudio: allowsAudio && includesSystemAudio,
                    includesMicrophone: allowsAudio && includesMicrophone,
                    framesPerSecond: format == .gif ? 10 : 30
                )
                activeRecordingFormat = format
                recordingCreatedAt = .now
                recordingState = .preparing
                beginRecordingStateObservation()
                try await recording.start(request: request)
                recordingState = await recording.state
            } catch is CancellationError {
                recordingState = .idle
            } catch {
                recordingState = .failed(error.localizedDescription)
                present(error, title: "Recording Failed")
            }
        }
    }

    func cancelCurrentOperation() {
        cancelCaptureAction()
        recordingTask?.cancel()
        recordingTask = nil
        guard [.preparing, .recording, .stopping].contains(recordingState.kind) else { return }
        Task { [weak self] in
            guard let self else { return }
            await recording.cancel()
            recordingMonitor?.cancel()
            recordingState = await recording.state
        }
    }

    func copyActiveCapture() {
        guard let capture = activeCapture else { return }
        let document = annotationHistory
        Task { [weak self] in
            do {
                try await self?.exporter.copy(capture: capture, document: document)
            } catch {
                self?.present(error, title: "Copy Failed")
            }
        }
    }

    func saveActiveCapture(format: ExportFormat) {
        guard let capture = activeCapture else { return }
        let document = annotationHistory
        Task { [weak self] in
            do {
                try await self?.exporter.save(
                    capture: capture,
                    document: document,
                    format: format
                )
            } catch {
                self?.present(error, title: "Export Failed")
            }
        }
    }

    func openRecord(_ id: UUID) {
        Task { [weak self] in
            guard let self,
                  let record = records.first(where: { $0.id == id }) else { return }
            do {
                if record.kind == .video || record.kind == .gif {
                    NSWorkspace.shared.open(try await library.originalURL(for: id))
                } else {
                    receiveCapture(try await library.loadCapture(id: id))
                }
            } catch {
                present(error, title: "Open Failed")
            }
        }
    }

    func copyRecord(_ id: UUID) {
        Task { [weak self] in
            guard let self,
                  let record = records.first(where: { $0.id == id }) else { return }
            do {
                if record.kind == .video || record.kind == .gif {
                    try await exporter.copyFile(at: library.originalURL(for: id))
                } else {
                    let capture = try await library.loadCapture(id: id)
                    try await exporter.copy(
                        capture: capture,
                        document: AnnotationDocument(captureID: capture.id)
                    )
                }
            } catch {
                present(error, title: "Copy Failed")
            }
        }
    }

    func exportRecord(_ id: UUID, format: ExportFormat) {
        Task { [weak self] in
            guard let self,
                  let record = records.first(where: { $0.id == id }) else { return }
            do {
                if record.kind == .video || record.kind == .gif {
                    try await exporter.saveFile(at: library.originalURL(for: id))
                } else {
                    let capture = try await library.loadCapture(id: id)
                    try await exporter.save(
                        capture: capture,
                        document: AnnotationDocument(captureID: capture.id),
                        format: format
                    )
                }
            } catch {
                present(error, title: "Export Failed")
            }
        }
    }

    func revealRecord(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await library.originalURL(for: id)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                present(error, title: "Reveal Failed")
            }
        }
    }

    func thumbnailURL(for id: UUID) async -> URL? {
        try? await library.thumbnailURL(for: id)
    }

    func deleteRecord(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.delete(id: id)
                records = await library.search(searchText)
                if activeCapture?.id == id { activeCapture = nil }
            } catch {
                present(error, title: "Delete Failed")
            }
        }
    }

    func updateTags(_ tags: [String], for id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await library.updateTags(id: id, tags: tags)
                records = await library.search(searchText)
            } catch {
                present(error, title: "Tag Update Failed")
            }
        }
    }

    func search(_ query: String) {
        searchText = query
        Task { [weak self] in
            guard let self else { return }
            records = await library.search(query)
        }
    }

    func undoAnnotation() {
        annotationEditor.undo()
        annotationHistory = annotationEditor.document
    }

    func redoAnnotation() {
        annotationEditor.redo()
        annotationHistory = annotationEditor.document
    }

    func dismissPresentedError() {
        presentedError = nil
    }

    func explainCloudUploadUnavailable() {
        presentedError = PresentedError(
            title: "Cloud Upload",
            message: "Cloud upload is coming later. Captures remain local on this Mac.",
            recoveryTitle: nil
        )
    }

    func beginScrollingCapture() {
        isScrollingCaptureActive = true
        progress = nil
    }

    func updateScrollingCapture(_ progress: ScrollingCaptureProgress) {
        isScrollingCaptureActive = true
        self.progress = progress
    }

    func endScrollingCapture() {
        isScrollingCaptureActive = false
        progress = nil
    }

    func present(_ error: Error, title: String) {
        presentedError = PresentedError(
            title: title,
            message: error.localizedDescription,
            recoveryTitle: nil
        )
    }

    private func reloadLibrary() {
        Task { [weak self] in
            guard let self else { return }
            do {
                records = try await library.load()
            } catch {
                present(error, title: "Library Failed")
            }
        }
    }

    private func beginRecordingStateObservation() {
        recordingMonitor?.cancel()
        recordingMonitor = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let state = await recording.state
                if state.kind == .completed { return }
                recordingState = state
                if state.kind == .failed {
                    presentedError = PresentedError(
                        title: "Recording Failed",
                        message: state.failureMessage ?? "The recording failed.",
                        recoveryTitle: nil
                    )
                    return
                }
                if state.kind == .idle { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private static var defaultLibraryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return applicationSupport.appendingPathComponent("TakeAShot", isDirectory: true)
    }
}

private extension RecordingState {
    var failureMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}
#endif
