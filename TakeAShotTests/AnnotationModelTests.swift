import Foundation
import CoreGraphics
import XCTest
@testable import TakeAShot

final class AnnotationModelTests: XCTestCase {
    @MainActor
    func testAppStateRetainsActiveCapturedImageArtifact() throws {
        let image = try TestImage.solid(width: 320, height: 180, color: .blue)
        let capture = CapturedImage(
            id: UUID(),
            kind: .window,
            title: "Settings",
            createdAt: Date(),
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height)
        )

        AppState.shared.setCapturedImage(capture)

        XCTAssertEqual(AppState.shared.activeCapture?.id, capture.id)
        XCTAssertEqual(AppState.shared.capturedTitle, capture.title)
        XCTAssertEqual(AppState.shared.capturedImage?.size, CGSize(width: 320, height: 180))
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
    func testAppStatePublishesAndClearsExportErrorMessage() {
        AppState.shared.setEditorError("Couldn’t copy annotated screenshot.")
        XCTAssertEqual(
            AppState.shared.editorErrorMessage,
            "Couldn’t copy annotated screenshot."
        )

        AppState.shared.setEditorError(nil)
        XCTAssertNil(AppState.shared.editorErrorMessage)
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
