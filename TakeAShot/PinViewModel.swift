import AppKit
import CoreGraphics
import Foundation

struct PinRenderRequest: @unchecked Sendable {
    let capture: CapturedImage
    let document: AnnotationDocument
    let pixelSize: CGSize
    let appliesCrop: Bool
}

protocol PinRendering: Sendable {
    func render(_ request: PinRenderRequest) async throws -> PinSurface
}

protocol PinLibraryServing: Sendable {
    func record(id: UUID) async throws -> CaptureRecord?
    func loadCapture(id: UUID) async throws -> CapturedImage
    func loadAnnotations(id: UUID) async throws -> AnnotationDocument
    func originalURL(id: UUID) async throws -> URL
}

enum PinPersistedUpdate: Sendable {
    case image
    case annotations
    case tags
    case ocr
}

enum PinRenderingError: Error, Equatable {
    case invalidPanelSize
}

struct PinCompositingRenderer: PinRendering {
    private let annotationRenderer: any AnnotationRenderServicing

    init(annotationRenderer: any AnnotationRenderServicing = DetachedAnnotationRenderService()) {
        self.annotationRenderer = annotationRenderer
    }

    func render(_ request: PinRenderRequest) async throws -> PinSurface {
        let composited = try await annotationRenderer.render(
            capture: request.capture,
            document: request.document
        )
        let maxPixelSize = max(1, Int(max(request.pixelSize.width, request.pixelSize.height)))
        let image = try await Task.detached(priority: .userInitiated) {
            try ImageExporter.thumbnail(for: composited, maxPixelSize: maxPixelSize)
        }.value
        return PinSurface(
            image: image,
            logicalSize: request.pixelSize,
            byteCost: image.bytesPerRow * image.height
        )
    }
}

@MainActor
protocol PinLinkOpening: AnyObject {
    func open(_ url: URL)
}

@MainActor
final class WorkspacePinLinkOpener: PinLinkOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

actor PinViewModel {
    private struct RenderRequest {
        let panelSize: CGSize
        let backingScale: CGFloat
    }

    private struct RenderJob {
        let request: RenderRequest
        let generation: UInt64
        let requestGeneration: UInt64
        var continuations: [CheckedContinuation<Void, Error>]
    }

    private let pin: PinnedReference
    private let library: any PinLibraryServing
    private let renderer: any PinRendering
    private let cache: PinSurfaceCache
    private let onRequestQueued: (@Sendable () -> Void)?
    private var pendingJob: RenderJob?
    private var isProcessing = false
    private var invalidationGeneration: UInt64 = 0
    private var latestRequestGeneration: UInt64 = 0
    private var latestRequest: RenderRequest?
    private var completedReplacement: (generation: UInt64, requestGeneration: UInt64)?
    private(set) var surface: PinSurface?

    init(
        pin: PinnedReference,
        library: any PinLibraryServing,
        renderer: any PinRendering = PinCompositingRenderer(),
        cache: PinSurfaceCache = PinSurfaceCache(),
        onRequestQueued: (@Sendable () -> Void)? = nil
    ) {
        self.pin = pin
        self.library = library
        self.renderer = renderer
        self.cache = cache
        self.onRequestQueued = onRequestQueued
    }

    init(
        pin: PinnedReference,
        library: any AppLibraryServing,
        renderer: any PinRendering = PinCompositingRenderer(),
        cache: PinSurfaceCache = PinSurfaceCache(),
        onRequestQueued: (@Sendable () -> Void)? = nil
    ) {
        self.init(
            pin: pin,
            library: AppLibraryPinLibrary(library: library),
            renderer: renderer,
            cache: cache,
            onRequestQueued: onRequestQueued
        )
    }

    func loadSurface(panelSize: CGSize, backingScale: CGFloat) async throws {
        guard panelSize.width > 0, panelSize.height > 0, backingScale > 0 else {
            throw PinRenderingError.invalidPanelSize
        }
        let request = RenderRequest(panelSize: panelSize, backingScale: backingScale)
        latestRequestGeneration &+= 1
        latestRequest = request
        let key = cacheKey(for: request, generation: invalidationGeneration)
        if let cached = await cache.surface(for: key) {
            surface = cached
            completedReplacement = (
                generation: invalidationGeneration,
                requestGeneration: latestRequestGeneration
            )
            return
        }
        completedReplacement = nil
        try await withCheckedThrowingContinuation { continuation in
            enqueue(
                RenderJob(
                    request: request,
                    generation: invalidationGeneration,
                    requestGeneration: latestRequestGeneration,
                    continuations: [continuation]
                )
            )
            onRequestQueued?()
        }
    }

    func updatePriority(_ priority: PinSurfacePriority) async {
        await cache.updatePriority(priority, for: pin.id)
    }

    func handlePersistedUpdate(_ update: PinPersistedUpdate) async {
        guard update == .image || update == .annotations else { return }
        invalidationGeneration &+= 1
        surface = nil
        completedReplacement = nil
        await cache.remove(pinID: pin.id)
        guard isProcessing, let latestRequest else { return }
        let continuations = pendingJob?.continuations ?? []
        pendingJob = RenderJob(
            request: latestRequest,
            generation: invalidationGeneration,
            requestGeneration: latestRequestGeneration,
            continuations: continuations
        )
    }

    func copyImage(using exporter: any AppCaptureExporting) async throws {
        async let capture = library.loadCapture(id: pin.captureID)
        async let document = library.loadAnnotations(id: pin.captureID)
        try await exporter.copy(capture: capture, document: document)
    }

    func ocrText() async throws -> String {
        try await library.record(id: pin.captureID)?.ocrText ?? ""
    }

    func detectedLinks(in text: String) -> [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range).compactMap(\.url).filter {
            $0.scheme == "http" || $0.scheme == "https"
        } ?? []
    }

    func openDetectedLink(_ url: URL, using opener: any PinLinkOpening) async {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        await MainActor.run { opener.open(url) }
    }

    private func enqueue(_ job: RenderJob) {
        if var pendingJob {
            pendingJob.continuations.append(contentsOf: job.continuations)
            self.pendingJob = RenderJob(
                request: job.request,
                generation: job.generation,
                requestGeneration: job.requestGeneration,
                continuations: pendingJob.continuations
            )
        } else {
            pendingJob = job
        }
        guard !isProcessing else { return }
        isProcessing = true
        Task { await processJobs() }
    }

    private func processJobs() async {
        while let job = pendingJob {
            pendingJob = nil
            do {
                async let capture = library.loadCapture(id: pin.captureID)
                async let document = library.loadAnnotations(id: pin.captureID)
                let request = PinRenderRequest(
                    capture: try await capture,
                    document: try await document,
                    pixelSize: pixelSize(for: job.request.panelSize, backingScale: job.request.backingScale),
                    appliesCrop: true
                )
                let rendered = try await renderer.render(request)
                if job.generation == invalidationGeneration,
                   job.requestGeneration == latestRequestGeneration {
                    let renderedSurface = PinSurface(
                        image: rendered.image,
                        logicalSize: job.request.panelSize,
                        byteCost: rendered.byteCost
                    )
                    surface = renderedSurface
                    await cache.insert(
                        renderedSurface,
                        for: cacheKey(for: job.request, generation: job.generation),
                        priority: .visible
                    )
                }
                resumeOrTransfer(job.continuations, for: job)
            } catch {
                if !transferContinuationsToReplacement(job.continuations, for: job) {
                    job.continuations.forEach { $0.resume(throwing: error) }
                }
            }
        }
        isProcessing = false
    }

    private func pixelSize(for panelSize: CGSize, backingScale: CGFloat) -> CGSize {
        let scaled = CGSize(
            width: ceil(panelSize.width * backingScale),
            height: ceil(panelSize.height * backingScale)
        )
        let longestEdge = max(scaled.width, scaled.height)
        guard longestEdge > 4_096 else { return scaled }
        let factor = 4_096 / longestEdge
        return CGSize(width: floor(scaled.width * factor), height: floor(scaled.height * factor))
    }

    private func cacheKey(for request: RenderRequest, generation: UInt64) -> PinSurfaceCacheKey {
        PinSurfaceCacheKey(
            pinID: pin.id,
            logicalSize: request.panelSize,
            backingScale: request.backingScale,
            compositionRevision: generation
        )
    }

    private func resumeOrTransfer(
        _ continuations: [CheckedContinuation<Void, Error>],
        for job: RenderJob
    ) {
        if !transferContinuationsToReplacement(continuations, for: job) {
            continuations.forEach { $0.resume() }
        }
    }

    private func transferContinuationsToReplacement(
        _ continuations: [CheckedContinuation<Void, Error>],
        for job: RenderJob
    ) -> Bool {
        guard job.generation != invalidationGeneration || job.requestGeneration != latestRequestGeneration else {
            return false
        }
        if var replacement = pendingJob {
            replacement.continuations.append(contentsOf: continuations)
            pendingJob = replacement
            return true
        }
        guard completedReplacement?.generation == invalidationGeneration,
              completedReplacement?.requestGeneration == latestRequestGeneration else {
            return false
        }
        continuations.forEach { $0.resume() }
        return true
    }
}

private struct AppLibraryPinLibrary: PinLibraryServing {
    let library: any AppLibraryServing

    func record(id: UUID) async throws -> CaptureRecord? {
        try await library.load(matching: "").first(where: { $0.id == id })
    }

    func loadCapture(id: UUID) async throws -> CapturedImage {
        try await library.loadCapture(id: id)
    }

    func loadAnnotations(id: UUID) async throws -> AnnotationDocument {
        try await library.loadAnnotations(for: id)
    }

    func originalURL(id: UUID) async throws -> URL {
        try await library.originalURL(for: id)
    }
}
