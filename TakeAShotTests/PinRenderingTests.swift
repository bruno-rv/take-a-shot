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

        async let first: Void = viewModel.loadSurface(
            panelSize: CGSize(width: 300, height: 200), backingScale: 2
        )
        async let second: Void = viewModel.loadSurface(
            panelSize: CGSize(width: 600, height: 400), backingScale: 2
        )
        await renderer.waitUntilRendering()
        await renderer.releaseAll()
        _ = try await (first, second)

        let maximumConcurrentCount = await renderer.maximumConcurrentCount
        let surface = await viewModel.surface
        XCTAssertEqual(maximumConcurrentCount, 1)
        XCTAssertEqual(surface?.logicalSize, CGSize(width: 600, height: 400))
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

    func render(_ request: PinRenderRequest) async throws -> PinSurface {
        lastRequest = request
        executedOnMainThread = isCurrentThreadMain()
        return try makeSurface(bytes: 32)
    }
}

private actor GatedPinRenderer: PinRendering {
    private var currentCount = 0
    private(set) var maximumConcurrentCount = 0
    private var isReleased = false
    private var renderingWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func render(_ request: PinRenderRequest) async throws -> PinSurface {
        currentCount += 1
        maximumConcurrentCount = max(maximumConcurrentCount, currentCount)
        for waiter in renderingWaiters { waiter.resume() }
        renderingWaiters.removeAll()
        if !isReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        currentCount -= 1
        return try makeSurface(bytes: 32)
    }

    func waitUntilRendering() async {
        if currentCount > 0 { return }
        await withCheckedContinuation { renderingWaiters.append($0) }
    }

    func releaseAll() {
        isReleased = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
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
