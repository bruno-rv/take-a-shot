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
        var continuations: [RenderContinuation]
        var isReady: Bool
        var lookupOwnerID: UInt64?
    }

    private struct RenderContinuation {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let pin: PinnedReference
    private let library: any PinLibraryServing
    private let renderer: any PinRendering
    private let cache: PinSurfaceCache
    private let onRequestQueued: (@Sendable () -> Void)?
    private let afterCacheLookup: (@Sendable () async -> Void)?
    private var pendingJob: RenderJob?
    private var activeJob: RenderJob?
    private var isProcessing = false
    private var invalidationGeneration: UInt64 = 0
    private var latestRequestGeneration: UInt64 = 0
    private var nextContinuationID: UInt64 = 0
    private var latestRequest: RenderRequest?
    private var completedReplacement: (generation: UInt64, requestGeneration: UInt64)?
    private(set) var surface: PinSurface?

    init(
        pin: PinnedReference,
        library: any PinLibraryServing,
        renderer: any PinRendering = PinCompositingRenderer(),
        cache: PinSurfaceCache = PinSurfaceCache(),
        onRequestQueued: (@Sendable () -> Void)? = nil,
        afterCacheLookup: (@Sendable () async -> Void)? = nil
    ) {
        self.pin = pin
        self.library = library
        self.renderer = renderer
        self.cache = cache
        self.onRequestQueued = onRequestQueued
        self.afterCacheLookup = afterCacheLookup
    }

    init(
        pin: PinnedReference,
        library: any AppLibraryServing,
        renderer: any PinRendering = PinCompositingRenderer(),
        cache: PinSurfaceCache = PinSurfaceCache(),
        onRequestQueued: (@Sendable () -> Void)? = nil,
        afterCacheLookup: (@Sendable () async -> Void)? = nil
    ) {
        self.init(
            pin: pin,
            library: AppLibraryPinLibrary(library: library),
            renderer: renderer,
            cache: cache,
            onRequestQueued: onRequestQueued,
            afterCacheLookup: afterCacheLookup
        )
    }

    func loadSurface(panelSize: CGSize, backingScale: CGFloat) async throws {
        guard panelSize.width > 0, panelSize.height > 0, backingScale > 0 else {
            throw PinRenderingError.invalidPanelSize
        }
        try Task.checkCancellation()
        let request = RenderRequest(panelSize: panelSize, backingScale: backingScale)
        latestRequestGeneration &+= 1
        latestRequest = request
        let generation = invalidationGeneration
        let requestGeneration = latestRequestGeneration
        nextContinuationID &+= 1
        let continuationID = nextContinuationID
        try await withTaskCancellationHandler(operation: {
            installReplacement(
                request: request,
                generation: generation,
                requestGeneration: requestGeneration,
                lookupOwnerID: continuationID
            )
            let key = cacheKey(for: request, generation: generation)
            let cached = await cache.surface(for: key)
            try throwIfCancelledAfterCacheLookup(
                cached,
                generation: generation,
                requestGeneration: requestGeneration
            )
            await afterCacheLookup?()
            try throwIfCancelledAfterCacheLookup(
                cached,
                generation: generation,
                requestGeneration: requestGeneration
            )
            if let cached,
               generation == invalidationGeneration,
               requestGeneration == latestRequestGeneration {
                surface = cached
                completePendingJobFromCacheHit()
                return
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    completeCancelledCacheLookup(
                        cached,
                        generation: generation,
                        requestGeneration: requestGeneration
                    )
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueueContinuation(
                    .init(id: continuationID, continuation: continuation),
                    for: RenderJob(
                        request: request,
                        generation: generation,
                        requestGeneration: requestGeneration,
                        continuations: [],
                        isReady: true,
                        lookupOwnerID: nil
                    )
                )
            }
        }, onCancel: {
            Task { await self.cancelContinuation(id: continuationID) }
        })
    }

    func updatePriority(_ priority: PinSurfacePriority) async {
        await cache.updatePriority(priority, for: pin.id)
    }

    func handlePersistedUpdate(_ update: PinPersistedUpdate) async {
        guard update == .image || update == .annotations else { return }
        invalidationGeneration &+= 1
        surface = nil
        completedReplacement = nil
        guard (isProcessing || pendingJob != nil), let latestRequest else {
            await cache.remove(pinID: pin.id)
            return
        }
        let generation = invalidationGeneration
        let requestGeneration = latestRequestGeneration
        installReplacement(
            request: latestRequest,
            generation: generation,
            requestGeneration: requestGeneration
        )
        await cache.remove(pinID: pin.id)
        markReplacementReady(generation: generation, requestGeneration: requestGeneration)
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

    private func installReplacement(
        request: RenderRequest,
        generation: UInt64,
        requestGeneration: UInt64,
        lookupOwnerID: UInt64? = nil
    ) {
        pendingJob = RenderJob(
            request: request,
            generation: generation,
            requestGeneration: requestGeneration,
            continuations: pendingJob?.continuations ?? [],
            isReady: false,
            lookupOwnerID: lookupOwnerID
        )
    }

    private func enqueueContinuation(
        _ continuation: RenderContinuation,
        for job: RenderJob
    ) {
        if var pendingJob {
            if pendingJob.lookupOwnerID == continuation.id {
                pendingJob.lookupOwnerID = nil
            }
            pendingJob.continuations.append(continuation)
            if pendingJob.generation == job.generation,
               pendingJob.requestGeneration == job.requestGeneration {
                pendingJob.isReady = true
                onRequestQueued?()
            }
            self.pendingJob = pendingJob
        } else if completedReplacement?.generation == invalidationGeneration,
                  completedReplacement?.requestGeneration == latestRequestGeneration {
            continuation.continuation.resume()
            return
        } else {
            pendingJob = job
            onRequestQueued?()
        }
        startProcessingIfNeeded()
    }

    private func markReplacementReady(generation: UInt64, requestGeneration: UInt64) {
        guard var pendingJob,
              pendingJob.generation == generation,
              pendingJob.requestGeneration == requestGeneration else {
            return
        }
        pendingJob.isReady = true
        self.pendingJob = pendingJob
        startProcessingIfNeeded()
    }

    private func startProcessingIfNeeded() {
        guard !isProcessing, pendingJob?.isReady == true else { return }
        isProcessing = true
        Task { await processJobs() }
    }

    private func processJobs() async {
        while let job = pendingJob, job.isReady {
            pendingJob = nil
            activeJob = job
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
                if isLatest(job) {
                    let renderedSurface = PinSurface(
                        image: rendered.image,
                        logicalSize: job.request.panelSize,
                        byteCost: rendered.byteCost
                    )
                    await cache.insert(
                        renderedSurface,
                        for: cacheKey(for: job.request, generation: job.generation),
                        priority: .visible
                    )
                    if isLatest(job) {
                        surface = renderedSurface
                    }
                }
                resumeOrTransfer(finishActiveJob(), for: job)
            } catch {
                let continuations = finishActiveJob()
                if !transferContinuationsToReplacement(continuations, for: job) {
                    continuations.forEach { $0.continuation.resume(throwing: error) }
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

    private func isLatest(_ job: RenderJob) -> Bool {
        job.generation == invalidationGeneration &&
        job.requestGeneration == latestRequestGeneration
    }

    private func resumeOrTransfer(
        _ continuations: [RenderContinuation],
        for job: RenderJob
    ) {
        if !transferContinuationsToReplacement(continuations, for: job) {
            continuations.forEach { $0.continuation.resume() }
        }
    }

    private func transferContinuationsToReplacement(
        _ continuations: [RenderContinuation],
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
        completedReplacement = nil
        continuations.forEach { $0.continuation.resume() }
        return true
    }

    private func completePendingJobFromCacheHit() {
        let terminalReplacement = (
            generation: invalidationGeneration,
            requestGeneration: latestRequestGeneration
        )
        completedReplacement = terminalReplacement
        guard let pendingJob else { return }
        self.pendingJob = nil
        pendingJob.continuations.forEach { $0.continuation.resume() }
    }

    private func completeCancelledCacheLookup(
        _ cached: PinSurface?,
        generation: UInt64,
        requestGeneration: UInt64
    ) {
        guard var pendingJob,
              pendingJob.generation == generation,
              pendingJob.requestGeneration == requestGeneration else {
            return
        }
        guard !pendingJob.continuations.isEmpty else {
            self.pendingJob = nil
            return
        }
        self.pendingJob = pendingJob
        if let cached {
            surface = cached
            completePendingJobFromCacheHit()
        } else {
            pendingJob.isReady = true
            self.pendingJob = pendingJob
            startProcessingIfNeeded()
        }
    }

    private func throwIfCancelledAfterCacheLookup(
        _ cached: PinSurface?,
        generation: UInt64,
        requestGeneration: UInt64
    ) throws {
        guard Task.isCancelled else { return }
        completeCancelledCacheLookup(
            cached,
            generation: generation,
            requestGeneration: requestGeneration
        )
        throw CancellationError()
    }

    private func finishActiveJob() -> [RenderContinuation] {
        defer { activeJob = nil }
        return activeJob?.continuations ?? []
    }

    private func cancelContinuation(id: UInt64) {
        if var activeJob,
           let continuation = removeContinuation(id: id, from: &activeJob) {
            self.activeJob = activeJob
            continuation.continuation.resume(throwing: CancellationError())
            return
        }
        if var pendingJob,
           let continuation = removeContinuation(id: id, from: &pendingJob) {
            self.pendingJob = pendingJob
            continuation.continuation.resume(throwing: CancellationError())
            return
        }
        if var pendingJob, pendingJob.lookupOwnerID == id {
            pendingJob.lookupOwnerID = nil
            self.pendingJob = pendingJob
        }
    }

    private func removeContinuation(
        id: UInt64,
        from job: inout RenderJob
    ) -> RenderContinuation? {
        guard let index = job.continuations.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return job.continuations.remove(at: index)
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
