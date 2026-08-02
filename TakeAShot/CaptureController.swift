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
    func beginManualScrollCapture(options: CaptureOptions)
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
        case .scrollingAreaSelection:
            handler.beginManualScrollCapture(options: options)
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

    func schedule(
        _ intent: CaptureIntent,
        options: CaptureOptions,
        onCancellation: @escaping @MainActor () -> Void = {}
    ) {
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            var didDispatch = false
            defer {
                if !didDispatch { onCancellation() }
            }
            do {
                if options.delay != .zero {
                    try await Task.sleep(for: options.delay)
                }
                try Task.checkCancellation()
                guard let self, let handler = self.handler else { return }
                didDispatch = true
                CaptureCoordinator.dispatch(intent, options: options, to: handler)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func cancel() async {
        let task = captureTask
        captureTask = nil
        task?.cancel()
        await task?.value
    }
}

@MainActor
final class CaptureOperationCompletion {
    private var completion: AppCaptureCompletion?

    init(_ completion: AppCaptureCompletion?) {
        self.completion = completion
    }

    func finish() {
        let completion = completion
        self.completion = nil
        completion?()
    }
}

typealias CaptureCleanupRetry = @Sendable () async throws -> Void

struct CaptureCleanupRetryOperation: Sendable {
    let run: CaptureCleanupRetry
}

@MainActor
final class CaptureOperationScope {
    enum Kind: Equatable {
        case areaSelection
        case windowDiscovery
        case displayCapture
        case scrollingDiscovery
        case manualScrollCapture
        case recordingDiscovery
    }

    struct Token: Equatable {
        fileprivate let generation: UInt64
        fileprivate let completion: CaptureOperationCompletion?

        static func == (lhs: Token, rhs: Token) -> Bool {
            lhs.generation == rhs.generation
        }
    }

    private var generation: UInt64 = 0
    private var activeKind: Kind?
    private var activeToken: Token?
    private var cancelActiveTask: (() -> Void)?
    private var awaitActiveTask: (() async throws -> Void)?
    private var activeCleanupRetry: CaptureCleanupRetry?
    private var latchedToken: Token?
    private var latchedTaskWaiter: (() async throws -> Void)?
    private var latchedCleanupRetry: CaptureCleanupRetry?
    private var latchedCleanupError: Error?

    func begin(
        _ kind: Kind,
        completion: CaptureOperationCompletion? = nil
    ) -> Token? {
        guard !hasUnresolvedCleanup else { return nil }
        if kind == .scrollingDiscovery, activeKind == .scrollingDiscovery {
            return nil
        }
        if kind == .manualScrollCapture, activeKind == .manualScrollCapture {
            return nil
        }
        invalidate()
        guard !hasUnresolvedCleanup else { return nil }
        activeKind = kind
        let token = Token(generation: generation, completion: completion)
        activeToken = token
        return token
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
        awaitActiveTask = { _ = try await task.value }
    }

    func registerCleanupRetry(
        _ retry: CaptureCleanupRetryOperation,
        for token: Token
    ) {
        guard isCurrent(token) else { return }
        activeCleanupRetry = retry.run
    }

    func isCurrent(_ token: Token) -> Bool {
        token.generation == generation && activeKind != nil
    }

    func isActive(_ kind: Kind) -> Bool {
        activeKind == kind
    }

    func finish(_ token: Token) {
        guard latchedToken?.generation != token.generation else { return }
        token.completion?.finish()
        guard isCurrent(token) else { return }
        activeKind = nil
        activeToken = nil
        cancelActiveTask = nil
        awaitActiveTask = nil
        activeCleanupRetry = nil
    }

    func cancel() {
        invalidate()
    }

    func cancelAndWait() async throws {
        invalidate(awaitCleanup: true)
        try await resolveLatchedCleanup()
    }

    private func invalidate(awaitCleanup: Bool = false) {
        let activeToken = activeToken
        let hasRetainedTask = cancelActiveTask != nil
        let shouldLatchToken = activeCleanupRetry != nil || (hasRetainedTask && awaitCleanup)
        cancelActiveTask?()
        if hasRetainedTask, awaitCleanup || activeCleanupRetry != nil {
            latchedTaskWaiter = awaitActiveTask
        }
        if let activeCleanupRetry {
            latchedCleanupRetry = activeCleanupRetry
        }
        if shouldLatchToken {
            latchedToken = activeToken
        }
        cancelActiveTask = nil
        awaitActiveTask = nil
        activeCleanupRetry = nil
        activeKind = nil
        self.activeToken = nil
        generation &+= 1
        if !hasRetainedTask, !shouldLatchToken {
            activeToken?.completion?.finish()
        }
    }

    private var hasUnresolvedCleanup: Bool {
        latchedTaskWaiter != nil || latchedCleanupRetry != nil || latchedCleanupError != nil
    }

    private func resolveLatchedCleanup() async throws {
        if let latchedTaskWaiter {
            do {
                try await latchedTaskWaiter()
                completeCleanupLatch()
                return
            } catch {
                self.latchedTaskWaiter = nil
                guard latchedCleanupRetry != nil else {
                    completeCleanupLatch()
                    return
                }
                latchedCleanupError = error
                throw error
            }
        }
        if let latchedCleanupRetry {
            do {
                try await latchedCleanupRetry()
                completeCleanupLatch()
                return
            } catch {
                latchedCleanupError = error
                throw error
            }
        }
        if let latchedCleanupError {
            throw latchedCleanupError
        }
    }

    private func completeCleanupLatch() {
        let completion = latchedToken?.completion
        latchedToken = nil
        latchedTaskWaiter = nil
        latchedCleanupRetry = nil
        latchedCleanupError = nil
        completion?.finish()
    }
}

struct CapturePersistenceOutcome: Equatable, Sendable {
    let recordID: UUID
}

protocol CapturePersisting: Sendable {
    func persistCapture(_ image: CapturedImage) async throws
    /// Default implementation (below) ignores `annotations`/`renderedImage` and defers to
    /// `persistCapture(_:)` — only `CaptureLibraryStore` needs its own implementation.
    func persistCapture(
        _ image: CapturedImage,
        annotations: AnnotationDocument?,
        renderedImage: CGImage?
    ) async throws
    func rollbackPersistedCapture(_ outcome: CapturePersistenceOutcome) async throws
}

extension CapturePersisting {
    func commitCapture(
        _ image: CapturedImage,
        annotations: AnnotationDocument? = nil,
        renderedImage: CGImage? = nil
    ) async throws -> CapturePersistenceOutcome {
        try await persistCapture(image, annotations: annotations, renderedImage: renderedImage)
        return CapturePersistenceOutcome(recordID: image.id)
    }

    func persistCapture(
        _ image: CapturedImage,
        annotations: AnnotationDocument?,
        renderedImage: CGImage?
    ) async throws {
        try await persistCapture(image)
    }

    func rollbackPersistedCapture(_ outcome: CapturePersistenceOutcome) async throws {
        throw CaptureLibraryError.rollbackFailed(
            primary: CancellationError().localizedDescription,
            rollback: "The persistence backend cannot roll back a committed capture."
        )
    }
}

extension CaptureLibraryStore: CapturePersisting {
    func persistCapture(_ image: CapturedImage) async throws {
        _ = try await persist(image: image)
    }

    func persistCapture(
        _ image: CapturedImage,
        annotations: AnnotationDocument?,
        renderedImage: CGImage?
    ) async throws {
        _ = try await persist(image: image, annotations: annotations, renderedImage: renderedImage)
    }

    func rollbackPersistedCapture(_ outcome: CapturePersistenceOutcome) async throws {
        do {
            try await rollbackPersistedImageCapture(id: outcome.recordID)
        } catch let error as CaptureLibraryError {
            throw error
        } catch {
            throw CaptureLibraryError.rollbackFailed(
                primary: CancellationError().localizedDescription,
                rollback: error.localizedDescription
            )
        }
    }
}

struct CapturePublication: @unchecked Sendable {
    let capture: CapturedImage
    let areaSelection: AreaSelection?
    let document: AnnotationDocument?
    /// The off-main-actor Baked render already produced for `document` at Confirm (nil for an
    /// empty/no-annotation capture) — reused as the post-capture preview so it isn't rendered
    /// twice.
    let renderedImage: CGImage?
}

@MainActor
protocol CapturePublishing: AnyObject {
    func publish(_ publication: CapturePublication)
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
    private let renderService: any AnnotationRenderServicing

    init(
        capturer: any ScreenshotCapturing,
        persistence: any CapturePersisting,
        publisher: any CapturePublishing,
        renderService: any AnnotationRenderServicing = DetachedAnnotationRenderService()
    ) {
        self.capturer = capturer
        self.persistence = persistence
        self.publisher = publisher
        self.renderService = renderService
    }

    /// `payload`: Quick Annotation items drafted on the Selection Overlay, already normalized
    /// against the final selection (PLAN.md §9). When non-empty, the document is Baked off the
    /// main actor via `renderService` before persistence, so a large/blurred image can't freeze
    /// the UI; the Baked image also becomes the source for the persisted thumbnail. An empty (or
    /// absent) payload skips this path entirely — byte-identical to a plain screenshot.
    ///
    /// `frozenImage`: the Selection Overlay's pre-capture per-display snapshot (frozen at
    /// `beginAreaSelection`, before the overlay ever showed live desktop pixels) — cropped to the
    /// final selection instead of a fresh live capture, so annotations line up with exactly what
    /// gets persisted and live apps below the overlay never change the outcome mid-annotation.
    /// `nil` when no snapshot was captured (permission failure, etc.) — falls back to today's live
    /// capture at Confirm.
    func captureArea(
        _ selection: AreaSelection,
        options: CaptureOptions,
        payload: PendingAnnotationPayload? = nil,
        frozenImage: CGImage? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        registerCleanupRetry: @escaping @MainActor (CaptureCleanupRetryOperation) -> Void = { _ in }
    ) async throws {
        let image = try await resolveAreaCapture(selection, options: options, frozenImage: frozenImage)
        var document: AnnotationDocument?
        var renderedImage: CGImage?
        if let payload, !payload.items.isEmpty {
            let builtDocument = AnnotationDocument(captureID: image.id, items: payload.items)
            renderedImage = try await renderService.render(capture: image, document: builtDocument)
            document = builtDocument
        }
        try await persistAndPublish(
            image,
            areaSelection: selection,
            document: document,
            renderedImage: renderedImage,
            isCurrent: isCurrent,
            registerCleanupRetry: registerCleanupRetry
        )
    }

    private func resolveAreaCapture(
        _ selection: AreaSelection,
        options: CaptureOptions,
        frozenImage: CGImage?
    ) async throws -> CapturedImage {
        if let frozenImage {
            let cropRect = CaptureGeometry.cropRectForAreaSelection(
                selection.rect,
                display: selection.display,
                imagePixelSize: PixelSize(width: frozenImage.width, height: frozenImage.height)
            )
            if cropRect.width > 0, cropRect.height > 0, let cropped = frozenImage.cropping(to: cropRect) {
                return CapturedImage(
                    id: UUID(),
                    kind: .area,
                    title: "Area capture",
                    createdAt: .now,
                    image: cropped,
                    pixelSize: PixelSize(width: cropped.width, height: cropped.height)
                )
            }
        }
        return try await capturer.captureArea(
            selection.rect,
            display: selection.display,
            options: options
        )
    }

    func captureDisplay(
        _ displayID: CGDirectDisplayID,
        options: CaptureOptions,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        registerCleanupRetry: @escaping @MainActor (CaptureCleanupRetryOperation) -> Void = { _ in }
    ) async throws {
        let image = try await capturer.captureDisplay(displayID, options: options)
        try await persistAndPublish(
            image,
            isCurrent: isCurrent,
            registerCleanupRetry: registerCleanupRetry
        )
    }

    func captureWindow(
        _ windowID: CGWindowID,
        options: CaptureOptions,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        registerCleanupRetry: @escaping @MainActor (CaptureCleanupRetryOperation) -> Void = { _ in }
    ) async throws {
        let image = try await capturer.captureWindow(windowID, options: options)
        try await persistAndPublish(
            image,
            isCurrent: isCurrent,
            registerCleanupRetry: registerCleanupRetry
        )
    }

    func persistAndPublish(
        _ image: CapturedImage,
        areaSelection: AreaSelection? = nil,
        document: AnnotationDocument? = nil,
        renderedImage: CGImage? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        registerCleanupRetry: @escaping @MainActor (CaptureCleanupRetryOperation) -> Void = { _ in }
    ) async throws {
        guard isCurrent() else { throw CancellationError() }
        let expectedOutcome = CapturePersistenceOutcome(recordID: image.id)
        registerCleanupRetry(CaptureCleanupRetryOperation(run: { [persistence] in
            try await persistence.rollbackPersistedCapture(expectedOutcome)
        }))
        let outcome = try await persistence.commitCapture(
            image,
            annotations: document,
            renderedImage: renderedImage
        )
        guard isCurrent() else {
            try await persistence.rollbackPersistedCapture(outcome)
            throw CancellationError()
        }
        publisher.publish(CapturePublication(
            capture: image,
            areaSelection: areaSelection,
            document: document,
            renderedImage: renderedImage
        ))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {}

@MainActor
final class ScreenCaptureController: CaptureIntentHandling {
    private let capturer: any ScreenshotCapturing
    private let pipeline: CapturePipeline
    private let scrollingEngine: ScrollingCaptureEngine
    private let screenCaptureAccess: (@MainActor () -> Bool)?
    private weak var reporter: (any CaptureOperationReporting)?
    private var overlayWindows: [SelectionOverlayWindow] = []
    private var selectionOwnership = SelectionOwnership()
    private let operationScope = CaptureOperationScope()
    private lazy var scheduler = CaptureIntentScheduler(handler: self)
    private var scheduledCompletion: CaptureOperationCompletion?
    private let manualScrollTargetResolver: any ManualScrollTargetResolving
    private let manualScrollHotKeySlotFactory: @MainActor () -> any ManualScrollHotKeyRegistering
    private let manualScrollShortcutProvider: () -> ShortcutPreference
    private let ownBundleIdentifier: String?

    init(
        capturer: any ScreenshotCapturing,
        persistence: any CapturePersisting,
        publisher: any CapturePublishing,
        screenCaptureAccess: (@MainActor () -> Bool)? = nil,
        reporter: (any CaptureOperationReporting)? = nil,
        windowScroller: any WindowScrolling = AccessibilityWindowScroller(),
        manualScrollTargetResolver: any ManualScrollTargetResolving = SystemManualScrollTargetResolver(),
        manualScrollHotKeySlotFactory: @escaping @MainActor () -> any ManualScrollHotKeyRegistering = {
            HotKeySessionSlot(registrar: CarbonHotKeyRegistrar())
        },
        manualScrollShortcutProvider: @escaping () -> ShortcutPreference = {
            ShortcutPreferenceStore(
                key: ShortcutAction.scrollingManual.storageKey,
                defaultPreference: ShortcutAction.scrollingManual.defaultPreference,
                requiresSupportedKey: true
            ).load()
        },
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
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
        self.screenCaptureAccess = screenCaptureAccess
        self.reporter = reporter
        self.manualScrollTargetResolver = manualScrollTargetResolver
        self.manualScrollHotKeySlotFactory = manualScrollHotKeySlotFactory
        self.manualScrollShortcutProvider = manualScrollShortcutProvider
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    func scheduleCapture(
        mode: CaptureMode,
        options: CaptureOptions,
        completion: AppCaptureCompletion? = nil
    ) {
        if mode == .scrolling, operationScope.isActive(.scrollingDiscovery) {
            completion?()
            return
        }
        if mode == .scrollingManual, operationScope.isActive(.manualScrollCapture) {
            completion?()
            return
        }
        operationScope.cancel()
        dismissOverlays()
        let operationCompletion = CaptureOperationCompletion(completion)
        scheduledCompletion = operationCompletion
        scheduler.schedule(
            CaptureIntent(mode: mode),
            options: options,
            onCancellation: { [weak self, weak operationCompletion] in
                guard let operationCompletion else { return }
                if self?.scheduledCompletion === operationCompletion {
                    self?.scheduledCompletion = nil
                }
                operationCompletion.finish()
            }
        )
    }

    func beginAreaSelection(options: CaptureOptions) {
        let completion = takeScheduledCompletion()
        guard let token = operationScope.begin(.areaSelection, completion: completion) else {
            completion?.finish()
            return
        }
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
        selectionOwnership = SelectionOwnership()

        // Snapshot every involved display BEFORE any overlay window is shown (PLAN change:
        // "freeze the image"). The overlay then annotates over these frozen pixels instead of the
        // live desktop, and Confirm crops the same snapshot — WYSIWYG, and live apps below can
        // never receive clicks or change the outcome mid-annotation. A display whose snapshot
        // fails (permission revoked mid-flight, transient failure, etc.) falls back to today's
        // transparent-live-overlay + live-capture-at-confirm behavior for that display only.
        let task = Task { [weak self] in
            guard let self else { return }
            var snapshots: [CGDirectDisplayID: CGImage] = [:]
            for (_, display) in screens {
                guard self.operationScope.isCurrent(token) else { return }
                if let captured = try? await self.capturer.captureDisplay(display.id, options: options) {
                    snapshots[display.id] = captured.image
                }
            }
            guard self.operationScope.isCurrent(token) else { return }
            self.presentAreaSelectionOverlays(
                screens: screens,
                snapshots: snapshots,
                options: options,
                token: token
            )
        }
        operationScope.retain(task, for: token)
    }

    private func presentAreaSelectionOverlays(
        screens: [(NSScreen, DisplayGeometry)],
        snapshots: [CGDirectDisplayID: CGImage],
        options: CaptureOptions,
        token: CaptureOperationScope.Token
    ) {
        overlayWindows = screens.map { screen, display in
            SelectionOverlayWindow(
                screen: screen,
                display: display,
                snapshot: snapshots[display.id],
                onSelection: { [weak self] selection, payload, snapshot in
                    guard let self, self.operationScope.isCurrent(token) else { return }
                    self.completeAreaSelection(
                        selection,
                        payload: payload,
                        snapshot: snapshot,
                        options: options,
                        token: token
                    )
                },
                onCancel: { [weak self] in
                    guard let self, self.operationScope.isCurrent(token) else { return }
                    Task {
                        do { try await self.cancelCurrentOperation() }
                        catch { self.presentCaptureError(error) }
                    }
                },
                onFullScreen: { [weak self] displayID in
                    guard let self, self.operationScope.isCurrent(token) else { return }
                    self.completeDisplayCapture(displayID, options: options, token: token)
                },
                onSelectionCommitted: { [weak self] in
                    guard let self, self.operationScope.isCurrent(token) else { return }
                    self.claimSelectionOwnership(for: display.id)
                }
            )
        }
        // Accessory (menu-bar) apps only get real key-window/keyboard focus once
        // NSApp itself is active. Activating after order-front leaves the overlay
        // visually frontmost but never actually key, so Return/Esc are silently
        // dropped. Activate first, then order front and take key.
        NSApp.activate(ignoringOtherApps: true)
        overlayWindows.forEach { $0.orderFrontRegardless() }
        overlayWindows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
    }

    func beginWindowPicker(options: CaptureOptions) {
        let completion = takeScheduledCompletion()
        guard let token = operationScope.begin(.windowDiscovery, completion: completion) else {
            completion?.finish()
            return
        }
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
                    },
                    registerCleanupRetry: { [weak self] retry in
                        self?.operationScope.registerCleanupRetry(retry, for: token)
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                if operationScope.isCurrent(token) {
                    presentCaptureError(error)
                    return
                }
                throw error
            }
        }
        operationScope.retain(task, for: token)
    }

    func beginDisplayCapture(options: CaptureOptions) {
        let completion = takeScheduledCompletion()
        guard let token = operationScope.begin(.displayCapture, completion: completion) else {
            completion?.finish()
            return
        }
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
        let completion = takeScheduledCompletion()
        guard let token = operationScope.begin(.scrollingDiscovery, completion: completion) else {
            completion?.finish()
            return
        }
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
                        },
                        registerCleanupRetry: { [weak self] retry in
                            self?.operationScope.registerCleanupRetry(retry, for: token)
                        }
                    )
                case .partial(let capture, let reason):
                    guard confirmUsingPartialCapture(capture, reasonDescription: reason.localizedDescription),
                          operationScope.isCurrent(token)
                    else { return }
                    try await pipeline.persistAndPublish(
                        capture,
                        isCurrent: { [weak self] in
                            self?.operationScope.isCurrent(token) == true
                        },
                        registerCleanupRetry: { [weak self] retry in
                            self?.operationScope.registerCleanupRetry(retry, for: token)
                        }
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                if operationScope.isCurrent(token) {
                    presentCaptureError(error)
                    return
                }
                throw error
            }
        }
        operationScope.retain(task, for: token)
    }

    func beginManualScrollCapture(options: CaptureOptions) {
        let completion = takeScheduledCompletion()
        guard let token = operationScope.begin(.manualScrollCapture, completion: completion) else {
            completion?.finish()
            return
        }
        guard ensureScreenCaptureAccess() else {
            operationScope.finish(token)
            return
        }
        guard capturer.supportsWindowExclusion() else {
            reporter?.captureFailed(CaptureError.captureFailed(
                "This Mac's capture provider cannot exclude Take a Shot's own windows, which Manual Scroll Capture requires."
            ))
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
        selectionOwnership = SelectionOwnership()
        let frontmostBeforeOverlay = NSWorkspace.shared.frontmostApplication

        overlayWindows = screens.map { screen, display in
            SelectionOverlayWindow(
                screen: screen,
                display: display,
                snapshot: nil,
                allowsQuickAnnotation: false,
                onSelection: { [weak self] selection, _, _ in
                    guard let self, self.operationScope.isCurrent(token) else { return }
                    self.beginManualScrollSession(
                        selection: selection,
                        options: options,
                        frontmostBeforeOverlay: frontmostBeforeOverlay,
                        token: token
                    )
                },
                onCancel: { [weak self] in
                    guard let self, self.operationScope.isCurrent(token) else { return }
                    Task {
                        do { try await self.cancelCurrentOperation() }
                        catch { self.presentCaptureError(error) }
                    }
                },
                onFullScreen: { [weak self] displayID in
                    guard let self, self.operationScope.isCurrent(token) else { return }
                    guard let display = screens.first(where: { $0.1.id == displayID })?.1 else { return }
                    let selection = AreaSelection(
                        localRect: CGRect(origin: .zero, size: display.frame.size),
                        display: display
                    )
                    self.beginManualScrollSession(
                        selection: selection,
                        options: options,
                        frontmostBeforeOverlay: frontmostBeforeOverlay,
                        token: token
                    )
                },
                onSelectionCommitted: { [weak self] in
                    guard let self, self.operationScope.isCurrent(token) else { return }
                    self.claimSelectionOwnership(for: display.id)
                }
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        overlayWindows.forEach { $0.orderFrontRegardless() }
        overlayWindows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
    }

    /// PLAN.md §3: target resolution → awaited seed transaction (before any HUD/border) → session
    /// controller (border, HUD, revalidate+activate, session-scoped hotkey) → runs until Done/
    /// Cancel/auto-finish → result routed through the same partial-confirmation dialog and
    /// `persistAndPublish` as every other capture path.
    private func beginManualScrollSession(
        selection: AreaSelection,
        options: CaptureOptions,
        frontmostBeforeOverlay: NSRunningApplication?,
        token: CaptureOperationScope.Token
    ) {
        dismissOverlays()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { operationScope.finish(token) }
            do {
                let quartzRect = ManualScrollCoordinateConversion.quartzRect(
                    fromAppKitRect: selection.rect,
                    primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0
                )
                let resolvedTarget = manualScrollTargetResolver.topmostWindow(
                    at: CGPoint(x: quartzRect.midX, y: quartzRect.midY),
                    excludingBundleIdentifier: ownBundleIdentifier
                )

                let seedCapture = try await capturer.captureArea(
                    selection.rect,
                    display: selection.display,
                    options: options
                )
                try Task.checkCancellation()
                guard operationScope.isCurrent(token) else { return }

                let engine = try ManualScrollCaptureEngine(
                    seed: seedCapture.image,
                    frameProvider: { [capturer] in
                        try await capturer.captureArea(selection.rect, display: selection.display, options: options).image
                    },
                    targetResolver: manualScrollTargetResolver,
                    monitoringWindowID: resolvedTarget?.windowID,
                    quartzCaptureRect: quartzRect,
                    ownBundleIdentifier: ownBundleIdentifier
                )
                let session = ManualScrollSessionController(
                    engine: engine,
                    selection: selection,
                    targetResolver: manualScrollTargetResolver,
                    resolvedTarget: resolvedTarget,
                    fallbackApplication: frontmostBeforeOverlay,
                    hotKeySlot: manualScrollHotKeySlotFactory(),
                    shortcut: manualScrollShortcutProvider()
                )
                // `session.run()` suspends on a checked continuation, which is not itself
                // cancellation-aware — `withTaskCancellationHandler` bridges Swift task
                // cancellation (from `operationScope.cancelAndWait()`, e.g. the app starting a
                // different capture mid-session) into `session.cancel()`, which resolves the
                // continuation instead of leaving it hung forever.
                let outcome = await withTaskCancellationHandler(
                    operation: { await session.run() },
                    onCancel: { Task { @MainActor in session.cancel() } }
                )
                try Task.checkCancellation()
                guard operationScope.isCurrent(token) else { return }

                switch outcome {
                case .cancelled:
                    return
                case .failed(let error):
                    presentCaptureError(error)
                case .completed(let image):
                    try await persistManualScrollResult(image, token: token)
                case .partial(let image, let reason):
                    let captured = capturedImage(image, kind: .scrolling, title: "Scroll capture")
                    guard confirmUsingPartialCapture(captured, reasonDescription: reason.localizedDescription),
                          operationScope.isCurrent(token)
                    else { return }
                    try await pipeline.persistAndPublish(
                        captured,
                        isCurrent: { [weak self] in self?.operationScope.isCurrent(token) == true },
                        registerCleanupRetry: { [weak self] retry in
                            self?.operationScope.registerCleanupRetry(retry, for: token)
                        }
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                if operationScope.isCurrent(token) {
                    presentCaptureError(error)
                    return
                }
                throw error
            }
        }
        operationScope.retain(task, for: token)
    }

    private func persistManualScrollResult(
        _ image: CGImage,
        token: CaptureOperationScope.Token
    ) async throws {
        let captured = capturedImage(image, kind: .scrolling, title: "Scroll capture")
        try await pipeline.persistAndPublish(
            captured,
            isCurrent: { [weak self] in self?.operationScope.isCurrent(token) == true },
            registerCleanupRetry: { [weak self] retry in
                self?.operationScope.registerCleanupRetry(retry, for: token)
            }
        )
    }

    private func capturedImage(_ image: CGImage, kind: CaptureKind, title: String) -> CapturedImage {
        CapturedImage(
            id: UUID(),
            kind: kind,
            title: title,
            createdAt: .now,
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height)
        )
    }

    func beginRecordingPicker(options: CaptureOptions) {
        let completion = takeScheduledCompletion()
        reporter?.captureFailed(CaptureError.captureFailed(
            "Choose MP4 or GIF from the recording controls."
        ))
        completion?.finish()
    }

    func cancelScrollingCapture() {
        Task {
            do { try await operationScope.cancelAndWait() }
            catch { presentCaptureError(error) }
        }
    }

    func cancelCurrentOperation() async throws {
        await scheduler.cancel()
        scheduledCompletion = nil
        try await operationScope.cancelAndWait()
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
        if let screenCaptureAccess {
            let granted = screenCaptureAccess()
            if !granted, reportsFailure {
                reporter?.captureFailed(CaptureError.permissionDenied)
            }
            return granted
        }
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        let granted = CGRequestScreenCaptureAccess()
        if !granted, reportsFailure {
            reporter?.captureFailed(CaptureError.permissionDenied)
        }
        return granted
    }

    /// First display to commit a selection claims ownership for the rest of the operation
    /// (PLAN.md §7): every other overlay goes inert, and a display that loses the race also goes
    /// inert instead of keeping its own partial selection. Never transferred mid-operation.
    private func claimSelectionOwnership(for displayID: CGDirectDisplayID) {
        guard selectionOwnership.claim(displayID) else {
            overlayWindows.first(where: { $0.displayID == displayID })?.overlayView.setInert()
            return
        }
        for window in overlayWindows where window.displayID != displayID {
            window.overlayView.setInert()
        }
    }

    private func completeAreaSelection(
        _ selection: AreaSelection,
        payload: PendingAnnotationPayload,
        snapshot: CGImage?,
        options: CaptureOptions,
        token: CaptureOperationScope.Token
    ) {
        dismissOverlays()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { operationScope.finish(token) }
            do {
                try await pipeline.captureArea(
                    selection,
                    options: options,
                    payload: payload,
                    frozenImage: snapshot,
                    isCurrent: { [weak self] in
                        self?.operationScope.isCurrent(token) == true
                    },
                    registerCleanupRetry: { [weak self] retry in
                        self?.operationScope.registerCleanupRetry(retry, for: token)
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                if operationScope.isCurrent(token) {
                    presentCaptureError(error)
                    return
                }
                throw error
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
                    },
                    registerCleanupRetry: { [weak self] retry in
                        self?.operationScope.registerCleanupRetry(retry, for: token)
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                if operationScope.isCurrent(token) {
                    presentCaptureError(error)
                    return
                }
                throw error
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
        reasonDescription: String
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Scrolling capture stopped early"
        alert.informativeText = "\(reasonDescription) A \(capture.pixelSize.height)-pixel partial image is available."
        alert.addButton(withTitle: "Use Partial")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func dismissOverlays() {
        let windows = overlayWindows
        overlayWindows.removeAll()
        windows.forEach { $0.orderOut(nil) }
    }

    private func takeScheduledCompletion() -> CaptureOperationCompletion? {
        defer { scheduledCompletion = nil }
        return scheduledCompletion
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
    var onCapture: ((CapturePublication) -> Void)?
    var onProgress: ((ScrollingCaptureProgress) -> Void)?
    var onScrollingChanged: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    func publish(_ publication: CapturePublication) {
        onCapture?(publication)
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
    let displayID: CGDirectDisplayID
    let overlayView: SelectionOverlayView

    init(
        screen: NSScreen,
        display: DisplayGeometry,
        snapshot: CGImage?,
        allowsQuickAnnotation: Bool = true,
        onSelection: @escaping (AreaSelection, PendingAnnotationPayload, CGImage?) -> Void,
        onCancel: @escaping () -> Void,
        onFullScreen: @escaping (CGDirectDisplayID) -> Void,
        onSelectionCommitted: @escaping () -> Void
    ) {
        displayID = display.id
        let view = SelectionOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            display: display,
            snapshot: snapshot,
            allowsQuickAnnotation: allowsQuickAnnotation
        )
        overlayView = view
        view.onSelection = onSelection
        view.onCancel = onCancel
        view.onFullScreen = { onFullScreen(display.id) }
        view.onSelectionCommitted = onSelectionCommitted

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
        // AppKit does per-pixel-alpha hit-testing on a transparent, non-opaque window by default,
        // so fully-transparent regions (the selection interior before Change 2's frozen image
        // covers it, or a display whose snapshot capture failed) let clicks fall through to
        // whatever app is beneath the overlay. Explicit assignment disables that — the window
        // itself owns every click for the life of the operation, regardless of what's drawn.
        self.ignoresMouseEvents = false
        self.makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionOverlayView: NSView, NSTextFieldDelegate {
    var onSelection: ((AreaSelection, PendingAnnotationPayload, CGImage?) -> Void)?
    var onCancel: (() -> Void)?
    var onFullScreen: (() -> Void)?
    /// Fires the first time a drag produces a committed rect — the controller uses this to claim
    /// multi-display ownership (PLAN.md §7).
    var onSelectionCommitted: (() -> Void)?

    private let display: DisplayGeometry
    /// This display's snapshot taken at `beginAreaSelection`, before the overlay ever showed live
    /// desktop pixels — `nil` when the snapshot capture failed (falls back to the pre-freeze,
    /// fully-transparent overlay). Pixel-sized; `draw(_:)` scales it into `bounds` (points).
    private let snapshot: CGImage?
    /// `false` for the Manual Scroll Capture intent (PLAN.md §2): annotation coordinates would be
    /// meaningless against a not-yet-known tall stitched canvas, so the Quick Annotation toolbar
    /// never appears and `activeTool` can never leave `.select` — the toolbar's `onSelectTool` and
    /// the 1-9 number-key shortcuts are the only things that ever change it, and both are gated on
    /// this flag.
    private let allowsQuickAnnotation: Bool

    private enum DragMode {
        case none
        case creating
        case resizing(SelectionHandle)
        case moving
    }

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var committedRect: CGRect?
    private var dragMode: DragMode = .none
    private var dragStartRect: CGRect?
    private var dragStartPoint: CGPoint?

    /// `true` once another display has claimed ownership of this operation — this overlay shows
    /// only a dimmed scrim and ignores all input for the remainder of the operation.
    private(set) var isInert = false

    private var activeTool: AnnotationTool = .select
    private var style = AnnotationStyle.standard
    private var draft = OverlayAnnotationDraft()
    private var draftDragStart: CGPoint?
    private var draftDragCurrent: CGPoint?

    private var fieldEditor: NSTextField?
    private var fieldEditorTool: AnnotationTool?
    /// 8 dedicated handle subviews (PLAN.md "Text Input") positioned by the pure `SelectionHandle`
    /// geometry against `fieldEditor.frame` — only installed for the `.text` tool (the `.emoji`
    /// field stays single-shot, out of scope for resizing). Lifecycle matches the field editor's
    /// own: created in `beginFieldEditor`, repositioned on every frame change, removed in
    /// `commitFieldEditor`/`cancelFieldEditor`/`setInert`.
    private var fieldHandles: [FieldResizeHandleView] = []
    /// Set the moment a person drags a field-editor handle — stops `controlTextDidChange`'s
    /// auto-grow from touching the frame again, mirroring `PendingAnnotationText.userSized`.
    private var fieldUserSized = false

    private var toolbarHost: NSHostingView<SelectionOverlayToolbarView>?

    /// Armed by the first Esc / toolbar ✕ over a committed selection; the second one discards
    /// (`SelectionCancelPolicy`). Anything else the person does disarms it.
    private var isCancelArmed = false

    private static let handleHitTolerance: CGFloat = 14
    /// Tighter grab radius while a drawing tool is active — the handles stay reachable (the drawn
    /// dot is 8pt wide) without turning the whole selection border into a no-drawing zone.
    private static let drawingHandleHitTolerance: CGFloat = 10
    private static let handleCursorSize: CGFloat = 16
    private static let minimumSelectionSize: CGFloat = 8
    private static let minimumDraftDragSize: CGFloat = 2

    /// Physical 60x28 px floor for the text field editor (PLAN.md "Text Input"), converted to
    /// display points so the same pixel invariant holds across Retina scales — matches the post-
    /// capture editor's normalized `min(60, w)/w x min(28, h)/h` floor, applied here in points
    /// since the overlay's field frame is a points-space `CGRect`, not normalized.
    private var minimumFieldTextSize: CGSize {
        CGSize(width: 60 / display.scale, height: 28 / display.scale)
    }

    private var currentHandleHitTolerance: CGFloat {
        activeTool == .select ? Self.handleHitTolerance : Self.drawingHandleHitTolerance
    }

    init(frame: NSRect, display: DisplayGeometry, snapshot: CGImage?, allowsQuickAnnotation: Bool = true) {
        self.display = display
        self.snapshot = snapshot
        self.allowsQuickAnnotation = allowsQuickAnnotation
        super.init(frame: frame)
        // Layer-backed for AppKit drawing. Note this does NOT make `CGContext.makeImage()` succeed
        // inside `draw(_:)` — it returns nil here regardless (confirmed root cause of the live blur
        // preview once drawing nothing) — which is why `drawDraftItems` passes `snapshot` as
        // `AnnotationRenderer.drawDraft`'s `source:`, letting `.blur` sample the frozen snapshot
        // image directly instead of reading this context back.
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SelectionOverlayView does not support NSCoding")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Bottom layer: the frozen per-display snapshot, scaled from its pixel size into `bounds`
        // (points) — annotating happens over this static image, never the live desktop, and it's
        // what Confirm crops from (WYSIWYG). Falls back to nothing (transparent, pre-freeze
        // behavior) when this display's snapshot capture failed.
        if let snapshot, let context = NSGraphicsContext.current?.cgContext {
            context.draw(snapshot, in: bounds)
        }

        let overlayPath = NSBezierPath(rect: bounds)

        if isInert {
            NSColor.black.withAlphaComponent(0.46).setFill()
            bounds.fill()
            return
        }

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
            drawDraftItems(clippingTo: selection)
        } else {
            NSColor.black.withAlphaComponent(0.46).setFill()
            bounds.fill()
        }

        drawInstructions()
    }

    override func mouseDown(with event: NSEvent) {
        guard !isInert else { return }
        if fieldEditor != nil {
            commitFieldEditor()
            return
        }
        disarmCancel()
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2, let rect = committedRect, rect.contains(point) {
            if case .confirmSelection = SelectionOverlayPrecedence.action(
                for: .doubleClick,
                isFieldEditorActive: fieldEditor != nil,
                hasCommittedSelection: true,
                activeTool: activeTool
            ), rect.width > Self.minimumSelectionSize, rect.height > Self.minimumSelectionSize {
                confirm(rect)
            }
            return
        }

        switch SelectionPointerHitTest.target(
            at: point,
            committedRect: committedRect,
            activeTool: activeTool,
            tolerance: currentHandleHitTolerance
        ) {
        case let .resizeHandle(handle):
            dragMode = .resizing(handle)
            dragStartRect = committedRect
            updateDisplay()
        case .draft:
            guard let rect = committedRect else { return }
            beginDraftInteraction(at: point, in: rect)
        case .move:
            dragMode = .moving
            dragStartRect = committedRect
            dragStartPoint = point
            updateDisplay()
        case .createNew:
            committedRect = nil
            dragMode = .creating
            startPoint = point
            currentPoint = point
            updateDisplay()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isInert else { return }
        let point = convert(event.locationInWindow, from: nil)

        if draftDragStart != nil {
            draftDragCurrent = point
            updateDisplay()
            return
        }

        switch dragMode {
        case .creating:
            currentPoint = point
        case .resizing(let handle):
            if let dragStartRect {
                committedRect = CaptureGeometry.clamp(handle.resized(dragStartRect, to: point), to: bounds)
            }
        case .moving:
            if let dragStartRect, let dragStartPoint {
                let moved = dragStartRect.offsetBy(
                    dx: point.x - dragStartPoint.x,
                    dy: point.y - dragStartPoint.y
                )
                committedRect = CaptureGeometry.clamp(moved, to: bounds)
            }
        case .none:
            break
        }

        updateDisplay()
    }

    override func mouseUp(with event: NSEvent) {
        guard !isInert else { return }
        let point = convert(event.locationInWindow, from: nil)

        if let start = draftDragStart {
            commitDraftDrag(from: start, to: point)
            draftDragStart = nil
            draftDragCurrent = nil
            updateDisplay()
            return
        }

        currentPoint = point

        if case .creating = dragMode {
            let wasUncommitted = committedRect == nil
            if let rect = selectionRect, rect.width > Self.minimumSelectionSize, rect.height > Self.minimumSelectionSize {
                committedRect = rect
                if wasUncommitted { onSelectionCommitted?() }
            }
            startPoint = nil
            currentPoint = nil
        }

        dragMode = .none
        dragStartRect = nil
        dragStartPoint = nil
        updateDisplay()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            disarmCancel()
            undoLastDraftItem()
            return
        }
        guard let input = overlayInput(for: event) else {
            disarmCancel()
            super.keyDown(with: event)
            return
        }
        if input != .escapeKey { disarmCancel() }
        switch SelectionOverlayPrecedence.action(
            for: input,
            isFieldEditorActive: fieldEditor != nil,
            hasCommittedSelection: committedRect != nil,
            activeTool: activeTool,
            allowsQuickAnnotation: allowsQuickAnnotation
        ) {
        case .cancelFieldEditor:
            cancelFieldEditor()
        case .commitFieldEditor:
            commitFieldEditor()
        case .confirmSelection:
            if let rect = committedRect, rect.width > Self.minimumSelectionSize, rect.height > Self.minimumSelectionSize {
                confirm(rect)
            }
        case .captureFullScreen:
            window?.orderOut(nil)
            onFullScreen?()
        case .cancelOperation:
            requestCancel()
        case let .selectTool(tool):
            activeTool = tool
            updateDisplay()
        case .ignore:
            // A recognized key the chain decided not to act on (e.g. a digit with no toolbar on
            // screen) is not ours to swallow — forward it exactly as an unrecognized key.
            super.keyDown(with: event)
        }
    }

    private func overlayInput(for event: NSEvent) -> SelectionOverlayInput? {
        SelectionOverlayInput(
            keyCode: event.keyCode,
            hasCommandOptionControl: !event.modifierFlags
                .intersection([.command, .option, .control]).isEmpty
        )
    }

    override func resetCursorRects() {
        guard !isInert else { return }
        addCursorRect(bounds, cursor: .crosshair)
        guard let rect = committedRect else { return }
        if let toolbarFrame = toolbarHost?.frame {
            addCursorRect(toolbarFrame, cursor: .arrow)
        }
        // Moving the selection is Select-only, but the resize handles stay live for every tool
        // (`SelectionPointerHitTest`) — added last so they win wherever they overlap the rect.
        if activeTool == .select {
            addCursorRect(rect, cursor: .openHand)
        }
        for handle in SelectionHandle.allCases {
            let point = handle.point(in: rect)
            let handleRect = CGRect(
                x: point.x - Self.handleCursorSize / 2,
                y: point.y - Self.handleCursorSize / 2,
                width: Self.handleCursorSize,
                height: Self.handleCursorSize
            )
            addCursorRect(handleRect, cursor: handle.cursor)
        }
    }

    /// Test seam only (no production caller): whether the Quick Annotation toolbar is currently
    /// showing — `false` for the whole life of a manual-scroll overlay (`allowsQuickAnnotation ==
    /// false`), PLAN.md §2.
    var isQuickAnnotationToolbarVisible: Bool { toolbarHost != nil }

    /// Called by `ScreenCaptureController` when another display claims ownership of this
    /// operation (PLAN.md §7). Clears any partial/committed selection and ignores input for the
    /// rest of the operation — no mid-operation transfer back.
    func setInert() {
        isInert = true
        committedRect = nil
        startPoint = nil
        currentPoint = nil
        dragMode = .none
        dragStartRect = nil
        dragStartPoint = nil
        draft = OverlayAnnotationDraft()
        draftDragStart = nil
        draftDragCurrent = nil
        isCancelArmed = false
        cancelFieldEditor()
        removeToolbar()
        updateDisplay()
    }

    /// The single cancel path for both Esc and the toolbar's ✕ — neither discards a committed
    /// selection (and whatever Quick Annotation is on it) without a second, confirming request.
    private func requestCancel() {
        // Esc with the mouse still down belongs to the drag in progress, not to the operation —
        // arming (or cancelling) mid-resize is what made Esc feel like it "cancelled the resizing".
        guard case .none = dragMode, draftDragStart == nil else { return }
        switch SelectionCancelPolicy.decision(
            hasCommittedSelection: committedRect != nil,
            isArmed: isCancelArmed
        ) {
        case .arm:
            isCancelArmed = true
            updateDisplay()
        case .cancel:
            isCancelArmed = false
            window?.orderOut(nil)
            onCancel?()
        }
    }

    private func disarmCancel() {
        guard isCancelArmed else { return }
        isCancelArmed = false
        updateDisplay()
    }

    private func confirm(_ rect: CGRect) {
        window?.orderOut(nil)
        let selection = AreaSelection(localRect: rect, display: display)
        let payload = OverlayAnnotationConversion.payload(
            for: draft,
            selectionRect: selection.rect,
            styleScale: display.scale
        )
        onSelection?(selection, payload, snapshot)
    }

    private func updateDisplay() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        updateToolbar()
    }

    private var selectionRect: CGRect? {
        if let committedRect { return committedRect }
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        )
    }

    // MARK: - Quick Annotation draft

    private func globalPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + display.frame.minX, y: point.y + display.frame.minY)
    }

    private func globalRect(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
    }

    private var nextStepNumber: Int {
        (draft.items.compactMap { item -> Int? in
            guard case let .step(_, number) = item else { return nil }
            return number
        }.max() ?? 0) + 1
    }

    private func beginDraftInteraction(at point: CGPoint, in selection: CGRect) {
        switch activeTool {
        case .text:
            beginFieldEditor(at: point, tool: .text)
        case .emoji:
            placeEmoji(at: point, in: selection)
        case .steps:
            draft.items.append(.step(center: globalPoint(point), number: nextStepNumber))
            updateDisplay()
        case .arrow, .highlight, .blur, .rect, .ellipse:
            draftDragStart = point
            draftDragCurrent = point
            updateDisplay()
        case .select, .crop:
            break
        }
    }

    /// Places the currently-picked emoji directly at `point`, mirroring `AnnotationEditor.placeEmoji`'s
    /// fixed-fraction sizing (12% of the target rect) — here the target rect is the committed
    /// selection (`selection`, view-local) rather than the final image, since that's what the
    /// draft's bounds get normalized against at Confirm (`OverlayAnnotationConversion`).
    private func placeEmoji(at point: CGPoint, in selection: CGRect) {
        let fraction: CGFloat = 0.12
        let size = min(selection.width, selection.height) * fraction
        let bounds = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        draft.items.append(.text(
            bounds: globalRect(bounds),
            text: style.emoji,
            fontSize: AnnotationStyle.emojiFontSize,
            color: style.color
        ))
        updateDisplay()
    }

    private func commitDraftDrag(from start: CGPoint, to end: CGPoint) {
        guard abs(end.x - start.x) > Self.minimumDraftDragSize
            || abs(end.y - start.y) > Self.minimumDraftDragSize
        else { return }
        guard let item = draftItem(tool: activeTool, from: start, to: end) else { return }
        draft.items.append(item)
    }

    private func draftItem(tool: AnnotationTool, from start: CGPoint, to end: CGPoint) -> AnnotationDraftItem? {
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        switch tool {
        case .arrow:
            return .arrow(start: globalPoint(start), end: globalPoint(end), color: style.color, strokeWidth: style.strokeWidth)
        case .highlight:
            return .highlight(rect: globalRect(rect), color: style.color, amount: style.opacity)
        case .blur:
            return .blur(rect: globalRect(rect), color: style.color, amount: style.blurRadius)
        case .rect:
            return .shape(kind: .rect, rect: globalRect(rect), color: style.color, strokeWidth: style.strokeWidth)
        case .ellipse:
            return .shape(kind: .ellipse, rect: globalRect(rect), color: style.color, strokeWidth: style.strokeWidth)
        default:
            return nil
        }
    }

    private func undoLastDraftItem() {
        guard !draft.items.isEmpty else { return }
        draft.items.removeLast()
        updateDisplay()
    }

    private func drawDraftItems(clippingTo selection: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var items = draft.items
        if let start = draftDragStart, let current = draftDragCurrent,
           let previewItem = draftItem(tool: activeTool, from: start, to: current) {
            items.append(previewItem)
        }
        guard !items.isEmpty else { return }
        let globalSelection = AreaSelection(localRect: selection, display: display).rect
        let renderer = AnnotationRenderer()
        for item in items {
            context.saveGState()
            let isRetained = OverlayAnnotationConversion.isRetained(item, in: globalSelection)
            context.setAlpha(isRetained ? 1 : 0.35)
            try? renderer.drawDraft(
                [item],
                in: context,
                origin: display.frame.origin,
                scale: 1,
                canvasBounds: globalRect(bounds),
                source: snapshot
            )
            context.restoreGState()
        }
    }

    // MARK: - Text/emoji field editor

    private func beginFieldEditor(at point: CGPoint, tool: AnnotationTool) {
        cancelFieldEditor()
        let isMultiline = tool == .text
        let width: CGFloat = tool == .emoji ? 90 : 220
        let height: CGFloat = tool == .emoji ? 56 : 30
        var frame = CGRect(x: point.x, y: point.y - height / 2, width: width, height: height)
        if isMultiline {
            frame = clampFieldFrameToSelection(frame)
        }
        let field = NSTextField(frame: frame)
        field.font = .systemFont(ofSize: tool == .emoji ? 40 : 18)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.backgroundColor = .white
        field.textColor = style.color.nsColor
        field.usesSingleLineMode = !isMultiline
        if isMultiline {
            field.cell?.wraps = true
            field.cell?.isScrollable = false
        }
        field.delegate = self
        field.stringValue = tool == .emoji ? style.emoji : ""
        addSubview(field)
        window?.makeFirstResponder(field)
        fieldEditor = field
        fieldEditorTool = tool
        fieldUserSized = false
        if isMultiline {
            installFieldHandles()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // The `.emoji` field stays single-shot (PLAN.md "Text Input" — out of scope): Enter
        // commits, Esc discards, exactly as before this change. Only `.text` gets the new
        // multiline/asymmetric-newline/Esc-commits contract via the shared `TextInputKeyDecision`
        // seam.
        guard fieldEditorTool == .text else {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                commitFieldEditor()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancelFieldEditor()
                return true
            }
            return false
        }
        switch TextInputKeyDecision.action(
            for: commandSelector,
            commandModifier: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        ) {
        case .insertNewline:
            // Returning `true` here (without also inserting) would let the field editor's default
            // Return END editing — `insertNewlineIgnoringFieldEditor` inserts the newline while
            // keeping the field editor session alive.
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case .commit:
            commitFieldEditor()
            return true
        case .pass:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = fieldEditor, fieldEditorTool == .text, !fieldUserSized else { return }
        let measuringBounds = CGRect(x: 0, y: 0, width: field.frame.width, height: .greatestFiniteMagnitude)
        let measured = field.cell?.cellSize(forBounds: measuringBounds) ?? field.frame.size
        let newHeight = max(minimumFieldTextSize.height, measured.height)
        guard newHeight != field.frame.height else { return }
        var frame = field.frame
        let topEdge = frame.maxY
        frame.size.height = newHeight
        frame.origin.y = topEdge - newHeight
        field.frame = clampFieldFrameToSelection(frame)
        repositionFieldHandles()
        updateDisplay()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitFieldEditor()
    }

    private func commitFieldEditor() {
        guard let field = fieldEditor, let tool = fieldEditorTool else { return }
        fieldEditor = nil
        fieldEditorTool = nil
        fieldUserSized = false
        removeFieldHandles()
        // Trim ONLY for the emptiness check — the committed annotation stores the ORIGINAL,
        // untrimmed string (PLAN.md "Text Input").
        let text = field.stringValue
        // `field.frame` directly — NOT a reconstruction from the original click point, otherwise a
        // dragged/resized field would persist its pre-resize position/size instead of what's
        // actually on screen.
        let bounds = field.frame
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let fontSize = tool == .emoji ? AnnotationStyle.emojiFontSize : style.fontSize
        draft.items.append(.text(bounds: globalRect(bounds), text: text, fontSize: fontSize, color: style.color))
        updateDisplay()
    }

    private func cancelFieldEditor() {
        guard let field = fieldEditor else { return }
        fieldEditor = nil
        fieldEditorTool = nil
        fieldUserSized = false
        removeFieldHandles()
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    // MARK: - Text field resize handles (PLAN.md "Text Input")

    private func installFieldHandles() {
        fieldHandles = SelectionHandle.allCases.map { handle in
            let view = FieldResizeHandleView(handle: handle)
            view.onDrag = { [weak self] handle, point in
                self?.resizeFieldEditor(handle: handle, to: point)
            }
            addSubview(view)
            return view
        }
        repositionFieldHandles()
    }

    private func repositionFieldHandles() {
        guard let field = fieldEditor else { return }
        let size: CGFloat = 10
        for handleView in fieldHandles {
            let point = handleView.handle.point(in: field.frame)
            handleView.frame = CGRect(
                x: point.x - size / 2,
                y: point.y - size / 2,
                width: size,
                height: size
            )
        }
    }

    private func removeFieldHandles() {
        fieldHandles.forEach { $0.removeFromSuperview() }
        fieldHandles = []
    }

    private func resizeFieldEditor(handle: SelectionHandle, to point: CGPoint) {
        guard let field = fieldEditor, fieldEditorTool == .text else { return }
        let clampedPoint = Self.clampFieldResizePoint(
            point,
            handle: handle,
            in: field.frame,
            minSize: minimumFieldTextSize
        )
        let resized = handle.resized(field.frame, to: clampedPoint)
        field.frame = clampFieldFrameToSelection(resized)
        fieldUserSized = true
        repositionFieldHandles()
        updateDisplay()
    }

    /// Clamps a handle drag point so the resulting frame can never shrink below `minSize` on the
    /// axis/axes that `handle` controls, by capping the point relative to the frame's opposite
    /// (fixed) edge — the overlay-side mirror of `AnnotationEditorState`'s
    /// `clampResizePoint`, working in AppKit's y-up display points instead of normalized space.
    private static func clampFieldResizePoint(
        _ point: CGPoint,
        handle: SelectionHandle,
        in rect: CGRect,
        minSize: CGSize
    ) -> CGPoint {
        var x = point.x
        var y = point.y
        switch handle {
        case .topLeft, .left, .bottomLeft:
            x = min(x, rect.maxX - minSize.width)
        case .topRight, .right, .bottomRight:
            x = max(x, rect.minX + minSize.width)
        case .top, .bottom:
            break
        }
        switch handle {
        case .topLeft, .top, .topRight:
            y = max(y, rect.minY + minSize.height)
        case .bottomLeft, .bottom, .bottomRight:
            y = min(y, rect.maxY - minSize.height)
        case .left, .right:
            break
        }
        return CGPoint(x: x, y: y)
    }

    /// Clamps the whole field frame to stay fully inside the committed selection rect (PLAN.md
    /// "Text Input") — otherwise `OverlayAnnotationConversion`'s fully-inside rule silently drops
    /// the annotation at Confirm. Applied to the initial frame, every auto-grow, and every handle
    /// resize. A no-op (returns `rect` unchanged) if there's no committed selection yet, which
    /// never happens in practice since the text tool only fires once a selection is committed.
    private func clampFieldFrameToSelection(_ rect: CGRect) -> CGRect {
        guard let selection = committedRect else { return rect }
        return CaptureGeometry.clamp(rect, to: selection)
    }

    // MARK: - Toolbar (PLAN.md §8)

    private func updateToolbar() {
        guard allowsQuickAnnotation, !isInert, let rect = committedRect else {
            removeToolbar()
            return
        }
        let content = SelectionOverlayToolbarView(
            activeTool: activeTool,
            colorID: style.colorID,
            selectedEmoji: style.emoji,
            isCancelArmed: isCancelArmed,
            onSelectTool: { [weak self] tool in
                self?.activeTool = tool
                self?.updateDisplay()
            },
            onSelectColor: { [weak self] option in
                self?.style.color = option.color
                self?.updateDisplay()
            },
            onSelectEmoji: { [weak self] emoji in
                self?.style.emoji = emoji
                self?.updateDisplay()
            },
            onUndo: { [weak self] in self?.undoLastDraftItem() },
            onCancel: { [weak self] in self?.requestCancel() },
            onConfirm: { [weak self] in
                guard let self, let rect = self.committedRect else { return }
                self.confirm(rect)
            }
        )
        let host: NSHostingView<SelectionOverlayToolbarView>
        if let existing = toolbarHost {
            existing.rootView = content
            host = existing
        } else {
            host = NSHostingView(rootView: content)
            addSubview(host)
            toolbarHost = host
        }
        host.layoutSubtreeIfNeeded()
        let measuredSize = host.fittingSize
        host.frame = SelectionToolbarPlacement.toolbarFrame(
            selection: rect,
            toolbarSize: measuredSize,
            visibleBounds: bounds
        )
    }

    private func removeToolbar() {
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil
    }

    private func drawInstructions() {
        if isCancelArmed {
            drawBadge(
                "Discard this screenshot?   Esc or ✕ again to discard   |   anything else keeps it",
                at: CGPoint(x: bounds.midX, y: bounds.maxY - 76),
                background: NSColor.systemRed,
                foreground: .white
            )
            return
        }
        let message = committedRect != nil
            ? "Drag handles to resize   |   1-9: tools   |   Return or double-click: capture   |   Esc twice: cancel"
            : "Drag to capture a slice   |   Return: whole screen   |   Esc: cancel"
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
        NSColor.systemBlue.setFill()
        for handle in SelectionHandle.allCases {
            let point = handle.point(in: selection)
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
        let message = committedRect != nil ? "Return or double-click to capture" : "Release to adjust"
        drawBadge(
            message,
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

/// One of the 8 dedicated resize-handle subviews for the Selection Overlay's text field editor
/// (PLAN.md "Text Input") — owns its own mouse handling directly (rather than depending on the
/// parent view's `mouseDown`, which the field subview otherwise swallows clicks within its own
/// frame for) so a drag starting on a handle is never mistaken for the parent's
/// any-mouseDown-commits click-outside path.
final class FieldResizeHandleView: NSView {
    let handle: SelectionHandle
    /// `point` is in the parent `SelectionOverlayView`'s local coordinate space.
    var onDrag: ((SelectionHandle, CGPoint) -> Void)?

    init(handle: SelectionHandle) {
        self.handle = handle
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.cgColor
        layer?.cornerRadius = 4
        layer?.borderColor = NSColor.white.cgColor
        layer?.borderWidth = 1.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FieldResizeHandleView does not support NSCoding")
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        onDrag?(handle, point)
    }
}

private extension AnnotationStyle {
    /// The palette swatch id matching `color`, for driving the overlay toolbar's selection ring.
    var colorID: String {
        AnnotationPalette.options.first(where: { $0.color == color })?.id ?? AnnotationPalette.options[0].id
    }
}

private extension SelectionHandle {
    /// AppKit has no public diagonal-resize cursor, so corners fall back to crosshair.
    var cursor: NSCursor {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return .crosshair
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        }
    }
}

#endif
