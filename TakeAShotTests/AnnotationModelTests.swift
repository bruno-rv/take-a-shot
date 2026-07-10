import Foundation
import CoreGraphics
import XCTest
@testable import TakeAShot

final class AnnotationModelTests: XCTestCase {
    @MainActor
    func testAppOwnedStateRetainsCaptureAndUsesOneAnnotationHistorySource() async throws {
        let image = try TestImage.solid(width: 320, height: 180, color: .blue)
        let capture = CapturedImage(
            id: UUID(),
            kind: .window,
            title: "Settings",
            createdAt: Date(),
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height)
        )
        let harness = try AppStateHarness()

        harness.state.receiveCapture(capture)
        harness.state.annotationEditor.applyDrag(
            tool: .highlight,
            from: NormalizedPoint(x: 0.1, y: 0.2),
            to: NormalizedPoint(x: 0.8, y: 0.7)
        )
        await Task.yield()

        XCTAssertEqual(harness.state.activeCapture?.id, capture.id)
        XCTAssertEqual(harness.state.annotationHistory, harness.state.annotationEditor.document)
        XCTAssertEqual(harness.state.annotationHistory.items.count, 1)

        harness.state.undoAnnotation()

        XCTAssertTrue(harness.state.annotationEditor.document.items.isEmpty)
        XCTAssertTrue(harness.state.annotationHistory.items.isEmpty)
    }

    @MainActor
    func testAppStateDispatchesEachCaptureModeWithoutCollapsingIntent() throws {
        let harness = try AppStateHarness()

        for mode in CaptureMode.allCases {
            harness.state.capture(mode: mode, options: CaptureOptions())
        }

        XCTAssertEqual(harness.captureRecorder.modes, CaptureMode.allCases)
    }

    @MainActor
    func testCopyUsesImmutableActiveCaptureAndAnnotationSnapshot() async throws {
        let harness = try AppStateHarness()
        let capture = try makeCapture()
        harness.state.receiveCapture(capture)
        harness.state.annotationEditor.applyDrag(
            tool: .arrow,
            from: NormalizedPoint(x: 0.1, y: 0.1),
            to: NormalizedPoint(x: 0.8, y: 0.8)
        )

        harness.state.copyActiveCapture()
        await fulfillment(of: [harness.exporter.copyExpectation], timeout: 1)

        let storedSnapshot = await harness.exporter.copySnapshot
        let snapshot = try XCTUnwrap(storedSnapshot)
        XCTAssertEqual(snapshot.captureID, capture.id)
        XCTAssertEqual(snapshot.document.captureID, capture.id)
        XCTAssertEqual(snapshot.document.items.count, 1)
    }

    @MainActor
    func testGIFRecordingIsDistinctAndForcesAudioOff() async throws {
        let harness = try AppStateHarness()

        harness.state.startRecording(
            format: .gif,
            includesSystemAudio: true,
            includesMicrophone: true
        )
        await fulfillment(of: [harness.recordingRequests.expectation], timeout: 1)

        let request = try XCTUnwrap(harness.recordingRequests.requests.first)
        XCTAssertEqual(request.format, .gif)
        XCTAssertFalse(request.includesSystemAudio)
        XCTAssertFalse(request.includesMicrophone)
        XCTAssertEqual(request.target, .display(1))
    }

    @MainActor
    func testStoppingRecordingRegistersCommittedOutputInLibrary() async throws {
        let harness = try AppStateHarness()

        harness.state.startRecording(
            format: .mp4,
            includesSystemAudio: true,
            includesMicrophone: false
        )
        await fulfillment(of: [harness.recordingRequests.expectation], timeout: 1)
        harness.state.stopRecording()

        for _ in 0..<100 where harness.state.records.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(harness.state.records.count, 1)
        XCTAssertEqual(harness.state.records.first?.kind, .video)
        XCTAssertEqual(harness.state.records.first?.originalFilename, "originals/output.mp4")
        XCTAssertEqual(try Data(contentsOf: harness.outputURL), Data("media".utf8))
    }

    @MainActor
    func testAsynchronousRecordingFailureUpdatesPresentedState() async throws {
        let root = temporaryDirectory()
        let session = AppStateFailureRecordingSession(
            outputURL: root.appendingPathComponent("originals/failure.mp4")
        )
        let requests = RecordingRequestRecorder()
        let state = AppState(
            library: CaptureLibraryStore(rootURL: root, ocr: AppStateOCR()),
            recording: RecordingEngine(sessionFactory: { request in
                requests.record(request)
                return session
            }),
            exporter: AppCaptureExporterSpy(copyError: nil),
            captureAction: { _, _ in },
            cancelCaptureAction: {},
            recordingTargetPicker: { .window(42) }
        )
        state.startRecording(
            format: .mp4,
            includesSystemAudio: false,
            includesMicrophone: false
        )
        await fulfillment(of: [requests.expectation], timeout: 1)

        await session.fail(.recordingFailed("source disappeared"))
        for _ in 0..<100 where state.recordingState.kind != .failed {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(state.recordingState.kind, .failed)
        XCTAssertEqual(state.presentedError?.title, "Recording Failed")
        XCTAssertTrue(state.presentedError?.message.contains("source disappeared") == true)
    }

    @MainActor
    func testRecordingDoesNotPublishCompletedBeforeLibraryRegistration() async throws {
        let root = temporaryDirectory()
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let outputURL = originals.appendingPathComponent("output.mp4")
        try Data("media".utf8).write(to: outputURL)
        let session = AppStateRecordingSession(outputURL: outputURL)
        let requests = RecordingRequestRecorder()
        let exporter = GatedMediaExporter()
        let state = AppState(
            library: CaptureLibraryStore(rootURL: root, ocr: AppStateOCR()),
            recording: RecordingEngine(sessionFactory: { request in
                requests.record(request)
                return session
            }),
            exporter: exporter,
            captureAction: { _, _ in },
            cancelCaptureAction: {},
            recordingTargetPicker: { .display(1) }
        )
        state.startRecording(
            format: .mp4,
            includesSystemAudio: false,
            includesMicrophone: false
        )
        await fulfillment(of: [requests.expectation], timeout: 1)

        state.stopRecording()
        await fulfillment(of: [exporter.inspectExpectation], timeout: 1)
        try await Task.sleep(for: .milliseconds(120))
        let stateBeforeRegistration = state.recordingState.kind
        await exporter.resume(
            RecordedMedia(
                id: UUID(),
                kind: .video,
                title: "output.mp4",
                createdAt: .now,
                pixelSize: PixelSize(width: 1, height: 1),
                duration: 1,
                originalURL: outputURL,
                thumbnail: try TestImage.solid(width: 1, height: 1, color: .black)
            )
        )

        XCTAssertEqual(stateBeforeRegistration, .stopping)
    }

    func testAspectFitTransformMapsLetterboxedPointIntoImageSpace() {
        let transform = CanvasTransform(
            canvasSize: CGSize(width: 1_000, height: 800),
            imageSize: CGSize(width: 1_000, height: 500),
            zoom: 1
        )

        XCTAssertEqual(
            transform.normalizedPoint(from: CGPoint(x: 500, y: 400)),
            NormalizedPoint(x: 0.5, y: 0.5)
        )
        XCTAssertNil(transform.normalizedPoint(from: CGPoint(x: 500, y: 50)))
    }

    func testCanvasTransformMapsNormalizedGeometryAtZoom() {
        let transform = CanvasTransform(
            canvasSize: CGSize(width: 1_000, height: 800),
            imageSize: CGSize(width: 1_000, height: 500),
            zoom: 2
        )

        XCTAssertEqual(transform.imageRect, CGRect(x: -500, y: -100, width: 2_000, height: 1_000))
        XCTAssertEqual(
            transform.canvasPoint(from: NormalizedPoint(x: 0.25, y: 0.75)),
            CGPoint(x: 0, y: 650)
        )
        XCTAssertEqual(
            transform.canvasRect(from: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
            CGRect(x: -300, y: 100, width: 600, height: 400)
        )
    }

    @MainActor
    func testEditorModelClampsZoomToSupportedRange() {
        let model = AnnotationEditorModel()

        model.zoom = 5
        XCTAssertEqual(model.zoom, 4)

        model.zoom = 0.1
        XCTAssertEqual(model.zoom, 0.25)
    }

    func testSelectIsTheOnlyToolThatAllowsItemManipulation() {
        XCTAssertEqual(AnnotationTool.allCases.first, .select)
        XCTAssertTrue(AnnotationTool.select.allowsItemManipulation)

        for tool in AnnotationTool.allCases where tool != .select {
            XCTAssertFalse(tool.allowsItemManipulation, "\(tool) must create instead of manipulating")
        }
    }

    func testSelectDragDoesNotCreateAnAnnotation() {
        var editor = makeEditor()

        editor.applyDrag(
            tool: .select,
            from: NormalizedPoint(x: 0.1, y: 0.2),
            to: NormalizedPoint(x: 0.8, y: 0.7),
            style: makeStyle()
        )

        XCTAssertTrue(editor.document.items.isEmpty)
    }

    func testResolvingPendingTextCommitsNonEmptyAndCancelsEmptyText() throws {
        var editor = makeEditor()
        let style = makeStyle()

        editor.beginText(at: NormalizedPoint(x: 0.2, y: 0.3), style: style)
        editor.updatePendingText("Review this")
        editor.resolvePendingText(style: style)

        guard case .text(let text) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected committed text")
        }
        XCTAssertEqual(text.text, "Review this")
        XCTAssertNil(editor.pendingText)

        editor.beginText(at: NormalizedPoint(x: 0.4, y: 0.5), style: style)
        editor.updatePendingText("   ")
        editor.resolvePendingText(style: style)

        XCTAssertEqual(editor.document.items.count, 1)
        XCTAssertNil(editor.pendingText)
    }

    func testBeginningTextAtSecondLocationCommitsCurrentDraft() throws {
        var editor = makeEditor()
        let style = makeStyle()
        let secondAnchor = NormalizedPoint(x: 0.7, y: 0.6)

        editor.beginText(at: NormalizedPoint(x: 0.2, y: 0.3), style: style)
        editor.updatePendingText("First note")
        editor.beginText(at: secondAnchor, style: style)

        guard case .text(let text) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected first draft to commit")
        }
        XCTAssertEqual(text.text, "First note")
        XCTAssertEqual(editor.pendingText?.anchor, secondAnchor)
        XCTAssertEqual(editor.pendingText?.text, "")
    }

    func testSelectingItemCommitsPendingTextBeforeSelectionChanges() throws {
        let arrowID = UUID()
        let style = makeStyle()
        var editor = makeEditor(items: [
            .arrow(.init(
                id: arrowID,
                start: NormalizedPoint(x: 0.1, y: 0.1),
                end: NormalizedPoint(x: 0.8, y: 0.8),
                color: .red,
                strokeWidth: 4
            )),
        ])

        editor.beginText(at: NormalizedPoint(x: 0.3, y: 0.4), style: style)
        editor.updatePendingText("Resolve me")
        editor.select(arrowID, style: style)

        XCTAssertEqual(editor.document.items.count, 2)
        guard case .text(let text) = editor.document.items.last else {
            return XCTFail("Expected pending text to commit")
        }
        XCTAssertEqual(text.text, "Resolve me")
        XCTAssertEqual(editor.selectedItemID, arrowID)
        XCTAssertNil(editor.pendingText)
    }

    func testHorizontalArrowResizeCanGainVerticalExtent() throws {
        let arrowID = UUID()
        var editor = makeEditor(items: [
            .arrow(.init(
                id: arrowID,
                start: NormalizedPoint(x: 0.2, y: 0.5),
                end: NormalizedPoint(x: 0.8, y: 0.5),
                color: .red,
                strokeWidth: 4
            )),
        ])

        editor.select(arrowID)
        editor.resizeSelection(
            handle: .topLeading,
            to: NormalizedPoint(x: 0.1, y: 0.2)
        )

        guard case .arrow(let arrow) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected arrow")
        }
        XCTAssertEqual(arrow.start, NormalizedPoint(x: 0.1, y: 0.2))
        XCTAssertEqual(arrow.end, NormalizedPoint(x: 0.8, y: 0.5))
    }

    func testVerticalArrowResizeCanGainHorizontalExtent() throws {
        let arrowID = UUID()
        var editor = makeEditor(items: [
            .arrow(.init(
                id: arrowID,
                start: NormalizedPoint(x: 0.5, y: 0.2),
                end: NormalizedPoint(x: 0.5, y: 0.8),
                color: .red,
                strokeWidth: 4
            )),
        ])

        editor.select(arrowID)
        editor.resizeSelection(
            handle: .topTrailing,
            to: NormalizedPoint(x: 0.8, y: 0.1)
        )

        guard case .arrow(let arrow) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected arrow")
        }
        XCTAssertEqual(arrow.start, NormalizedPoint(x: 0.8, y: 0.1))
        XCTAssertEqual(arrow.end, NormalizedPoint(x: 0.5, y: 0.8))
    }

    func testEdgeClampedNoOpMoveDoesNotConsumeUndo() throws {
        let itemID = UUID()
        let originalRect = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        var editor = makeEditor(items: [
            .highlight(.init(
                id: itemID,
                rect: originalRect,
                color: .red,
                amount: 0.5
            )),
        ])

        editor.select(itemID)
        editor.moveSelection(dx: 0.4, dy: 0)
        editor.moveSelection(dx: 0.1, dy: 0)
        editor.undo()

        guard case .highlight(let highlight) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected highlight")
        }
        assertEqual(highlight.rect, originalRect)
    }

    func testNoOpResizeDoesNotConsumeUndo() throws {
        let itemID = UUID()
        let originalRect = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        var editor = makeEditor(items: [
            .blur(.init(id: itemID, rect: originalRect, color: .red, amount: 8)),
        ])

        editor.select(itemID)
        editor.resizeSelection(
            handle: .bottomTrailing,
            to: NormalizedPoint(x: 0.8, y: 0.8)
        )
        editor.resizeSelection(
            handle: .bottomTrailing,
            to: NormalizedPoint(x: 0.8, y: 0.8)
        )
        editor.undo()

        guard case .blur(let blur) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected blur")
        }
        assertEqual(blur.rect, originalRect)
    }

    func testNoOpCropDoesNotConsumeUndo() {
        var editor = makeEditor()
        let start = NormalizedPoint(x: 0.1, y: 0.2)
        let end = NormalizedPoint(x: 0.8, y: 0.9)

        editor.applyDrag(tool: .crop, from: start, to: end, style: makeStyle())
        editor.applyDrag(tool: .crop, from: start, to: end, style: makeStyle())
        editor.undo()

        XCTAssertNil(editor.document.cropRect)
    }

    @MainActor
    func testDetachedRendererPerformsWorkOffMainThread() async throws {
        let capture = try makeCapture()
        let recorder = RenderThreadRecorder()
        let service = DetachedAnnotationRenderService { source, _ in
            recorder.record(isMainThread: Thread.isMainThread)
            return source
        }

        let rendered = try await service.render(
            capture: capture,
            document: AnnotationDocument(captureID: capture.id)
        )

        XCTAssertEqual(rendered.width, capture.image.width)
        XCTAssertEqual(recorder.wasMainThread, false)
    }

    @MainActor
    func testExportFailureLeavesClipboardPublisherUntouched() async throws {
        let capture = try makeCapture()
        let clipboard = RecordingAnnotationClipboard()
        let coordinator = AnnotationExportCoordinator(
            renderService: FailingAnnotationRenderService(),
            clipboard: clipboard
        )

        do {
            try await coordinator.copy(
                capture: capture,
                document: AnnotationDocument(captureID: capture.id)
            )
            XCTFail("Expected rendering to fail")
        } catch TestAnnotationExportError.rendering {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(clipboard.publishCount, 0)
    }

    @MainActor
    func testAppStateSurfacesAndClearsPresentedExportError() async throws {
        let harness = try AppStateHarness(exportError: TestAnnotationExportError.rendering)
        harness.state.receiveCapture(try makeCapture())

        harness.state.copyActiveCapture()
        await fulfillment(of: [harness.exporter.copyExpectation], timeout: 1)
        for _ in 0..<10 where harness.state.presentedError == nil { await Task.yield() }

        XCTAssertEqual(harness.state.presentedError?.title, "Copy Failed")

        harness.state.dismissPresentedError()
        XCTAssertNil(harness.state.presentedError)
    }

    func testEditorCreatesArrowWithActiveStyle() throws {
        var editor = makeEditor()
        let style = makeStyle()

        editor.applyDrag(
            tool: .arrow,
            from: NormalizedPoint(x: 0.1, y: 0.2),
            to: NormalizedPoint(x: 0.8, y: 0.7),
            style: style
        )

        guard case .arrow(let arrow) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected an arrow")
        }
        XCTAssertEqual(arrow.start, NormalizedPoint(x: 0.1, y: 0.2))
        XCTAssertEqual(arrow.end, NormalizedPoint(x: 0.8, y: 0.7))
        XCTAssertEqual(arrow.color, style.color)
        XCTAssertEqual(arrow.strokeWidth, style.strokeWidth)
        XCTAssertEqual(editor.selectedItemID, arrow.id)
    }

    func testEditorCreatesHighlightRectangleWithActiveStyle() throws {
        var editor = makeEditor()
        let style = makeStyle()

        editor.applyDrag(
            tool: .highlight,
            from: NormalizedPoint(x: 0.8, y: 0.7),
            to: NormalizedPoint(x: 0.2, y: 0.3),
            style: style
        )

        guard case .highlight(let highlight) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected a highlight")
        }
        assertEqual(
            highlight.rect,
            NormalizedRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        )
        XCTAssertEqual(highlight.color, style.color)
        XCTAssertEqual(highlight.amount, style.opacity)
    }

    func testEditorCreatesBlurRectangleWithActiveRadius() throws {
        var editor = makeEditor()
        let style = makeStyle()

        editor.applyDrag(
            tool: .blur,
            from: NormalizedPoint(x: 0.15, y: 0.25),
            to: NormalizedPoint(x: 0.45, y: 0.55),
            style: style
        )

        guard case .blur(let blur) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected a blur")
        }
        assertEqual(
            blur.rect,
            NormalizedRect(x: 0.15, y: 0.25, width: 0.3, height: 0.3)
        )
        XCTAssertEqual(blur.amount, style.blurRadius)
    }

    func testEditorAppliesCropWithoutAddingAnAnnotation() {
        var editor = makeEditor()

        editor.applyDrag(
            tool: .crop,
            from: NormalizedPoint(x: 0.9, y: 0.85),
            to: NormalizedPoint(x: 0.1, y: 0.15),
            style: makeStyle()
        )

        XCTAssertTrue(editor.document.items.isEmpty)
        assertEqual(
            editor.document.cropRect,
            NormalizedRect(x: 0.1, y: 0.15, width: 0.8, height: 0.7)
        )
    }

    func testEditorCommitsInlineTextAtAnchor() throws {
        var editor = makeEditor()
        let style = makeStyle()

        editor.commitText(
            "Review this",
            at: NormalizedPoint(x: 0.75, y: 0.85),
            style: style
        )

        guard case .text(let text) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected text")
        }
        XCTAssertEqual(text.text, "Review this")
        assertEqual(
            text.bounds,
            NormalizedRect(x: 0.75, y: 0.85, width: 0.25, height: 0.12)
        )
        XCTAssertEqual(text.fontSize, style.fontSize)
        XCTAssertEqual(text.color, style.color)
    }

    func testEditorMovesSelectedItemAndPreservesItsSize() throws {
        let itemID = UUID()
        var editor = makeEditor(items: [
            .highlight(.init(
                id: itemID,
                rect: NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2),
                color: .red,
                amount: 0.5
            )),
        ])

        editor.select(itemID)
        editor.moveSelection(dx: 0.3, dy: 0.4)

        guard case .highlight(let highlight) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected a highlight")
        }
        assertEqual(
            highlight.rect,
            NormalizedRect(x: 0.5, y: 0.7, width: 0.4, height: 0.2)
        )
    }

    func testEditorResizesSelectedItemToNewBounds() throws {
        let itemID = UUID()
        var editor = makeEditor(items: [
            .blur(.init(
                id: itemID,
                rect: NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2),
                color: .red,
                amount: 8
            )),
        ])

        editor.select(itemID)
        editor.resizeSelection(to: NormalizedRect(x: 0.1, y: 0.15, width: 0.7, height: 0.6))

        guard case .blur(let blur) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected a blur")
        }
        assertEqual(
            blur.rect,
            NormalizedRect(x: 0.1, y: 0.15, width: 0.7, height: 0.6)
        )
    }

    func testEditorDeletesSelectionAndClearsSelection() {
        let itemID = UUID()
        var editor = makeEditor(items: [
            .arrow(.init(
                id: itemID,
                start: NormalizedPoint(x: 0.1, y: 0.1),
                end: NormalizedPoint(x: 0.8, y: 0.8),
                color: .red,
                strokeWidth: 4
            )),
        ])

        editor.select(itemID)
        editor.deleteSelection()

        XCTAssertTrue(editor.document.items.isEmpty)
        XCTAssertNil(editor.selectedItemID)
    }

    func testEditorUndoAndRedoWireThroughDocumentHistory() {
        var editor = makeEditor()

        editor.applyDrag(
            tool: .arrow,
            from: NormalizedPoint(x: 0.1, y: 0.1),
            to: NormalizedPoint(x: 0.8, y: 0.8),
            style: makeStyle()
        )
        editor.undo()
        XCTAssertTrue(editor.document.items.isEmpty)

        editor.redo()
        XCTAssertEqual(editor.document.items.count, 1)
    }

    func testUndoAndRedoRestoreWholeDocument() {
        let initial = AnnotationDocument(captureID: UUID())
        var history = AnnotationHistory(initial: initial, limit: 50)
        let arrow = AnnotationItem.arrow(.init(
            id: UUID(),
            start: .init(x: 0.1, y: 0.2),
            end: .init(x: 0.8, y: 0.7),
            color: .red,
            strokeWidth: 4
        ))

        history.commit { $0.items.append(arrow) }
        XCTAssertEqual(history.document.items, [arrow])

        history.undo()
        XCTAssertTrue(history.document.items.isEmpty)

        history.redo()
        XCTAssertEqual(history.document.items, [arrow])
    }

    func testDocumentCodableRoundTripPreservesAnnotationsAndCrop() throws {
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .arrow(.init(
                    id: UUID(),
                    start: .init(x: 0.1, y: 0.2),
                    end: .init(x: 0.8, y: 0.7),
                    color: .red,
                    strokeWidth: 4
                )),
                .text(.init(
                    id: UUID(),
                    bounds: .init(x: 0.2, y: 0.3, width: 0.4, height: 0.2),
                    text: "Review this",
                    fontSize: 18,
                    color: .red
                )),
                .highlight(.init(
                    id: UUID(),
                    rect: .init(x: 0.1, y: 0.5, width: 0.6, height: 0.25),
                    color: .red,
                    amount: 0.5
                )),
                .blur(.init(
                    id: UUID(),
                    rect: .init(x: 0.6, y: 0.1, width: 0.3, height: 0.3),
                    color: .red,
                    amount: 8
                )),
            ],
            cropRect: .init(x: 0.05, y: 0.1, width: 0.9, height: 0.8)
        )

        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: encoded)

        XCTAssertEqual(decoded, document)
    }

    func testNormalizedGeometryClampsToImageBounds() {
        XCTAssertEqual(NormalizedPoint(x: -0.25, y: 1.4), NormalizedPoint(x: 0, y: 1))
        XCTAssertEqual(
            NormalizedRect(x: 0.75, y: -0.2, width: 0.5, height: 1.5),
            NormalizedRect(x: 0.75, y: 0, width: 0.25, height: 1)
        )
        XCTAssertEqual(
            NormalizedRect(x: 0.2, y: 0.3, width: -1, height: -1),
            NormalizedRect(x: 0.2, y: 0.3, width: 0, height: 0)
        )
    }

    private func makeEditor(items: [AnnotationItem] = []) -> AnnotationEditorState {
        AnnotationEditorState(
            document: AnnotationDocument(captureID: UUID(), items: items),
            historyLimit: 50
        )
    }

    private func makeStyle() -> AnnotationStyle {
        AnnotationStyle(
            color: RGBAColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),
            strokeWidth: 6,
            opacity: 0.4,
            blurRadius: 12,
            fontSize: 22
        )
    }

    private func makeCapture() throws -> CapturedImage {
        let image = try TestImage.solid(width: 32, height: 18, color: .blue)
        return CapturedImage(
            id: UUID(),
            kind: .window,
            title: "Export",
            createdAt: Date(),
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height)
        )
    }

    private func assertEqual(
        _ actual: NormalizedRect?,
        _ expected: NormalizedRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("Expected normalized rectangle", file: file, line: line)
        }
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.000_001, file: file, line: line)
    }
}

private final class RenderThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWasMainThread: Bool?

    var wasMainThread: Bool? {
        lock.withLock { storedWasMainThread }
    }

    func record(isMainThread: Bool) {
        lock.withLock { storedWasMainThread = isMainThread }
    }
}

private enum TestAnnotationExportError: Error {
    case rendering
}

private struct FailingAnnotationRenderService: AnnotationRenderServicing {
    func render(
        capture: CapturedImage,
        document: AnnotationDocument
    ) async throws -> CGImage {
        throw TestAnnotationExportError.rendering
    }
}

@MainActor
private final class RecordingAnnotationClipboard: AnnotationClipboardPublishing {
    private(set) var publishCount = 0

    func publish(_ image: CGImage) {
        publishCount += 1
    }
}

@MainActor
private struct AppStateHarness {
    let state: AppState
    let captureRecorder: AppCaptureActionRecorder
    let exporter: AppCaptureExporterSpy
    let recordingRequests: RecordingRequestRecorder
    let outputURL: URL

    init(exportError: Error? = nil) throws {
        let root = temporaryDirectory()
        let library = CaptureLibraryStore(rootURL: root, ocr: AppStateOCR())
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        outputURL = originals.appendingPathComponent("output.mp4")
        try Data("media".utf8).write(to: outputURL)
        let session = AppStateRecordingSession(
            outputURL: outputURL
        )
        captureRecorder = AppCaptureActionRecorder()
        recordingRequests = RecordingRequestRecorder()
        exporter = AppCaptureExporterSpy(copyError: exportError)
        state = AppState(
            library: library,
            recording: RecordingEngine(sessionFactory: { [recordingRequests] request in
                recordingRequests.record(request)
                return session
            }),
            exporter: exporter,
            captureAction: { [captureRecorder] mode, _ in
                captureRecorder.record(mode)
            },
            cancelCaptureAction: {},
            recordingTargetPicker: { .display(1) }
        )
    }
}

private final class RecordingRequestRecorder: @unchecked Sendable {
    let expectation = XCTestExpectation(description: "recording requested")
    private let lock = NSLock()
    private var storedRequests: [RecordingRequest] = []

    var requests: [RecordingRequest] {
        lock.withLock { storedRequests }
    }

    func record(_ request: RecordingRequest) {
        lock.withLock { storedRequests.append(request) }
        expectation.fulfill()
    }
}

@MainActor
private final class AppCaptureActionRecorder {
    private(set) var modes: [CaptureMode] = []

    func record(_ mode: CaptureMode) {
        modes.append(mode)
    }
}

private actor AppCaptureExporterSpy: AppCaptureExporting {
    struct CopySnapshot {
        let captureID: UUID
        let document: AnnotationDocument
    }

    nonisolated let copyExpectation = XCTestExpectation(description: "copy attempted")
    private let copyError: Error?
    private(set) var copySnapshot: CopySnapshot?

    init(copyError: Error?) {
        self.copyError = copyError
    }

    func copy(capture: CapturedImage, document: AnnotationDocument) async throws {
        copySnapshot = CopySnapshot(captureID: capture.id, document: document)
        copyExpectation.fulfill()
        if let copyError { throw copyError }
    }

    func save(
        capture: CapturedImage,
        document: AnnotationDocument,
        format: ExportFormat
    ) async throws {}

    func copyFile(at url: URL) async throws {}
    func saveFile(at url: URL) async throws {}

    func inspectRecording(
        at url: URL,
        format: RecordingFormat,
        createdAt: Date
    ) async throws -> RecordedMedia {
        RecordedMedia(
            id: UUID(),
            kind: format == .mp4 ? .video : .gif,
            title: url.lastPathComponent,
            createdAt: createdAt,
            pixelSize: PixelSize(width: 1, height: 1),
            duration: 1,
            originalURL: url,
            thumbnail: try TestImage.solid(width: 1, height: 1, color: .black)
        )
    }
}

private actor GatedMediaExporter: AppCaptureExporting {
    nonisolated let inspectExpectation = XCTestExpectation(description: "inspection started")
    private var continuation: CheckedContinuation<RecordedMedia, Never>?

    func copy(capture: CapturedImage, document: AnnotationDocument) async throws {}
    func save(capture: CapturedImage, document: AnnotationDocument, format: ExportFormat) async throws {}
    func copyFile(at url: URL) async throws {}
    func saveFile(at url: URL) async throws {}

    func inspectRecording(
        at url: URL,
        format: RecordingFormat,
        createdAt: Date
    ) async throws -> RecordedMedia {
        inspectExpectation.fulfill()
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ media: RecordedMedia) {
        continuation?.resume(returning: media)
        continuation = nil
    }
}

private actor AppStateRecordingSession: RecordingSession {
    nonisolated let failureEvents: AsyncStream<RecordingError> = AsyncStream { $0.finish() }
    let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() async throws {}
    func stop() async throws -> URL { outputURL }
    func cancel() async {}
}

private actor AppStateFailureRecordingSession: RecordingSession {
    nonisolated let failureEvents: AsyncStream<RecordingError>
    let outputURL: URL
    private let continuation: AsyncStream<RecordingError>.Continuation

    init(outputURL: URL) {
        self.outputURL = outputURL
        let stream = AsyncStream.makeStream(of: RecordingError.self)
        failureEvents = stream.stream
        continuation = stream.continuation
    }

    func start() async throws {}
    func stop() async throws -> URL { outputURL }
    func cancel() async { continuation.finish() }
    func fail(_ error: RecordingError) { continuation.yield(error) }
}

private struct AppStateOCR: OCRRecognizing {
    func recognizeText(in image: CGImage) async throws -> String { "" }
}
