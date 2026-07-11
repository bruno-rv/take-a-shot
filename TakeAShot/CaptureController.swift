#if os(macOS)
import AppKit
import AVFoundation
import Carbon
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
protocol CaptureIntentHandling: AnyObject {
    func beginAreaSelection(options: CaptureOptions)
    func beginWindowPicker(options: CaptureOptions)
    func beginDisplayCapture(options: CaptureOptions)
    func beginScrollingWindowPicker(options: CaptureOptions)
    func beginRecordingPicker(options: CaptureOptions)
}

@MainActor
enum CaptureCoordinator {
    static func dispatch(
        _ intent: CaptureIntent,
        options: CaptureOptions,
        to handler: any CaptureIntentHandling
    ) {
        switch intent {
        case .areaSelection:
            handler.beginAreaSelection(options: options)
        case .windowPicker:
            handler.beginWindowPicker(options: options)
        case .display:
            handler.beginDisplayCapture(options: options)
        case .scrollingWindowPicker:
            handler.beginScrollingWindowPicker(options: options)
        case .recordingPicker:
            handler.beginRecordingPicker(options: options)
        }
    }
}

@MainActor
final class CaptureIntentScheduler {
    private weak var handler: (any CaptureIntentHandling)?
    private var captureTask: Task<Void, Never>?

    init(handler: any CaptureIntentHandling) {
        self.handler = handler
    }

    deinit {
        captureTask?.cancel()
    }

    func schedule(_ intent: CaptureIntent, options: CaptureOptions) {
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            do {
                if options.delay != .zero {
                    try await Task.sleep(for: options.delay)
                }
                try Task.checkCancellation()
                guard let self, let handler = self.handler else { return }
                CaptureCoordinator.dispatch(intent, options: options, to: handler)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func cancel() {
        captureTask?.cancel()
        captureTask = nil
    }
}

@MainActor
final class CaptureOperationScope {
    enum Kind: Equatable {
        case areaSelection
        case windowDiscovery
        case displayCapture
        case scrollingDiscovery
        case recordingDiscovery
    }

    struct Token: Equatable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var activeKind: Kind?
    private var cancelActiveTask: (() -> Void)?

    func begin(_ kind: Kind) -> Token? {
        if kind == .scrollingDiscovery, activeKind == .scrollingDiscovery {
            return nil
        }
        invalidate()
        activeKind = kind
        return Token(generation: generation)
    }

    func retain<Success, Failure>(
        _ task: Task<Success, Failure>,
        for token: Token
    ) where Failure: Error {
        guard isCurrent(token) else {
            task.cancel()
            return
        }
        cancelActiveTask = { task.cancel() }
    }

    func isCurrent(_ token: Token) -> Bool {
        token.generation == generation && activeKind != nil
    }

    func isActive(_ kind: Kind) -> Bool {
        activeKind == kind
    }

    func finish(_ token: Token) {
        guard isCurrent(token) else { return }
        activeKind = nil
        cancelActiveTask = nil
    }

    func cancel() {
        invalidate()
    }

    private func invalidate() {
        cancelActiveTask?()
        cancelActiveTask = nil
        activeKind = nil
        generation &+= 1
    }
}

protocol CapturePersisting: Sendable {
    func persistCapture(_ image: CapturedImage) async throws
}

extension CaptureLibraryStore: CapturePersisting {
    func persistCapture(_ image: CapturedImage) async throws {
        _ = try await persist(image: image)
    }
}

@MainActor
protocol CapturePublishing: AnyObject {
    func publish(_ image: CapturedImage)
}

@MainActor
protocol CaptureOperationReporting: AnyObject {
    func scrollingCaptureChanged(isActive: Bool)
    func scrollingCaptureProgressed(_ progress: ScrollingCaptureProgress)
    func captureFailed(_ error: Error)
}

@MainActor
final class CapturePipeline {
    private let capturer: any ScreenshotCapturing
    private let persistence: any CapturePersisting
    private let publisher: any CapturePublishing

    init(
        capturer: any ScreenshotCapturing,
        persistence: any CapturePersisting,
        publisher: any CapturePublishing
    ) {
        self.capturer = capturer
        self.persistence = persistence
        self.publisher = publisher
    }

    func captureArea(
        _ rect: CGRect,
        display: DisplayGeometry,
        options: CaptureOptions,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async throws {
        let image = try await capturer.captureArea(rect, display: display, options: options)
        try await persistAndPublish(image, isCurrent: isCurrent)
    }

    func captureDisplay(
        _ displayID: CGDirectDisplayID,
        options: CaptureOptions,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async throws {
        let image = try await capturer.captureDisplay(displayID, options: options)
        try await persistAndPublish(image, isCurrent: isCurrent)
    }

    func captureWindow(
        _ windowID: CGWindowID,
        options: CaptureOptions,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async throws {
        let image = try await capturer.captureWindow(windowID, options: options)
        try await persistAndPublish(image, isCurrent: isCurrent)
    }

    func persistAndPublish(
        _ image: CapturedImage,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async throws {
        guard isCurrent() else { throw CancellationError() }
        try await persistence.persistCapture(image)
        guard isCurrent() else { throw CancellationError() }
        publisher.publish(image)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyController.shared.register()
    }
}

final class HotKeyController {
    static let shared = HotKeyController()
    var captureAction: (@MainActor () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, _, _ in
            Task { @MainActor in
                HotKeyController.shared.captureAction?()
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: "TAS1".fourCharCode, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_5),
            UInt32(shiftKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

@MainActor
final class ScreenCaptureController: CaptureIntentHandling {
    private let capturer: any ScreenshotCapturing
    private let pipeline: CapturePipeline
    private let scrollingEngine: ScrollingCaptureEngine
    private weak var reporter: (any CaptureOperationReporting)?
    private var overlayWindows: [SelectionOverlayWindow] = []
    private let operationScope = CaptureOperationScope()
    private lazy var scheduler = CaptureIntentScheduler(handler: self)

    init(
        capturer: any ScreenshotCapturing,
        persistence: any CapturePersisting,
        publisher: any CapturePublishing,
        reporter: (any CaptureOperationReporting)? = nil,
        windowScroller: any WindowScrolling = AccessibilityWindowScroller()
    ) {
        self.capturer = capturer
        scrollingEngine = ScrollingCaptureEngine(
            capturer: capturer,
            scroller: windowScroller
        )
        pipeline = CapturePipeline(
            capturer: capturer,
            persistence: persistence,
            publisher: publisher
        )
        self.reporter = reporter
    }

    func scheduleCapture(mode: CaptureMode, options: CaptureOptions) {
        if mode == .scrolling, operationScope.isActive(.scrollingDiscovery) {
            return
        }
        operationScope.cancel()
        dismissOverlays()
        scheduler.schedule(CaptureIntent(mode: mode), options: options)
    }

    func beginAreaSelection(options: CaptureOptions) {
        guard let token = operationScope.begin(.areaSelection) else { return }
        guard ensureScreenCaptureAccess() else {
            operationScope.finish(token)
            return
        }

        let screens = NSScreen.screens.compactMap { screen -> (NSScreen, DisplayGeometry)? in
            guard let display = displayGeometry(for: screen) else { return nil }
            return (screen, display)
        }
        guard !screens.isEmpty else {
            operationScope.finish(token)
            return
        }

        dismissOverlays()
        overlayWindows = screens.map { screen, display in
            SelectionOverlayWindow(
                screen: screen,
                display: display,
                onSelection: { [weak self] selection in
                    guard let self, self.operationScope.isCurrent(token) else { return }
                    self.completeAreaSelection(selection, options: options, token: token)
                },
                onCancel: { [weak self] in
                    guard let self, self.operationScope.isCurrent(token) else { return }
                    self.cancelCurrentOperation()
                },
                onFullScreen: { [weak self] displayID in
                    guard let self, self.operationScope.isCurrent(token) else { return }
                    self.completeDisplayCapture(displayID, options: options, token: token)
                }
            )
        }
        overlayWindows.forEach { $0.orderFrontRegardless() }
        overlayWindows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func beginWindowPicker(options: CaptureOptions) {
        guard let token = operationScope.begin(.windowDiscovery) else { return }
        guard ensureScreenCaptureAccess() else {
            operationScope.finish(token)
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            defer { operationScope.finish(token) }
            do {
                let sources = try await capturer.sources()
                try Task.checkCancellation()
                guard operationScope.isCurrent(token),
                      let windowID = showWindowPicker(sources.windows)
                else { return }
                try await pipeline.captureWindow(
                    windowID,
                    options: options,
                    isCurrent: { [weak self] in
                        self?.operationScope.isCurrent(token) == true
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                if operationScope.isCurrent(token) { presentCaptureError(error) }
            }
        }
        operationScope.retain(task, for: token)
    }

    func beginDisplayCapture(options: CaptureOptions) {
        guard let token = operationScope.begin(.displayCapture) else { return }
        guard ensureScreenCaptureAccess() else {
            operationScope.finish(token)
            return
        }
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
            let display = displayGeometry(for: screen)
        else {
            presentCaptureError(CaptureError.sourceUnavailable)
            operationScope.finish(token)
            return
        }
        completeDisplayCapture(display.id, options: options, token: token)
    }

    func beginScrollingWindowPicker(options: CaptureOptions) {
        guard let token = operationScope.begin(.scrollingDiscovery) else { return }
        guard ensureScreenCaptureAccess() else {
            operationScope.finish(token)
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            var reportedActive = false
            defer {
                if reportedActive { reporter?.scrollingCaptureChanged(isActive: false) }
                operationScope.finish(token)
            }
            do {
                let sources = try await capturer.sources()
                try Task.checkCancellation()
                guard operationScope.isCurrent(token),
                      let target = showScrollingWindowPicker(sources.windows)
                else { return }
                reporter?.scrollingCaptureChanged(isActive: true)
                reportedActive = true
                try await Task.sleep(for: .milliseconds(250))
                let captureResult = try await scrollingEngine.capture(
                    target: target,
                    options: options,
                    progress: { progress in
                        await MainActor.run {
                            guard self.operationScope.isCurrent(token) else { return }
                            self.reporter?.scrollingCaptureProgressed(progress)
                        }
                    }
                )
                try Task.checkCancellation()
                guard operationScope.isCurrent(token) else { return }
                switch captureResult {
                case .completed(let capture):
                    try await pipeline.persistAndPublish(
                        capture,
                        isCurrent: { [weak self] in
                            self?.operationScope.isCurrent(token) == true
                        }
                    )
                case .partial(let capture, let reason):
                    guard confirmUsingPartialCapture(capture, reason: reason),
                          operationScope.isCurrent(token)
                    else { return }
                    try await pipeline.persistAndPublish(
                        capture,
                        isCurrent: { [weak self] in
                            self?.operationScope.isCurrent(token) == true
                        }
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                if operationScope.isCurrent(token) { presentCaptureError(error) }
            }
        }
        operationScope.retain(task, for: token)
    }

    func beginRecordingPicker(options: CaptureOptions) {
        reporter?.captureFailed(CaptureError.captureFailed(
            "Choose MP4 or GIF from the recording controls."
        ))
    }

    func cancelScrollingCapture() {
        operationScope.cancel()
    }

    func cancelCurrentOperation() {
        scheduler.cancel()
        operationScope.cancel()
        dismissOverlays()
    }

    func chooseRecordingTarget() async throws -> RecordingTarget? {
        guard let token = operationScope.begin(.recordingDiscovery) else { return nil }
        defer { operationScope.finish(token) }
        guard ensureScreenCaptureAccess(reportsFailure: false) else {
            throw RecordingError.screenRecordingPermissionDenied
        }
        let discovery = Task { try await capturer.sources() }
        operationScope.retain(discovery, for: token)
        let sources = try await discovery.value
        try Task.checkCancellation()
        guard operationScope.isCurrent(token) else { return nil }
        let targets: [(String, RecordingTarget)] = sources.displays.compactMap { source in
            guard case .display(let display) = source.kind else { return nil }
            return (source.title, .display(display.id))
        } + sources.windows.compactMap { source in
            guard case .window(let windowID, _) = source.kind else { return nil }
            return (source.title, .window(windowID))
        }
        guard !targets.isEmpty else { throw RecordingError.sourceUnavailable }

        let picker = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 380, height: 28))
        picker.setAccessibilityLabel("Choose a recording source")
        picker.addItems(withTitles: targets.map(\.0))
        let alert = NSAlert()
        alert.messageText = "Choose a recording source"
        alert.informativeText = "Select a display or window to record."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard operationScope.isCurrent(token) else { return nil }
        return targets[picker.indexOfSelectedItem].1
    }

    private func ensureScreenCaptureAccess(reportsFailure: Bool = true) -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        let granted = CGRequestScreenCaptureAccess()
        if !granted, reportsFailure {
            reporter?.captureFailed(CaptureError.permissionDenied)
        }
        return granted
    }

    private func completeAreaSelection(
        _ selection: AreaSelection,
        options: CaptureOptions,
        token: CaptureOperationScope.Token
    ) {
        dismissOverlays()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { operationScope.finish(token) }
            do {
                try await pipeline.captureArea(
                    selection.rect,
                    display: selection.display,
                    options: options,
                    isCurrent: { [weak self] in
                        self?.operationScope.isCurrent(token) == true
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                if operationScope.isCurrent(token) { presentCaptureError(error) }
            }
        }
        operationScope.retain(task, for: token)
    }

    private func completeDisplayCapture(
        _ displayID: CGDirectDisplayID,
        options: CaptureOptions,
        token: CaptureOperationScope.Token
    ) {
        dismissOverlays()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { operationScope.finish(token) }
            do {
                try await pipeline.captureDisplay(
                    displayID,
                    options: options,
                    isCurrent: { [weak self] in
                        self?.operationScope.isCurrent(token) == true
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                if operationScope.isCurrent(token) { presentCaptureError(error) }
            }
        }
        operationScope.retain(task, for: token)
    }

    private func showWindowPicker(
        _ sources: [CaptureSource]
    ) -> CGWindowID? {
        let windows = sources.compactMap { source -> (CaptureSource, CGWindowID)? in
            guard case .window(let windowID, _) = source.kind else { return nil }
            return (source, windowID)
        }
        guard !windows.isEmpty else {
            presentCaptureError(CaptureError.sourceUnavailable)
            return nil
        }

        let picker = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 360, height: 28))
        picker.setAccessibilityLabel("Choose a window to capture")
        picker.addItems(withTitles: windows.map { $0.0.title })
        let alert = NSAlert()
        alert.messageText = "Choose a window"
        alert.informativeText = "Select the window to capture."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Capture")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return windows[picker.indexOfSelectedItem].1
    }

    private func showScrollingWindowPicker(
        _ sources: [CaptureSource]
    ) -> ScrollingWindowTarget? {
        let windows = sources.compactMap { source -> (CaptureSource, CGWindowID, CGRect)? in
            guard case .window(let windowID, let frame) = source.kind else { return nil }
            return (source, windowID, frame)
        }
        guard !windows.isEmpty else {
            presentCaptureError(CaptureError.sourceUnavailable)
            return nil
        }

        let picker = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 360, height: 28))
        picker.setAccessibilityLabel("Choose a scrolling capture window")
        picker.addItems(withTitles: windows.map { $0.0.title })
        let alert = NSAlert()
        alert.messageText = "Choose a scrollable window"
        alert.informativeText = "Take a Shot will bring the window forward and scroll it automatically."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Start Scrolling Capture")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let selected = windows[picker.indexOfSelectedItem]
        return ScrollingWindowTarget(
            windowID: selected.1,
            title: selected.0.title,
            frame: selected.2
        )
    }

    private func confirmUsingPartialCapture(
        _ capture: CapturedImage,
        reason: ScrollingCaptureError
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Scrolling capture stopped early"
        alert.informativeText = "\(reason.localizedDescription) A \(capture.pixelSize.height)-pixel partial image is available."
        alert.addButton(withTitle: "Use Partial")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func dismissOverlays() {
        let windows = overlayWindows
        overlayWindows.removeAll()
        windows.forEach { $0.orderOut(nil) }
    }

    private func displayGeometry(for screen: NSScreen) -> DisplayGeometry? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return DisplayGeometry(
            id: CGDirectDisplayID(number.uint32Value),
            frame: screen.frame,
            scale: screen.backingScaleFactor
        )
    }

    private func presentCaptureError(_ error: Error) {
        reporter?.captureFailed(error)
    }
}

@MainActor
final class AppCapturePublisher: CapturePublishing, CaptureOperationReporting {
    var onCapture: ((CapturedImage) -> Void)?
    var onProgress: ((ScrollingCaptureProgress) -> Void)?
    var onScrollingChanged: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    func publish(_ capture: CapturedImage) {
        onCapture?(capture)
    }

    func scrollingCaptureChanged(isActive: Bool) {
        onScrollingChanged?(isActive)
    }

    func scrollingCaptureProgressed(_ progress: ScrollingCaptureProgress) {
        onProgress?(progress)
    }

    func captureFailed(_ error: Error) {
        onError?(error)
    }
}

struct LiveAppCaptureExporter: AppCaptureExporting {
    private let renderService = DetachedAnnotationRenderService()

    func copy(capture: CapturedImage, document: AnnotationDocument) async throws {
        let rendered = try await renderService.render(capture: capture, document: document)
        await MainActor.run {
            let image = NSImage(
                cgImage: rendered,
                size: CGSize(width: rendered.width, height: rendered.height)
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    func save(
        capture: CapturedImage,
        document: AnnotationDocument,
        format: ExportFormat
    ) async throws {
        guard let destination = await chooseDestination(
            suggestedName: "TakeAShot-\(capture.id.uuidString).\(format.fileExtension)",
            contentType: format.contentType
        ) else { return }
        let rendered = try await renderService.render(capture: capture, document: document)
        try await Task.detached(priority: .userInitiated) {
            let data: Data
            switch format {
            case .png:
                data = try ImageExporter.pngData(for: rendered)
            case .jpeg:
                data = try ImageExporter.jpegData(for: rendered, quality: 0.9)
            }
            try ImageExporter.write(data, to: destination)
        }.value
    }

    func inspectRecording(
        at url: URL,
        format: RecordingFormat,
        createdAt: Date
    ) async throws -> RecordedMedia {
        try await Task.detached(priority: .utility) {
            let identifier = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            switch format {
            case .mp4:
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw RecordingError.recordingFailed("The completed video has no video track.")
                }
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let transformed = size.applying(transform)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                let thumbnail = try generator.copyCGImage(at: .zero, actualTime: nil)
                return RecordedMedia(
                    id: identifier,
                    kind: .video,
                    title: url.lastPathComponent,
                    createdAt: createdAt,
                    pixelSize: PixelSize(
                        width: Int(abs(transformed.width).rounded()),
                        height: Int(abs(transformed.height).rounded())
                    ),
                    duration: duration.seconds,
                    originalURL: url,
                    thumbnail: thumbnail
                )
            case .gif:
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else {
                    throw RecordingError.gifEncodingFailed("The completed GIF could not be read.")
                }
                let frameCount = CGImageSourceGetCount(source)
                var duration: Double = 0
                for index in 0..<frameCount {
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                        as? [CFString: Any]
                    let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    duration += gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                        ?? gif?[kCGImagePropertyGIFDelayTime] as? Double
                        ?? 0.1
                }
                return RecordedMedia(
                    id: identifier,
                    kind: .gif,
                    title: url.lastPathComponent,
                    createdAt: createdAt,
                    pixelSize: PixelSize(width: thumbnail.width, height: thumbnail.height),
                    duration: duration,
                    originalURL: url,
                    thumbnail: thumbnail
                )
            }
        }.value
    }

    func copyFile(at url: URL) async throws {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        }
    }

    func saveFile(at url: URL) async throws {
        guard let destination = await chooseDestination(
            suggestedName: url.lastPathComponent,
            contentType: url.pathExtension.lowercased() == "gif" ? .gif : .mpeg4Movie
        ) else { return }
        try await Task.detached(priority: .userInitiated) {
            try AtomicMediaFileCopy.copyReplacing(source: url, destination: destination)
        }.value
    }

    func discardFile(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }.value
    }

    @MainActor
    private func chooseDestination(
        suggestedName: String,
        contentType: UTType
    ) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum AtomicMediaFileCopy {
    static func copyReplacing(source: URL, destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        var renameError: Int32 = 0
        let result = temporary.withUnsafeFileSystemRepresentation { temporaryPath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let temporaryPath, let destinationPath else {
                    renameError = EINVAL
                    return Int32(-1)
                }
                let result = Darwin.rename(temporaryPath, destinationPath)
                if result != 0 { renameError = errno }
                return result
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: renameError) ?? .EIO)
        }
    }
}

private extension ExportFormat {
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var contentType: UTType { self == .png ? .png : .jpeg }
}

final class SelectionOverlayWindow: NSWindow {
    init(
        screen: NSScreen,
        display: DisplayGeometry,
        onSelection: @escaping (AreaSelection) -> Void,
        onCancel: @escaping () -> Void,
        onFullScreen: @escaping (CGDirectDisplayID) -> Void
    ) {
        let view = SelectionOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size)
        )
        view.onSelection = { localRect in
            onSelection(AreaSelection(localRect: localRect, display: display))
        }
        view.onCancel = onCancel
        view.onFullScreen = { onFullScreen(display.id) }

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.contentView = view
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true
        self.makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionOverlayView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onFullScreen: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let overlayPath = NSBezierPath(rect: bounds)

        if let selection = selectionRect {
            overlayPath.append(NSBezierPath(rect: selection))
            overlayPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.46).setFill()
            overlayPath.fill()

            let path = NSBezierPath(rect: selection)
            path.lineWidth = 2.5
            NSColor.systemBlue.setStroke()
            path.stroke()

            drawHandles(for: selection)
            drawSelectionBadge(for: selection)
            drawDoneBadge(for: selection)
        } else {
            NSColor.black.withAlphaComponent(0.46).setFill()
            bounds.fill()
        }

        drawInstructions()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        if let selection = selectionRect, selection.width > 8, selection.height > 8 {
            window?.orderOut(nil)
            onSelection?(selection)
        } else {
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            window?.orderOut(nil)
            onCancel?()
        case 36:
            window?.orderOut(nil)
            onFullScreen?()
        default:
            super.keyDown(with: event)
        }
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        )
    }

    private func drawInstructions() {
        let message = "Drag to capture a slice   |   Return: whole screen   |   Esc: cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = message.size(withAttributes: attributes)
        let rect = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.maxY - 88,
            width: size.width,
            height: size.height
        )
        message.draw(in: rect, withAttributes: attributes)
    }

    private func drawHandles(for selection: CGRect) {
        let points = [
            CGPoint(x: selection.minX, y: selection.minY),
            CGPoint(x: selection.midX, y: selection.minY),
            CGPoint(x: selection.maxX, y: selection.minY),
            CGPoint(x: selection.minX, y: selection.midY),
            CGPoint(x: selection.maxX, y: selection.midY),
            CGPoint(x: selection.minX, y: selection.maxY),
            CGPoint(x: selection.midX, y: selection.maxY),
            CGPoint(x: selection.maxX, y: selection.maxY)
        ]

        NSColor.systemBlue.setFill()
        for point in points {
            NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }
    }

    private func drawSelectionBadge(for selection: CGRect) {
        let message = "\(Int(selection.width)) x \(Int(selection.height))"
        drawBadge(
            message,
            at: CGPoint(x: selection.midX, y: min(selection.maxY + 18, bounds.maxY - 36)),
            background: NSColor.black.withAlphaComponent(0.72),
            foreground: .white
        )
    }

    private func drawDoneBadge(for selection: CGRect) {
        drawBadge(
            "Release to capture",
            at: CGPoint(x: selection.midX, y: max(selection.minY - 28, bounds.minY + 28)),
            background: NSColor.systemBlue,
            foreground: .white
        )
    }

    private func drawBadge(
        _ message: String,
        at center: CGPoint,
        background: NSColor,
        foreground: NSColor
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: foreground
        ]
        let textSize = message.size(withAttributes: attributes)
        let rect = CGRect(
            x: center.x - (textSize.width + 24) / 2,
            y: center.y - (textSize.height + 10) / 2,
            width: textSize.width + 24,
            height: textSize.height + 10
        )

        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        message.draw(
            in: CGRect(x: rect.minX + 12, y: rect.minY + 5, width: textSize.width, height: textSize.height),
            withAttributes: attributes
        )
    }
}

private extension String {
    var fourCharCode: OSType {
        utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
#endif
