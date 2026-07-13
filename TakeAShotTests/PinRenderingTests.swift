import AppKit
import XCTest
@testable import TakeAShot

final class PinRenderingTests: XCTestCase {
    func testRendererAppliesPersistedCropAndAnnotationsOffMainActor() async throws {
        let capture = try makeCapture(width: 1_200, height: 800)
        let library = StubPinLibrary(
            capture: capture,
            annotations: AnnotationDocument(
                captureID: capture.id,
                items: [.text(.init(
                    id: UUID(),
                    bounds: .init(x: 0.1, y: 0.1, width: 0.4, height: 0.2),
                    text: "Pin",
                    fontSize: 24,
                    color: .red
                ))],
                cropRect: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            )
        )
        let renderer = InspectingPinRenderer()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: library,
            renderer: renderer,
            cache: PinSurfaceCache(byteLimit: 256 * 1_024 * 1_024)
        )

        try await viewModel.loadSurface(
            panelSize: CGSize(width: 3_000, height: 2_000),
            backingScale: 2
        )

        let lastRequest = await renderer.lastRequest
        let request = try XCTUnwrap(lastRequest)
        XCTAssertTrue(request.appliesCrop)
        let executedOnMainThread = await renderer.executedOnMainThread
        XCTAssertFalse(executedOnMainThread)
        XCTAssertLessThanOrEqual(max(request.pixelSize.width, request.pixelSize.height), 4_096)
    }

    func testDefaultRendererCompositesAnnotationsBeforeApplyingCrop() async throws {
        let capture = try makeCapture(width: 100, height: 100)
        let document = AnnotationDocument(
            captureID: capture.id,
            items: [.highlight(.init(
                id: UUID(),
                rect: .init(x: 0.3, y: 0.3, width: 0.2, height: 0.2),
                color: .red,
                amount: 1
            ))],
            cropRect: .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )

        let surface = try await PinCompositingRenderer().render(
            .init(capture: capture, document: document, pixelSize: CGSize(width: 100, height: 100), appliesCrop: true)
        )

        XCTAssertEqual(surface.image.width, 50)
        XCTAssertEqual(surface.image.height, 50)
        let center = try TestImage.pixelColor(in: surface.image, x: 15, y: 15)
        XCTAssertGreaterThan(center.redComponent, center.greenComponent)
    }

    func testCacheEvictsHiddenAndCollapsedBeforeVisibleSurfaces() async throws {
        let cache = PinSurfaceCache(byteLimit: 100)
        await cache.insert(try makeSurface(bytes: 60), for: UUID(), priority: .visible)
        let hiddenID = UUID()
        await cache.insert(try makeSurface(bytes: 40), for: hiddenID, priority: .hidden)
        await cache.insert(try makeSurface(bytes: 40), for: UUID(), priority: .visible)

        let hiddenSurface = await cache.surface(for: hiddenID)
        let totalBytes = await cache.totalBytes
        XCTAssertNil(hiddenSurface)
        XCTAssertLessThanOrEqual(totalBytes, 100)
    }

    func testRapidResizeSerializesRenderingAndPublishesLatestSurface() async throws {
        let capture = try makeCapture()
        let renderer = GatedPinRenderer()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: PinSurfaceCache()
        )

        let first = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 300, height: 200), backingScale: 2)
        }
        await renderer.waitUntilStarted(count: 1)
        let second = Task {
            try await viewModel.loadSurface(
                panelSize: CGSize(width: 600, height: 400), backingScale: 2
            )
        }
        await renderer.releaseNext()
        await renderer.waitUntilStarted(count: 2)
        await renderer.releaseNext()
        try await first.value
        try await second.value

        let maximumConcurrentCount = await renderer.maximumConcurrentCount
        let surface = await viewModel.surface
        XCTAssertEqual(maximumConcurrentCount, 1)
        XCTAssertEqual(surface?.logicalSize, CGSize(width: 600, height: 400))
    }

    func testSamePointSizeAtDifferentBackingScaleRerendersInsteadOfUsingCachedSurface() async throws {
        let capture = try makeCapture()
        let renderer = InspectingPinRenderer()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: PinSurfaceCache()
        )

        try await viewModel.loadSurface(panelSize: CGSize(width: 100, height: 50), backingScale: 1)
        try await viewModel.loadSurface(panelSize: CGSize(width: 100, height: 50), backingScale: 2)

        let requestCount = await renderer.requestCount
        let pixelSize = await renderer.lastRequest?.pixelSize
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(pixelSize, CGSize(width: 200, height: 100))
    }

    func testAnnotationUpdateRerendersSameSizeInsteadOfUsingPriorComposition() async throws {
        let capture = try makeCapture()
        let renderer = InspectingPinRenderer()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: PinSurfaceCache()
        )

        try await viewModel.loadSurface(panelSize: CGSize(width: 100, height: 50), backingScale: 2)
        await viewModel.handlePersistedUpdate(.annotations)
        try await viewModel.loadSurface(panelSize: CGSize(width: 100, height: 50), backingScale: 2)

        let requestCount = await renderer.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testQueuedNewerResizePreventsFirstSurfaceFromPublishing() async throws {
        let capture = try makeCapture()
        let renderer = GatedPinRenderer()
        let queueSignal = RequestQueueSignal()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: PinSurfaceCache(),
            onRequestQueued: { Task { await queueSignal.recordRequest() } }
        )

        let first = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 300, height: 200), backingScale: 1)
        }
        await renderer.waitUntilStarted(count: 1)
        let second = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 600, height: 400), backingScale: 1)
        }
        await queueSignal.waitUntilRequestsQueued(count: 2)

        await renderer.releaseNext()
        await renderer.waitUntilStarted(count: 2)
        let surfaceBeforeSecondCompletion = await viewModel.surface
        XCTAssertNil(surfaceBeforeSecondCompletion)

        await renderer.releaseNext()
        try await first.value
        try await second.value
        let surface = await viewModel.surface
        XCTAssertEqual(surface?.logicalSize, CGSize(width: 600, height: 400))
    }

    func testNewerCacheLookupKeepsActiveCallerSuspendedUntilReplacementRenders() async throws {
        let capture = try makeCapture()
        let lookupGate = CacheOperationGate()
        let renderer = GatedPinRenderer()
        let completion = CallerCompletionSignal()
        completion.expectation.isInverted = true
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: PinSurfaceCache(beforeSurfaceLookup: { await lookupGate.pauseIfArmed() })
        )

        let first = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 300, height: 200), backingScale: 1)
            await completion.recordCompletion()
        }
        await renderer.waitUntilStarted(count: 1)
        await lookupGate.arm()
        let second = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 600, height: 400), backingScale: 1)
        }
        await lookupGate.waitUntilPaused()

        await renderer.releaseNext()
        await renderer.waitUntilFinished(count: 1)
        await fulfillment(of: [completion.expectation], timeout: 0.1)

        await lookupGate.release()
        await renderer.waitUntilStarted(count: 2)
        await renderer.releaseNext()
        try await first.value
        try await second.value
        let surface = await viewModel.surface
        XCTAssertEqual(surface?.logicalSize, CGSize(width: 600, height: 400))
    }

    func testInvalidationEvictionKeepsActiveCallerSuspendedUntilReplacementRenders() async throws {
        let capture = try makeCapture()
        let evictionGate = CacheOperationGate()
        let renderer = GatedPinRenderer()
        let completion = CallerCompletionSignal()
        completion.expectation.isInverted = true
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: PinSurfaceCache(beforeRemove: { await evictionGate.pauseIfArmed() })
        )

        let first = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 300, height: 200), backingScale: 1)
            await completion.recordCompletion()
        }
        await renderer.waitUntilStarted(count: 1)
        await evictionGate.arm()
        let invalidation = Task { await viewModel.handlePersistedUpdate(PinPersistedUpdate.annotations) }
        await evictionGate.waitUntilPaused()

        await renderer.releaseNext()
        await renderer.waitUntilFinished(count: 1)
        await fulfillment(of: [completion.expectation], timeout: 0.1)

        await evictionGate.release()
        await invalidation.value
        await renderer.waitUntilStarted(count: 2)
        await renderer.releaseNext()
        try await first.value
        let surface = await viewModel.surface
        XCTAssertEqual(surface?.logicalSize, CGSize(width: 300, height: 200))
    }

    func testSupersededRenderKeepsOriginalCallerSuspendedUntilLatestSurfaceCompletes() async throws {
        let capture = try makeCapture()
        let renderer = GatedPinRenderer()
        let queueSignal = RequestQueueSignal()
        let completion = CallerCompletionSignal()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: PinSurfaceCache(),
            onRequestQueued: { Task { await queueSignal.recordRequest() } }
        )

        let first = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 300, height: 200), backingScale: 1)
            await completion.recordCompletion()
        }
        await renderer.waitUntilStarted(count: 1)
        let second = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 600, height: 400), backingScale: 1)
        }
        await queueSignal.waitUntilRequestsQueued(count: 2)

        await renderer.releaseNext()
        await renderer.waitUntilStarted(count: 2)
        await Task.yield()
        let completedBeforeLatestSurface = await completion.hasCompleted
        XCTAssertFalse(completedBeforeLatestSurface)

        await renderer.releaseNext()
        try await first.value
        try await second.value
        let completedAfterLatestSurface = await completion.hasCompleted
        XCTAssertTrue(completedAfterLatestSurface)
    }

    func testCachedNewerResizePreventsInFlightSurfaceFromOverwritingIt() async throws {
        let capture = try makeCapture()
        let pin = makePin(captureID: capture.id)
        let cache = PinSurfaceCache()
        let cachedSize = CGSize(width: 600, height: 400)
        let cachedSurface = PinSurface(
            image: try TestImage.solid(width: 2, height: 2, color: .white),
            logicalSize: cachedSize,
            byteCost: 32
        )
        await cache.insert(
            cachedSurface,
            for: .init(pinID: pin.id, logicalSize: cachedSize, backingScale: 1),
            priority: .visible
        )
        let renderer = GatedPinRenderer()
        let viewModel = PinViewModel(
            pin: pin,
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: cache
        )

        let first = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 300, height: 200), backingScale: 1)
        }
        await renderer.waitUntilStarted(count: 1)
        try await viewModel.loadSurface(panelSize: cachedSize, backingScale: 1)
        await renderer.releaseNext()
        try await first.value

        let surface = await viewModel.surface
        XCTAssertEqual(surface?.logicalSize, cachedSize)
    }

    func testCachedLatestSurfaceCompletesSupersededThrowingCaller() async throws {
        let capture = try makeCapture()
        let pin = makePin(captureID: capture.id)
        let cache = PinSurfaceCache()
        let cachedSize = CGSize(width: 600, height: 400)
        let cachedSurface = PinSurface(
            image: try TestImage.solid(width: 2, height: 2, color: .white),
            logicalSize: cachedSize,
            byteCost: 32
        )
        await cache.insert(
            cachedSurface,
            for: .init(pinID: pin.id, logicalSize: cachedSize, backingScale: 1),
            priority: .visible
        )
        let renderer = GatedThrowingPinRenderer()
        let viewModel = PinViewModel(
            pin: pin,
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: cache
        )

        let first = Task { () -> Result<Void, Error> in
            do {
                try await viewModel.loadSurface(
                    panelSize: CGSize(width: 300, height: 200),
                    backingScale: 1
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        await renderer.waitUntilStarted()
        try await viewModel.loadSurface(panelSize: cachedSize, backingScale: 1)
        await renderer.release()

        switch await first.value {
        case .success:
            break
        case .failure(let error):
            XCTFail("Expected cached replacement to complete the caller, got \(error)")
        }
        let surface = await viewModel.surface
        XCTAssertEqual(surface?.logicalSize, cachedSize)
    }

    func testCachedNewestRequestCompletesPendingCallerWithoutRenderingObsoleteRequest() async throws {
        let capture = try makeCapture()
        let pin = makePin(captureID: capture.id)
        let cache = PinSurfaceCache()
        let cachedSize = CGSize(width: 600, height: 400)
        let cachedSurface = PinSurface(
            image: try TestImage.solid(width: 2, height: 2, color: .white),
            logicalSize: cachedSize,
            byteCost: 32
        )
        await cache.insert(
            cachedSurface,
            for: .init(pinID: pin.id, logicalSize: cachedSize, backingScale: 1),
            priority: .visible
        )
        let renderer = GatedPinRenderer()
        let queueSignal = RequestQueueSignal()
        let viewModel = PinViewModel(
            pin: pin,
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: cache,
            onRequestQueued: { Task { await queueSignal.recordRequest() } }
        )

        let first = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 300, height: 200), backingScale: 1)
        }
        await renderer.waitUntilStarted(count: 1)
        let second = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 450, height: 300), backingScale: 1)
        }
        await queueSignal.waitUntilRequestsQueued(count: 2)

        try await viewModel.loadSurface(panelSize: cachedSize, backingScale: 1)
        try await second.value
        await renderer.releaseNext()
        try await first.value

        let requestCount = await renderer.requestCount
        let surface = await viewModel.surface
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(surface?.logicalSize, cachedSize)
    }

    func testCancellingActiveRenderCallerThrowsCancellationErrorWithoutStoppingRender() async throws {
        let capture = try makeCapture()
        let renderer = GatedPinRenderer()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: PinSurfaceCache()
        )

        let load = Task { () -> Result<Void, Error> in
            do {
                try await viewModel.loadSurface(panelSize: CGSize(width: 300, height: 200), backingScale: 1)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        await renderer.waitUntilStarted(count: 1)
        load.cancel()

        switch await load.value {
        case .success:
            XCTFail("Expected cancellation")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        await renderer.releaseNext()
    }

    func testCancellingPendingRenderCallerThrowsCancellationErrorWithoutCancellingReplacementRender() async throws {
        let capture = try makeCapture()
        let renderer = GatedPinRenderer()
        let queueSignal = RequestQueueSignal()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: PinSurfaceCache(),
            onRequestQueued: { Task { await queueSignal.recordRequest() } }
        )

        let first = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 300, height: 200), backingScale: 1)
        }
        await renderer.waitUntilStarted(count: 1)
        let second = Task { () -> Result<Void, Error> in
            do {
                try await viewModel.loadSurface(panelSize: CGSize(width: 600, height: 400), backingScale: 1)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        await queueSignal.waitUntilRequestsQueued(count: 2)
        second.cancel()

        switch await second.value {
        case .success:
            XCTFail("Expected cancellation")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        await renderer.releaseNext()
        await renderer.waitUntilStarted(count: 2)
        await renderer.releaseNext()
        try await first.value

        let requestCount = await renderer.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testCancellingCallerAfterTransferToReplacementThrowsCancellationError() async throws {
        let capture = try makeCapture()
        let renderer = GatedPinRenderer()
        let queueSignal = RequestQueueSignal()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: PinSurfaceCache(),
            onRequestQueued: { Task { await queueSignal.recordRequest() } }
        )

        let first = Task { () -> Result<Void, Error> in
            do {
                try await viewModel.loadSurface(panelSize: CGSize(width: 300, height: 200), backingScale: 1)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        await renderer.waitUntilStarted(count: 1)
        let second = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 600, height: 400), backingScale: 1)
        }
        await queueSignal.waitUntilRequestsQueued(count: 2)
        await renderer.releaseNext()
        await renderer.waitUntilStarted(count: 2)
        first.cancel()

        switch await first.value {
        case .success:
            XCTFail("Expected cancellation")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        await renderer.releaseNext()
        try await second.value
    }

    func testInvalidationDuringRenderingRequeuesTheLatestRequestedSurface() async throws {
        let capture = try makeCapture()
        let renderer = GatedPinRenderer()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: renderer,
            cache: PinSurfaceCache()
        )

        let load = Task {
            try await viewModel.loadSurface(panelSize: CGSize(width: 300, height: 200), backingScale: 2)
        }
        await renderer.waitUntilStarted(count: 1)
        await viewModel.handlePersistedUpdate(.image)

        await renderer.releaseNext()
        await renderer.waitUntilStarted(count: 2)
        let surfaceBeforeReplacement = await viewModel.surface
        XCTAssertNil(surfaceBeforeReplacement)

        await renderer.releaseNext()
        try await load.value
        let requestCount = await renderer.requestCount
        let surface = await viewModel.surface
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(surface?.logicalSize, CGSize(width: 300, height: 200))
    }

    func testCacheUsesLRUWithinPriorityAndDropsOversizeAndMemoryPressureSurfaces() async throws {
        let cache = PinSurfaceCache(byteLimit: 80)
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        await cache.insert(try makeSurface(bytes: 40), for: firstID, priority: .visible)
        await cache.insert(try makeSurface(bytes: 40), for: secondID, priority: .visible)
        _ = await cache.surface(for: firstID)
        await cache.insert(try makeSurface(bytes: 40), for: thirdID, priority: .visible)

        let firstSurface = await cache.surface(for: firstID)
        let secondSurface = await cache.surface(for: secondID)
        XCTAssertNotNil(firstSurface)
        XCTAssertNil(secondSurface)
        await cache.insert(try makeSurface(bytes: 81), for: UUID(), priority: .visible)
        let bytesBeforeMemoryPressure = await cache.totalBytes
        XCTAssertEqual(bytesBeforeMemoryPressure, 80)

        await cache.handleMemoryPressure()
        let bytesAfterMemoryPressure = await cache.totalBytes
        let cachedSurfaceAfterMemoryPressure = await cache.surface(for: firstID)
        XCTAssertEqual(bytesAfterMemoryPressure, 0)
        XCTAssertNil(cachedSurfaceAfterMemoryPressure)
    }

    func testCacheEvictsCollapsedThenHiddenBeforeVisibleSurfaces() async throws {
        let cache = PinSurfaceCache(byteLimit: 60)
        let visibleID = UUID()
        let hiddenID = UUID()
        let collapsedID = UUID()
        await cache.insert(try makeSurface(bytes: 20), for: visibleID, priority: .visible)
        await cache.insert(try makeSurface(bytes: 20), for: hiddenID, priority: .hidden)
        await cache.insert(try makeSurface(bytes: 20), for: collapsedID, priority: .collapsed)
        await cache.insert(try makeSurface(bytes: 20), for: UUID(), priority: .visible)
        await cache.insert(try makeSurface(bytes: 20), for: UUID(), priority: .visible)

        let visibleSurface = await cache.surface(for: visibleID)
        let hiddenSurface = await cache.surface(for: hiddenID)
        let collapsedSurface = await cache.surface(for: collapsedID)
        XCTAssertNotNil(visibleSurface)
        XCTAssertNil(hiddenSurface)
        XCTAssertNil(collapsedSurface)
    }

    func testCopyImageDelegatesToTheFullResolutionExportPath() async throws {
        let capture = try makeCapture()
        let document = AnnotationDocument(captureID: capture.id)
        let exporter = RecordingPinExporter()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: document),
            renderer: InspectingPinRenderer(),
            cache: PinSurfaceCache()
        )

        try await viewModel.copyImage(using: exporter)

        let copyRequests = await exporter.copyRequests
        XCTAssertEqual(copyRequests.count, 1)
        XCTAssertEqual(copyRequests.first?.capture.id, capture.id)
        XCTAssertEqual(copyRequests.first?.document, document)
    }

    func testCopyOCRTextReadsStoredTextWithoutRecognition() async throws {
        let capture = try makeCapture()
        let library = StubPinLibrary(
            capture: capture,
            annotations: .init(captureID: capture.id),
            record: makeRecord(id: capture.id, ocrText: "Stored OCR")
        )
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: library,
            renderer: InspectingPinRenderer(),
            cache: PinSurfaceCache()
        )

        let text = try await viewModel.ocrText()
        let recognitionRequests = await library.recognitionRequests
        XCTAssertEqual(text, "Stored OCR")
        XCTAssertEqual(recognitionRequests, 0)
    }

    @MainActor
    func testDetectedLinksOpenOnlyAfterExplicitAction() async throws {
        let capture = try makeCapture()
        let opener = RecordingPinLinkOpener()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: InspectingPinRenderer(),
            cache: PinSurfaceCache()
        )
        let links = await viewModel.detectedLinks(in: "See https://example.com/path.")
        let link = try XCTUnwrap(links.first)

        XCTAssertEqual(opener.openedURLs, [])
        await viewModel.openDetectedLink(link, using: opener)

        XCTAssertEqual(opener.openedURLs, [URL(string: "https://example.com/path")!])
    }

    func testTagAndOCRUpdatesKeepTheSurfaceWhileImageAndAnnotationUpdatesInvalidateIt() async throws {
        let capture = try makeCapture()
        let viewModel = PinViewModel(
            pin: makePin(captureID: capture.id),
            library: StubPinLibrary(capture: capture, annotations: .init(captureID: capture.id)),
            renderer: InspectingPinRenderer(),
            cache: PinSurfaceCache()
        )
        try await viewModel.loadSurface(panelSize: CGSize(width: 100, height: 50), backingScale: 1)

        await viewModel.handlePersistedUpdate(.tags)
        let surfaceAfterTags = await viewModel.surface
        XCTAssertNotNil(surfaceAfterTags)
        await viewModel.handlePersistedUpdate(.ocr)
        let surfaceAfterOCR = await viewModel.surface
        XCTAssertNotNil(surfaceAfterOCR)
        await viewModel.handlePersistedUpdate(.annotations)
        let surfaceAfterAnnotations = await viewModel.surface
        XCTAssertNil(surfaceAfterAnnotations)
    }
}

private actor StubPinLibrary: PinLibraryServing {
    let capture: CapturedImage
    let annotations: AnnotationDocument
    let storedRecord: CaptureRecord?
    private(set) var recognitionRequests = 0

    init(capture: CapturedImage, annotations: AnnotationDocument, record: CaptureRecord? = nil) {
        self.capture = capture
        self.annotations = annotations
        storedRecord = record
    }

    func record(id: UUID) async throws -> CaptureRecord? { storedRecord }
    func loadCapture(id: UUID) async throws -> CapturedImage { capture }
    func loadAnnotations(id: UUID) async throws -> AnnotationDocument { annotations }
    func originalURL(id: UUID) async throws -> URL { URL(fileURLWithPath: "/tmp/pin.png") }
}

private actor InspectingPinRenderer: PinRendering {
    private(set) var lastRequest: PinRenderRequest?
    private(set) var executedOnMainThread = true
    private(set) var requestCount = 0

    func render(_ request: PinRenderRequest) async throws -> PinSurface {
        requestCount += 1
        lastRequest = request
        executedOnMainThread = isCurrentThreadMain()
        return try makeSurface(bytes: 32)
    }
}

private actor GatedPinRenderer: PinRendering {
    private var currentCount = 0
    private(set) var maximumConcurrentCount = 0
    private(set) var requestCount = 0
    private var startedCount = 0
    private var finishedCount = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var finishWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func render(_ request: PinRenderRequest) async throws -> PinSurface {
        currentCount += 1
        requestCount += 1
        startedCount += 1
        maximumConcurrentCount = max(maximumConcurrentCount, currentCount)
        let readyWaiters = startWaiters.filter { $0.0 <= startedCount }
        startWaiters.removeAll { $0.0 <= startedCount }
        readyWaiters.forEach { $0.1.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
        currentCount -= 1
        finishedCount += 1
        let readyFinishWaiters = finishWaiters.filter { $0.0 <= finishedCount }
        finishWaiters.removeAll { $0.0 <= finishedCount }
        readyFinishWaiters.forEach { $0.1.resume() }
        return try makeSurface(bytes: 32)
    }

    func waitUntilStarted(count: Int) async {
        if startedCount >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func releaseNext() {
        releaseWaiters.removeFirst().resume()
    }

    func waitUntilFinished(count: Int) async {
        if finishedCount >= count { return }
        await withCheckedContinuation { finishWaiters.append((count, $0)) }
    }
}

private actor GatedThrowingPinRenderer: PinRendering {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func render(_ request: PinRenderRequest) async throws -> PinSurface {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
        throw TestRendererError.expected
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum TestRendererError: Error {
    case expected
}

private actor RequestQueueSignal {
    private var requestCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func recordRequest() {
        requestCount += 1
        let readyWaiters = waiters.filter { $0.0 <= requestCount }
        waiters.removeAll { $0.0 <= requestCount }
        readyWaiters.forEach { $0.1.resume() }
    }

    func waitUntilRequestsQueued(count: Int) async {
        if requestCount >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private actor CallerCompletionSignal {
    nonisolated let expectation = XCTestExpectation(description: "superseded caller completed")
    private(set) var hasCompleted = false

    func recordCompletion() {
        hasCompleted = true
        expectation.fulfill()
    }
}

private actor CacheOperationGate {
    private var isArmed = false
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arm() {
        isArmed = true
    }

    func pauseIfArmed() async {
        guard isArmed else { return }
        isArmed = false
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor RecordingPinExporter: AppCaptureExporting {
    struct CopyRequest: Equatable {
        let capture: CapturedImage
        let document: AnnotationDocument

        static func == (lhs: CopyRequest, rhs: CopyRequest) -> Bool {
            lhs.capture.id == rhs.capture.id && lhs.document == rhs.document
        }
    }

    private(set) var copyRequests: [CopyRequest] = []

    func copy(capture: CapturedImage, document: AnnotationDocument) async throws {
        copyRequests.append(.init(capture: capture, document: document))
    }
    func save(capture: CapturedImage, document: AnnotationDocument, format: ExportFormat) async throws {}
    func inspectRecording(at url: URL, format: RecordingFormat, createdAt: Date) async throws -> RecordedMedia { throw CocoaError(.featureUnsupported) }
    func copyFile(at url: URL) async throws {}
    func saveFile(at url: URL) async throws {}
    func discardFile(at url: URL) async throws {}
}

@MainActor
private final class RecordingPinLinkOpener: PinLinkOpening {
    private(set) var openedURLs: [URL] = []
    func open(_ url: URL) { openedURLs.append(url) }
}

private func makeCapture(width: Int = 120, height: Int = 80) throws -> CapturedImage {
    let image = try TestImage.solid(width: width, height: height, color: .white)
    return CapturedImage(
        id: UUID(), kind: .area, title: "Pin", createdAt: .now, image: image,
        pixelSize: .init(width: width, height: height)
    )
}

private func makeSurface(bytes: Int) throws -> PinSurface {
    PinSurface(
        image: try TestImage.solid(width: 2, height: 2, color: .white),
        logicalSize: CGSize(width: 2, height: 2),
        byteCost: bytes
    )
}

private func makePin(captureID: UUID) -> PinnedReference {
    PinnedReference(
        id: UUID(), captureID: captureID,
        frame: .init(displayID: "display", panelFrame: .zero, previousVisibleFrame: .zero),
        zoom: 1, normalizedPan: .init(x: 0.5, y: 0.5), opacity: 1,
        isClickThrough: false, collapsedEdge: nil, restoresAfterRelaunch: true,
        createdAt: .now, updatedAt: .now
    )
}

private func makeRecord(id: UUID, ocrText: String) -> CaptureRecord {
    CaptureRecord(
        id: id, kind: .area, title: "Pin", createdAt: .now, lastEditedAt: .now,
        pixelSize: .init(width: 120, height: 80), duration: nil,
        originalFilename: "original.png", editedFilename: nil, thumbnailFilename: "thumbnail.png",
        annotationFilename: nil, ocrText: ocrText, tags: []
    )
}

private func isCurrentThreadMain() -> Bool {
    Thread.isMainThread
}
