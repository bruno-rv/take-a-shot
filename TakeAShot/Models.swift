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
        self != .recordingPicker
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
enum PresentedErrorRecovery: Equatable, Sendable {
    case openScreenRecordingSettings
    case openAccessibilitySettings
    case recordWithoutMicrophone

    var title: String {
        switch self {
        case .openScreenRecordingSettings, .openAccessibilitySettings: "Open Settings"
        case .recordWithoutMicrophone: "Record Without Microphone"
        }
    }
}

struct PresentedError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let recovery: PresentedErrorRecovery?
}

protocol AppLibraryServing: Sendable {
    func load(matching query: String) async throws -> [CaptureRecord]
    func loadIssues() async -> [CaptureLibraryLoadIssue]
    func search(_ query: String) async -> [CaptureRecord]
    func register(media: RecordedMedia) async throws -> CaptureRecord
    func saveAnnotations(
        _ document: AnnotationDocument,
        for id: UUID,
        editedAt: Date
    ) async throws
    func loadAnnotations(for id: UUID) async throws -> AnnotationDocument
    func delete(id: UUID) async throws
    func updateTags(id: UUID, tags: [String]) async throws
    func originalURL(for id: UUID) async throws -> URL
    func thumbnailURL(for id: UUID) async throws -> URL
    func loadCapture(id: UUID) async throws -> CapturedImage
}

extension AppLibraryServing {
    func loadIssues() async -> [CaptureLibraryLoadIssue] { [] }
}

extension CaptureLibraryStore: AppLibraryServing {}

protocol AppRecordingControlling: Sendable {
    var state: RecordingState { get async }
    func start(request: RecordingRequest) async throws
    func stop() async throws -> URL
    func cancel() async
}

extension RecordingEngine: AppRecordingControlling {}

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
    func discardFile(at url: URL) async throws
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

    private let library: any AppLibraryServing
    private let recording: any AppRecordingControlling
    private let exporter: any AppCaptureExporting
    private let captureAction: @MainActor (CaptureMode, CaptureOptions) -> Void
    private let cancelCaptureAction: @MainActor () -> Void
    private let recordingTargetPicker: @MainActor () async throws -> RecordingTarget?
    private let recoveryAction: @MainActor (PresentedErrorRecovery) -> Void
    private var annotationSubscription: AnyCancellable?
    private var annotationPersistenceTask: Task<Void, Error>?
    private var observedAnnotationDocument: AnnotationDocument?
    private var captureSwitchTask: Task<Void, Never>?
    private var captureSwitchGeneration: UInt64 = 0
    private var isInstallingAnnotationDocument = false
    private var recordingTask: Task<Void, Never>?
    private var recordingCleanupBarrier: Task<Void, Never>?
    private var recordingMonitor: Task<Void, Never>?
    private var recordingGeneration: UInt64 = 0
    private var activeRecordingFormat: RecordingFormat?
    private var recordingCreatedAt: Date?
    private var microphoneFallbackRequest: RecordingRequest?
    private var libraryQueryGeneration: UInt64 = 0

    init(
        library: any AppLibraryServing,
        recording: any AppRecordingControlling,
        exporter: any AppCaptureExporting,
        captureAction: @escaping @MainActor (CaptureMode, CaptureOptions) -> Void,
        cancelCaptureAction: @escaping @MainActor () -> Void,
        recordingTargetPicker: @escaping @MainActor () async throws -> RecordingTarget?,
        recoveryAction: @escaping @MainActor (PresentedErrorRecovery) -> Void = { _ in }
    ) {
        self.library = library
        self.recording = recording
        self.exporter = exporter
        self.captureAction = captureAction
        self.cancelCaptureAction = cancelCaptureAction
        self.recordingTargetPicker = recordingTargetPicker
        self.recoveryAction = recoveryAction
        let editor = AnnotationEditorModel()
        annotationEditor = editor
        annotationHistory = editor.document
        observedAnnotationDocument = editor.document
        annotationSubscription = editor.$state.sink { [weak self] state in
            guard let self else { return }
            self.annotationHistory = state.document
            guard self.observedAnnotationDocument != state.document else { return }
            self.observedAnnotationDocument = state.document
            guard !self.isInstallingAnnotationDocument else { return }
            self.queueAnnotationPersistence(state.document)
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
            },
            recoveryAction: { recovery in
                let urlString: String?
                switch recovery {
                case .openScreenRecordingSettings:
                    urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                case .openAccessibilitySettings:
                    urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                case .recordWithoutMicrophone:
                    urlString = nil
                }
                if let urlString, let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
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
        guard CaptureIntent(mode: mode).isAvailable else { return }
        captureAction(mode, options)
    }

    func receiveCapture(_ capture: CapturedImage) {
        if activeCapture == nil {
            install(capture: capture, document: AnnotationDocument(captureID: capture.id))
        } else {
            switchToCapture(capture, document: AnnotationDocument(captureID: capture.id))
        }
        reloadLibrary()
    }

    var canStartRecording: Bool {
        recordingTask == nil
            && recordingCleanupBarrier == nil
            && [.idle, .completed, .failed].contains(recordingState.kind)
    }

    var canCancelRecording: Bool {
        recordingCleanupBarrier == nil
            && [.preparing, .recording].contains(recordingState.kind)
    }

    func stopRecording() {
        guard recordingState.kind == .recording,
              recordingTask == nil,
              recordingCleanupBarrier == nil else { return }
        recordingGeneration &+= 1
        let token = recordingGeneration
        recordingMonitor?.cancel()
        recordingState = .stopping
        recordingTask = Task { [weak self] in
            guard let self else { return }
            var completedOutput: URL?
            do {
                let output = try await recording.stop()
                completedOutput = output
                try validateRecordingOperation(token)
                guard let format = activeRecordingFormat,
                      let createdAt = recordingCreatedAt else { return }
                let media = try await exporter.inspectRecording(
                    at: output,
                    format: format,
                    createdAt: createdAt
                )
                try validateRecordingOperation(token)
                _ = try await library.register(media: media)
                try validateRecordingOperation(token)
                recordingState = .completed(output)
                finishRecordingTask(token: token)
                reloadLibrary()
            } catch is CancellationError {
                return
            } catch {
                if let completedOutput {
                    try? await exporter.discardFile(at: completedOutput)
                    guard recordingGeneration == token else { return }
                }
                recordingState = .failed(error.localizedDescription)
                present(error, title: "Recording Failed")
                finishRecordingTask(token: token)
            }
        }
    }

    func startRecording(
        format: RecordingFormat,
        includesSystemAudio: Bool,
        includesMicrophone: Bool
    ) {
        guard canStartRecording else { return }
        recordingGeneration &+= 1
        let token = recordingGeneration
        recordingState = .preparing
        recordingTask = Task { [weak self] in
            guard let self else { return }
            var attemptedRequest: RecordingRequest?
            do {
                let target = try await recordingTargetPicker()
                try validateRecordingOperation(token)
                guard let target else {
                    recordingState = .idle
                    finishRecordingTask(token: token)
                    return
                }
                let allowsAudio = format == .mp4
                let request = RecordingRequest(
                    target: target,
                    format: format,
                    includesSystemAudio: allowsAudio && includesSystemAudio,
                    includesMicrophone: allowsAudio && includesMicrophone,
                    framesPerSecond: format == .gif ? 10 : 30
                )
                attemptedRequest = request
                try await startRecording(request: request, token: token)
            } catch is CancellationError {
                return
            } catch {
                await handleRecordingStartFailure(error, request: attemptedRequest, token: token)
            }
        }
    }

    private func startRecording(request: RecordingRequest, token: UInt64) async throws {
        activeRecordingFormat = request.format
        recordingCreatedAt = .now
        try await recording.start(request: request)
        try validateRecordingOperation(token)
        let state = await recording.state
        try validateRecordingOperation(token)
        recordingState = state
        if state.kind == .recording || state.kind == .preparing {
            beginRecordingStateObservation(token: token)
        }
        finishRecordingTask(token: token)
    }

    private func startRecordingWithoutPicker(_ request: RecordingRequest) {
        guard canStartRecording else { return }
        recordingGeneration &+= 1
        let token = recordingGeneration
        recordingState = .preparing
        recordingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await startRecording(request: request, token: token)
            } catch is CancellationError {
                return
            } catch {
                await handleRecordingStartFailure(error, request: request, token: token)
            }
        }
    }

    func cancelCurrentOperation() {
        cancelCaptureAction()
        guard recordingCleanupBarrier == nil,
              [.preparing, .recording].contains(recordingState.kind) else { return }
        recordingGeneration &+= 1
        let cleanupToken = recordingGeneration
        let operation = recordingTask
        operation?.cancel()
        recordingMonitor?.cancel()
        recordingState = .preparing
        recordingCleanupBarrier = Task { [weak self] in
            guard let self else { return }
            await recording.cancel()
            await operation?.value
            guard recordingGeneration == cleanupToken else { return }
            recordingTask = nil
            recordingCleanupBarrier = nil
            activeRecordingFormat = nil
            recordingCreatedAt = nil
            microphoneFallbackRequest = nil
            recordingState = .idle
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
                    try await flushAnnotations()
                    let capture = try await library.loadCapture(id: id)
                    let document = try await library.loadAnnotations(for: id)
                    switchToCapture(capture, document: document)
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
                    try await flushAnnotations()
                    let capture = try await library.loadCapture(id: id)
                    let document = try await library.loadAnnotations(for: id)
                    try await exporter.copy(
                        capture: capture,
                        document: document
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
                    try await flushAnnotations()
                    let capture = try await library.loadCapture(id: id)
                    let document = try await library.loadAnnotations(for: id)
                    try await exporter.save(
                        capture: capture,
                        document: document,
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
                reloadLibrary()
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
                reloadLibrary()
            } catch {
                present(error, title: "Tag Update Failed")
            }
        }
    }

    func search(_ query: String) {
        searchText = query
        libraryQueryGeneration &+= 1
        let token = libraryQueryGeneration
        Task { [weak self] in
            guard let self else { return }
            let result = await library.search(query)
            guard libraryQueryGeneration == token, searchText == query else { return }
            records = result
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

    func flushPendingAnnotations() async throws {
        annotationEditor.resolvePendingText()
        try await flushAnnotations()
    }

    func dismissPresentedError() {
        presentedError = nil
    }

    func performPresentedErrorRecovery() {
        guard let recovery = presentedError?.recovery else {
            dismissPresentedError()
            return
        }
        dismissPresentedError()
        switch recovery {
        case .recordWithoutMicrophone:
            guard let request = microphoneFallbackRequest else { return }
            microphoneFallbackRequest = nil
            startRecordingWithoutPicker(request)
        case .openScreenRecordingSettings, .openAccessibilitySettings:
            recoveryAction(recovery)
        }
    }

    func explainCloudUploadUnavailable() {
        presentedError = PresentedError(
            title: "Cloud Upload",
            message: "Cloud upload is coming later. Captures remain local on this Mac.",
            recovery: nil
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
            recovery: recovery(for: error)
        )
    }

    private func reloadLibrary() {
        libraryQueryGeneration &+= 1
        let token = libraryQueryGeneration
        let query = searchText
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await library.load(matching: query)
                let issues = await library.loadIssues()
                guard libraryQueryGeneration == token, searchText == query else { return }
                records = result
                if !issues.isEmpty {
                    let count = issues.count
                    presentedError = PresentedError(
                        title: "Library Warning",
                        message: "\(count) damaged library \(count == 1 ? "entry was" : "entries were") skipped. Other captures remain available.",
                        recovery: nil
                    )
                }
            } catch {
                guard libraryQueryGeneration == token else { return }
                present(error, title: "Library Failed")
            }
        }
    }

    private func beginRecordingStateObservation(token: UInt64) {
        recordingMonitor?.cancel()
        recordingMonitor = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let state = await recording.state
                guard recordingGeneration == token, !Task.isCancelled else { return }
                if state.kind == .completed { return }
                recordingState = state
                if state.kind == .failed {
                    presentedError = PresentedError(
                        title: "Recording Failed",
                        message: state.failureMessage ?? "The recording failed.",
                        recovery: nil
                    )
                    return
                }
                if state.kind == .idle { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func queueAnnotationPersistence(_ document: AnnotationDocument) {
        guard activeCapture?.id == document.captureID else { return }
        let previous = annotationPersistenceTask
        let library = library
        let task = Task {
            _ = try? await previous?.value
            try await library.saveAnnotations(
                document,
                for: document.captureID,
                editedAt: .now
            )
        }
        annotationPersistenceTask = task
        Task { [weak self] in
            do {
                try await task.value
            } catch {
                self?.present(error, title: "Annotation Save Failed")
            }
        }
    }

    private func flushAnnotations() async throws {
        try await annotationPersistenceTask?.value
    }

    private func switchToCapture(
        _ capture: CapturedImage,
        document: AnnotationDocument
    ) {
        captureSwitchGeneration &+= 1
        let token = captureSwitchGeneration
        let previousSwitch = captureSwitchTask
        captureSwitchTask = Task { [weak self] in
            guard let self else { return }
            await previousSwitch?.value
            do {
                try await flushAnnotations()
            } catch {
                present(error, title: "Annotation Save Failed")
                return
            }
            guard captureSwitchGeneration == token else { return }
            install(capture: capture, document: document)
            reloadLibrary()
        }
    }

    private func install(capture: CapturedImage, document: AnnotationDocument) {
        isInstallingAnnotationDocument = true
        activeCapture = capture
        annotationEditor.load(capture, document: document)
        annotationHistory = document
        isInstallingAnnotationDocument = false
    }

    private func validateRecordingOperation(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard recordingGeneration == token else { throw CancellationError() }
    }

    private func finishRecordingTask(token: UInt64) {
        guard recordingGeneration == token else { return }
        recordingTask = nil
    }

    private func handleRecordingStartFailure(
        _ error: Error,
        request: RecordingRequest?,
        token: UInt64
    ) async {
        await recording.cancel()
        guard recordingGeneration == token, !Task.isCancelled else { return }
        let failedRequest = request
        if error as? RecordingError == .microphonePermissionDenied,
           let failedRequest {
            microphoneFallbackRequest = RecordingRequest(
                target: failedRequest.target,
                format: failedRequest.format,
                includesSystemAudio: failedRequest.includesSystemAudio,
                includesMicrophone: false,
                framesPerSecond: failedRequest.framesPerSecond
            )
            recordingState = .failed(error.localizedDescription)
            presentedError = PresentedError(
                title: "Microphone Access Denied",
                message: error.localizedDescription,
                recovery: .recordWithoutMicrophone
            )
        } else {
            recordingState = .failed(error.localizedDescription)
            present(error, title: "Recording Failed")
        }
        finishRecordingTask(token: token)
    }

    private func recovery(for error: Error) -> PresentedErrorRecovery? {
        if error as? CaptureError == .permissionDenied
            || error as? RecordingError == .screenRecordingPermissionDenied {
            return .openScreenRecordingSettings
        }
        if error as? ScrollingCaptureError == .accessibilityDenied {
            return .openAccessibilitySettings
        }
        return nil
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
