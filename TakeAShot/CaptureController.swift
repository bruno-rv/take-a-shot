#if os(macOS)
import AppKit
import Carbon
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
        options: CaptureOptions
    ) async throws {
        let image = try await capturer.captureArea(rect, display: display, options: options)
        try await persistAndPublish(image)
    }

    func captureDisplay(
        _ displayID: CGDirectDisplayID,
        options: CaptureOptions
    ) async throws {
        let image = try await capturer.captureDisplay(displayID, options: options)
        try await persistAndPublish(image)
    }

    func captureWindow(
        _ windowID: CGWindowID,
        options: CaptureOptions
    ) async throws {
        let image = try await capturer.captureWindow(windowID, options: options)
        try await persistAndPublish(image)
    }

    func persistAndPublish(_ image: CapturedImage) async throws {
        try await persistence.persistCapture(image)
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

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, _, _ in
            Task { @MainActor in
                ScreenCaptureController.shared.scheduleCapture(
                    mode: .area,
                    options: CaptureOptions()
                )
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
    static let shared: ScreenCaptureController = {
        let capturer = ScreenCaptureEngine()
        return ScreenCaptureController(
            capturer: capturer,
            persistence: CaptureLibraryStore(
                rootURL: defaultLibraryURL,
                ocr: VisionOCRService()
            ),
            publisher: AppCapturePublisher()
        )
    }()

    private let capturer: any ScreenshotCapturing
    private let pipeline: CapturePipeline
    private let scrollingEngine: ScrollingCaptureEngine
    private var overlayWindows: [SelectionOverlayWindow] = []
    private var scrollingCaptureTask: Task<Void, Never>?
    private lazy var scheduler = CaptureIntentScheduler(handler: self)

    init(
        capturer: any ScreenshotCapturing,
        persistence: any CapturePersisting,
        publisher: any CapturePublishing,
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
    }

    func scheduleCapture(mode: CaptureMode, options: CaptureOptions) {
        scheduler.schedule(CaptureIntent(mode: mode), options: options)
    }

    func beginAreaSelection(options: CaptureOptions) {
        guard ensureScreenCaptureAccess() else { return }

        let screens = NSScreen.screens.compactMap { screen -> (NSScreen, DisplayGeometry)? in
            guard let display = displayGeometry(for: screen) else { return nil }
            return (screen, display)
        }
        guard !screens.isEmpty else { return }

        dismissOverlays()
        overlayWindows = screens.map { screen, display in
            SelectionOverlayWindow(
                screen: screen,
                display: display,
                onSelection: { [weak self] selection in
                    self?.completeAreaSelection(selection, options: options)
                },
                onCancel: { [weak self] in
                    self?.dismissOverlays()
                },
                onFullScreen: { [weak self] displayID in
                    self?.completeDisplayCapture(displayID, options: options)
                }
            )
        }
        overlayWindows.forEach { $0.orderFrontRegardless() }
        overlayWindows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func beginWindowPicker(options: CaptureOptions) {
        guard ensureScreenCaptureAccess() else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let sources = try await capturer.sources()
                showWindowPicker(sources.windows, options: options)
            } catch {
                presentCaptureError(error)
            }
        }
    }

    func beginDisplayCapture(options: CaptureOptions) {
        guard ensureScreenCaptureAccess() else { return }
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
            let display = displayGeometry(for: screen)
        else {
            presentCaptureError(CaptureError.sourceUnavailable)
            return
        }
        completeDisplayCapture(display.id, options: options)
    }

    func beginScrollingWindowPicker(options: CaptureOptions) {
        guard scrollingCaptureTask == nil else { return }
        guard ensureScreenCaptureAccess() else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let sources = try await capturer.sources()
                showScrollingWindowPicker(sources.windows, options: options)
            } catch {
                presentCaptureError(error)
            }
        }
    }

    func beginRecordingPicker(options: CaptureOptions) {}

    func cancelScrollingCapture() {
        scrollingCaptureTask?.cancel()
    }

    func copyCurrentCapture() {
        guard let image = AppState.shared.capturedImage else { return }
        copy(image)
    }

    func saveCurrentCapture() {
        guard let image = AppState.shared.capturedImage else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "TakeAShot-\(Self.timestamp()).png"

        if panel.runModal() == .OK, let url = panel.url {
            save(image, to: url)
        }
    }

    private func copy(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func save(_ image: NSImage, to url: URL) {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return
        }

        try? pngData.write(to: url)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: Date())
    }

    private func ensureScreenCaptureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return granted
    }

    private func completeAreaSelection(
        _ selection: AreaSelection,
        options: CaptureOptions
    ) {
        dismissOverlays()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.captureArea(
                    selection.rect,
                    display: selection.display,
                    options: options
                )
            } catch {
                presentCaptureError(error)
            }
        }
    }

    private func completeDisplayCapture(
        _ displayID: CGDirectDisplayID,
        options: CaptureOptions
    ) {
        dismissOverlays()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.captureDisplay(displayID, options: options)
            } catch {
                presentCaptureError(error)
            }
        }
    }

    private func completeWindowCapture(
        _ windowID: CGWindowID,
        options: CaptureOptions
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.captureWindow(windowID, options: options)
            } catch {
                presentCaptureError(error)
            }
        }
    }

    private func completeScrollingCapture(
        target: ScrollingWindowTarget,
        options: CaptureOptions
    ) {
        guard scrollingCaptureTask == nil else { return }
        AppState.shared.beginScrollingCapture()

        scrollingCaptureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                scrollingCaptureTask = nil
                AppState.shared.endScrollingCapture()
            }

            do {
                try await Task.sleep(for: .milliseconds(250))
                let captureResult = try await scrollingEngine.capture(
                    target: target,
                    options: options,
                    progress: { progress in
                        await MainActor.run {
                            AppState.shared.updateScrollingCapture(progress)
                        }
                    }
                )
                switch captureResult {
                case .completed(let capture):
                    try await pipeline.persistAndPublish(capture)
                case .partial(let capture, let reason):
                    if confirmUsingPartialCapture(capture, reason: reason) {
                        try await pipeline.persistAndPublish(capture)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                presentCaptureError(error)
            }
        }
    }

    private func showWindowPicker(
        _ sources: [CaptureSource],
        options: CaptureOptions
    ) {
        let windows = sources.compactMap { source -> (CaptureSource, CGWindowID)? in
            guard case .window(let windowID, _) = source.kind else { return nil }
            return (source, windowID)
        }
        guard !windows.isEmpty else {
            presentCaptureError(CaptureError.sourceUnavailable)
            return
        }

        let picker = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 360, height: 28))
        picker.addItems(withTitles: windows.map { $0.0.title })
        let alert = NSAlert()
        alert.messageText = "Choose a window"
        alert.informativeText = "Select the window to capture."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Capture")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        completeWindowCapture(windows[picker.indexOfSelectedItem].1, options: options)
    }

    private func showScrollingWindowPicker(
        _ sources: [CaptureSource],
        options: CaptureOptions
    ) {
        let windows = sources.compactMap { source -> (CaptureSource, CGWindowID, CGRect)? in
            guard case .window(let windowID, let frame) = source.kind else { return nil }
            return (source, windowID, frame)
        }
        guard !windows.isEmpty else {
            presentCaptureError(CaptureError.sourceUnavailable)
            return
        }

        let picker = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 360, height: 28))
        picker.addItems(withTitles: windows.map { $0.0.title })
        let alert = NSAlert()
        alert.messageText = "Choose a scrollable window"
        alert.informativeText = "Take a Shot will bring the window forward and scroll it automatically."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Start Scrolling Capture")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let selected = windows[picker.indexOfSelectedItem]
        completeScrollingCapture(
            target: ScrollingWindowTarget(
                windowID: selected.1,
                title: selected.0.title,
                frame: selected.2
            ),
            options: options
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
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    private static var defaultLibraryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return applicationSupport.appendingPathComponent("TakeAShot", isDirectory: true)
    }
}

@MainActor
private final class AppCapturePublisher: CapturePublishing {
    private let thumbnailController = FloatingThumbnailController()

    func publish(_ capture: CapturedImage) {
        AppState.shared.setCapturedImage(capture)
        if let image = AppState.shared.capturedImage {
            thumbnailController.show(image: image)
        }
    }
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

@MainActor
final class FloatingThumbnailController {
    private var panel: NSPanel?

    func show(image: NSImage) {
        let thumbnailView = FloatingThumbnailView(
            image: image,
            onCopy: {
                ScreenCaptureController.shared.copyCurrentCapture()
            },
            onSave: {
                ScreenCaptureController.shared.saveCurrentCapture()
            },
            onEdit: {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { !$0.isKind(of: NSPanel.self) }?.makeKeyAndOrderFront(nil)
            },
            onClose: { [weak self] in
                self?.panel?.orderOut(nil)
            }
        )

        let hostingView = NSHostingView(rootView: thumbnailView)
        let size = CGSize(width: 320, height: 320)
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let origin = CGPoint(x: screenFrame.minX + 18, y: screenFrame.midY - size.height / 2)

        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.orderFrontRegardless()

        self.panel = panel
    }
}

struct FloatingThumbnailView: View {
    let image: NSImage
    let onCopy: () -> Void
    let onSave: () -> Void
    let onEdit: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 272, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 14, y: 8)

            ZStack {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.56),
                        Color(red: 0.9, green: 0.67, blue: 0.04).opacity(0.72)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 12) {
                    Button(action: onCopy) {
                        Text("Copy")
                            .font(.title3.weight(.semibold))
                            .frame(width: 104, height: 48)
                    }
                    .buttonStyle(FloatingPillButtonStyle())

                    Button(action: onSave) {
                        Text("Save")
                            .font(.title3.weight(.semibold))
                            .frame(width: 104, height: 48)
                    }
                    .buttonStyle(FloatingPillButtonStyle())
                }

                VStack {
                    HStack {
                        thumbnailIcon("pin.fill", action: {})
                            .help("Pin")
                        Spacer()
                        thumbnailIcon("xmark", action: onClose)
                            .help("Close")
                    }
                    Spacer()
                    HStack {
                        thumbnailIcon("pencil.tip", action: onEdit)
                            .help("Edit")
                        Spacer()
                        thumbnailIcon("icloud.and.arrow.up", action: {})
                            .help("Upload")
                    }
                }
                .padding(12)
            }
            .frame(width: 272, height: 148)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 18, y: 10)
        }
        .padding(18)
        .background(Color.clear)
    }

    private func thumbnailIcon(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.86))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct FloatingPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black.opacity(0.86))
            .background(.white.opacity(configuration.isPressed ? 0.72 : 0.88))
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private extension String {
    var fourCharCode: OSType {
        utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
#endif
