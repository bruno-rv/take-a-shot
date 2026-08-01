import Carbon
import XCTest
@testable import TakeAShot

final class CaptureGeometryTests: XCTestCase {
    func testHarnessLoadsApplicationModule() {
        XCTAssertEqual(CaptureMode.area.rawValue, "Area")
    }

    func testCaptureOptionsHideCursorByDefaultButAllowOptingIn() {
        XCTAssertFalse(CaptureOptions().showsCursor)
        XCTAssertTrue(CaptureOptions(showsCursor: true).showsCursor)
    }

    func testMainAndKeypadEnterMapToTheSameOverlayActionIncludingFullscreenWithoutSelection() {
        let keyCodes = [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)]

        for keyCode in keyCodes {
            XCTAssertEqual(SelectionOverlayInput(keyCode: keyCode), .returnKey)
            XCTAssertEqual(
                SelectionOverlayPrecedence.action(
                    for: SelectionOverlayInput(keyCode: keyCode)!,
                    isFieldEditorActive: false,
                    hasCommittedSelection: false,
                    activeTool: .select
                ),
                .captureFullScreen
            )
            XCTAssertEqual(
                SelectionOverlayPrecedence.action(
                    for: SelectionOverlayInput(keyCode: keyCode)!,
                    isFieldEditorActive: false,
                    hasCommittedSelection: true,
                    activeTool: .select
                ),
                .confirmSelection
            )
        }
    }

    func testSourceRectConvertsAppKitBottomLeftToScreenCaptureTopLeft() {
        let display = DisplayGeometry(
            id: 7,
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            scale: 2
        )
        let selection = CGRect(x: 1540, y: 680, width: 300, height: 200)
        XCTAssertEqual(
            CaptureGeometry.sourceRect(selection: selection, display: display),
            CGRect(x: 100, y: 200, width: 300, height: 200)
        )
    }

    func testPixelSizeUsesCapturedDisplayScale() {
        XCTAssertEqual(
            CaptureGeometry.pixelSize(rect: CGRect(x: 0, y: 0, width: 300, height: 200), scale: 2),
            PixelSize(width: 600, height: 400)
        )
    }

    /// Frozen-snapshot crop math (WYSIWYG): same transform as the live capture path
    /// (`sourceRect` × `display.scale`), matching `testCaptureAreaUsesOwningDisplayGeometryAndRequestedOptions`'s
    /// request numbers in `ScreenCaptureTests` — this is the same rect the live path would have
    /// asked ScreenCaptureKit for, applied instead to a pre-captured full-display image.
    func testCropRectForAreaSelectionMatchesLiveCaptureRequestGeometry() {
        let display = DisplayGeometry(
            id: 22,
            frame: CGRect(x: 100, y: 0, width: 80, height: 60),
            scale: 2
        )
        let selection = CGRect(x: 110, y: 10, width: 20, height: 20)

        let cropRect = CaptureGeometry.cropRectForAreaSelection(
            selection,
            display: display,
            imagePixelSize: PixelSize(width: 160, height: 120)
        )

        XCTAssertEqual(cropRect, CGRect(x: 20, y: 60, width: 40, height: 40))
    }

    func testCropRectForAreaSelectionClampsToASmallerThanExpectedSnapshot() {
        let display = DisplayGeometry(
            id: 22,
            frame: CGRect(x: 100, y: 0, width: 80, height: 60),
            scale: 2
        )
        // Full-display pixel rect would be x:20 y:60 w:40 h:40, but the snapshot is narrower and
        // shorter than the display frame implies (e.g. a stale/mismatched image) — the crop rect
        // must clamp to what the image actually has instead of requesting outside its bounds.
        let selection = CGRect(x: 110, y: 10, width: 20, height: 20)

        let cropRect = CaptureGeometry.cropRectForAreaSelection(
            selection,
            display: display,
            imagePixelSize: PixelSize(width: 50, height: 90)
        )

        XCTAssertEqual(cropRect, CGRect(x: 20, y: 60, width: 30, height: 30))
    }

    func testCropRectForAreaSelectionIsEmptyWhenSnapshotDoesNotOverlapSelectionAtAll() {
        let display = DisplayGeometry(
            id: 22,
            frame: CGRect(x: 100, y: 0, width: 80, height: 60),
            scale: 2
        )
        let selection = CGRect(x: 110, y: 10, width: 20, height: 20)

        let cropRect = CaptureGeometry.cropRectForAreaSelection(
            selection,
            display: display,
            imagePixelSize: PixelSize(width: 10, height: 10)
        )

        XCTAssertTrue(cropRect.isNull || cropRect.width <= 0 || cropRect.height <= 0)
    }

    func testSelectionHandleHitTestFindsHandleWithinTolerance() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
        XCTAssertEqual(
            SelectionHandle.hitTest(CGPoint(x: 100, y: 100), in: rect, tolerance: 14),
            .bottomLeft
        )
        XCTAssertEqual(
            SelectionHandle.hitTest(CGPoint(x: 300, y: 175), in: rect, tolerance: 14),
            .right
        )
        XCTAssertNil(SelectionHandle.hitTest(CGPoint(x: 200, y: 175), in: rect, tolerance: 14))
    }

    func testSelectionHandleResizeNormalizesRectWhenDraggedPastOppositeEdge() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)

        // Dragging the top-right corner further out grows the rect from that corner.
        XCTAssertEqual(
            SelectionHandle.topRight.resized(rect, to: CGPoint(x: 400, y: 300)),
            CGRect(x: 100, y: 100, width: 300, height: 200)
        )

        // Dragging the top-right corner's x past the left edge flips the rect.
        XCTAssertEqual(
            SelectionHandle.topRight.resized(rect, to: CGPoint(x: 50, y: 300)),
            CGRect(x: 50, y: 100, width: 50, height: 200)
        )

        // Edge midpoint handles only move one axis.
        XCTAssertEqual(
            SelectionHandle.right.resized(rect, to: CGPoint(x: 350, y: 999)),
            CGRect(x: 100, y: 100, width: 250, height: 150)
        )
    }

    func testCanonicalAreaSelectionRoundTripsOnPrimaryDisplayAtOrigin() {
        let display = DisplayGeometry(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            scale: 2
        )
        let selection = CGRect(x: 100, y: 200, width: 300, height: 150)

        let canonical = CanonicalAreaSelection(selection: selection, display: display)

        XCTAssertEqual(canonical.sourceRect, CaptureGeometry.sourceRect(selection: selection, display: display))
        XCTAssertEqual(
            CaptureGeometry.sourceRect(selection: canonical.selectionRect, display: display),
            canonical.sourceRect
        )
    }

    func testCanonicalAreaSelectionRoundTripsOnOffsetSecondaryDisplayWithNegativeOrigin() {
        // A secondary display positioned above-and-left of the primary display, so both its x
        // and y origins are negative — the case a zero-origin-only test would never exercise.
        let display = DisplayGeometry(
            id: 9,
            frame: CGRect(x: -1920, y: -300, width: 1920, height: 1080),
            scale: 2
        )
        let selection = CGRect(x: -1540, y: -100, width: 300, height: 200)

        let canonical = CanonicalAreaSelection(selection: selection, display: display)

        XCTAssertEqual(canonical.sourceRect, CaptureGeometry.sourceRect(selection: selection, display: display))
        XCTAssertEqual(
            CaptureGeometry.sourceRect(selection: canonical.selectionRect, display: display),
            canonical.sourceRect
        )
        // The inverse-transformed global rect must itself be the same pixels as the original
        // selection's own canonical local rect (both sides of "one canonical computation").
        XCTAssertEqual(
            CanonicalAreaSelection(selection: canonical.selectionRect, display: display).sourceRect,
            canonical.sourceRect
        )
    }

    // MARK: - Display-bounds clamping (resize/move)

    func testClampShrinksAndRepositionsRectThatOverflowsBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

        // Overflows past the right/top edges — clamp slides it back in without resizing.
        XCTAssertEqual(
            CaptureGeometry.clamp(CGRect(x: 900, y: 700, width: 200, height: 200), to: bounds),
            CGRect(x: 800, y: 600, width: 200, height: 200)
        )

        // Negative origin also gets pulled back to the bounds' own origin.
        XCTAssertEqual(
            CaptureGeometry.clamp(CGRect(x: -50, y: -20, width: 100, height: 100), to: bounds),
            CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        // Larger than bounds in both dimensions — shrinks to fit exactly.
        XCTAssertEqual(
            CaptureGeometry.clamp(CGRect(x: -100, y: -100, width: 5000, height: 5000), to: bounds),
            bounds
        )
    }

    // MARK: - toolbarFrame (PLAN.md §8) — all inputs/output are overlay-LOCAL

    func testToolbarFramePrefersBelowSelectionWhenRoomExists() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: 400, y: 400, width: 300, height: 200)
        let toolbarSize = CGSize(width: 360, height: 40)

        let frame = SelectionToolbarPlacement.toolbarFrame(
            selection: selection,
            toolbarSize: toolbarSize,
            visibleBounds: visible
        )

        // Below the selection means smaller y in AppKit's non-flipped, y-up local space.
        XCTAssertLessThan(frame.maxY, selection.minY)
        XCTAssertEqual(frame.midX, selection.midX, accuracy: 0.5)
    }

    func testToolbarFrameFlipsAboveWhenNoRoomBelow() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Selection sits right at the bottom edge — no room below it.
        let selection = CGRect(x: 400, y: 0, width: 300, height: 200)
        let toolbarSize = CGSize(width: 360, height: 40)

        let frame = SelectionToolbarPlacement.toolbarFrame(
            selection: selection,
            toolbarSize: toolbarSize,
            visibleBounds: visible
        )

        XCTAssertGreaterThanOrEqual(frame.minY, selection.maxY)
    }

    func testToolbarFrameFallsBackInsideBottomEdgeForFullDisplaySelection() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Selection spans the entire visible area — neither above nor below fits.
        let selection = visible
        let toolbarSize = CGSize(width: 360, height: 40)

        let frame = SelectionToolbarPlacement.toolbarFrame(
            selection: selection,
            toolbarSize: toolbarSize,
            visibleBounds: visible
        )

        XCTAssertTrue(visible.contains(frame))
    }

    func testToolbarFrameClampsForTinyCornerSelection() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // A tiny selection tucked in the bottom-left corner — below doesn't fit; above does, but
        // horizontal centering would push the toolbar off the left edge without clamping.
        let selection = CGRect(x: 4, y: 4, width: 20, height: 20)
        let toolbarSize = CGSize(width: 360, height: 40)

        let frame = SelectionToolbarPlacement.toolbarFrame(
            selection: selection,
            toolbarSize: toolbarSize,
            visibleBounds: visible
        )

        XCTAssertTrue(visible.contains(frame))
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX)
    }

    func testToolbarFrameFitsTallerToolbarWhenEmojiGridIsVisible() {
        // The emoji tool grows the toolbar (SelectionOverlayToolbarView renders a LazyVGrid below
        // the button row when `activeTool == .emoji`) — the taller size must still fit entirely
        // within `visibleBounds`, same as the normal-height toolbar.
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: 400, y: 400, width: 300, height: 200)
        let tallToolbarSize = CGSize(width: 240, height: 160)

        let frame = SelectionToolbarPlacement.toolbarFrame(
            selection: selection,
            toolbarSize: tallToolbarSize,
            visibleBounds: visible
        )

        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.size, tallToolbarSize)
    }

    func testToolbarFrameUsesOverlayLocalCoordinatesNotGlobal() {
        // A secondary display far from the origin. If the caller (or this function) accidentally
        // fed global screen coordinates in, the result would land far outside a 0-origin overlay
        // — this test fails unless everything stays overlay-local.
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: 400, y: 400, width: 300, height: 200)
        let toolbarSize = CGSize(width: 360, height: 40)

        let frame = SelectionToolbarPlacement.toolbarFrame(
            selection: selection,
            toolbarSize: toolbarSize,
            visibleBounds: visible
        )

        XCTAssertTrue(visible.contains(frame), "toolbarFrame must stay within overlay-local visibleBounds")
    }

    // MARK: - Draft → normalized conversion (PLAN.md §5)

    func testDraftArrowFullyInsideMovedSelectionConvertsWithFlippedNormalizedY() {
        // Selection moved away from the display origin — exercises the general case, not just
        // (0,0)-anchored rects.
        let selectionRect = CGRect(x: 200, y: 100, width: 400, height: 300)
        var draft = OverlayAnnotationDraft()
        draft.items = [
            .arrow(
                start: CGPoint(x: 300, y: 150),
                end: CGPoint(x: 500, y: 350),
                color: .red,
                strokeWidth: 4
            )
        ]

        let payload = OverlayAnnotationConversion.payload(for: draft, selectionRect: selectionRect)

        XCTAssertEqual(payload.items.count, 1)
        guard case let .arrow(arrow) = payload.items[0] else {
            return XCTFail("expected an arrow item")
        }
        // x: (300-200)/400 = 0.25 ; y flips: (rect.maxY(400) - 150)/300 = 0.8333...
        XCTAssertEqual(arrow.start.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(arrow.start.y, 250.0 / 300.0, accuracy: 0.001)
        XCTAssertEqual(arrow.end.x, 0.75, accuracy: 0.001)
        XCTAssertEqual(arrow.end.y, 50.0 / 300.0, accuracy: 0.001)
    }

    func testDraftArrowCrossingSelectionEdgeIsDropped() {
        let selectionRect = CGRect(x: 200, y: 100, width: 400, height: 300)
        var draft = OverlayAnnotationDraft()
        draft.items = [
            .arrow(
                start: CGPoint(x: 300, y: 150),
                // End point lies outside the selection — not intersected, dropped entirely.
                end: CGPoint(x: 900, y: 900),
                color: .red,
                strokeWidth: 4
            )
        ]

        let payload = OverlayAnnotationConversion.payload(for: draft, selectionRect: selectionRect)

        XCTAssertTrue(payload.items.isEmpty)
    }

    func testDraftHighlightCrossingSelectionEdgeIsIntersectedNotDropped() {
        let selectionRect = CGRect(x: 200, y: 100, width: 400, height: 300)
        var draft = OverlayAnnotationDraft()
        // Highlight rect extends 100pt past the selection's right edge (maxX = 600).
        draft.items = [
            .highlight(
                rect: CGRect(x: 500, y: 150, width: 200, height: 100),
                color: .red,
                amount: 0.4
            )
        ]

        let payload = OverlayAnnotationConversion.payload(for: draft, selectionRect: selectionRect)

        XCTAssertEqual(payload.items.count, 1)
        guard case let .highlight(highlight) = payload.items[0] else {
            return XCTFail("expected a highlight item")
        }
        // Clipped rect is x:[500,600] y:[150,250] → normalized width = 100/400 = 0.25.
        XCTAssertEqual(highlight.rect.width, 0.25, accuracy: 0.001)
    }

    func testDraftTextOutlineShapeAndStepAreDroppedUnlessFullyInside() {
        let selectionRect = CGRect(x: 0, y: 0, width: 400, height: 300)
        var draft = OverlayAnnotationDraft()
        draft.items = [
            // Fully inside — kept.
            .text(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), text: "hi", fontSize: 18, color: .red),
            // Crosses the edge — dropped.
            .shape(kind: .rect, rect: CGRect(x: 380, y: 10, width: 50, height: 50), color: .red, strokeWidth: 4),
            // Outside entirely — dropped.
            .step(center: CGPoint(x: 500, y: 500), number: 1)
        ]

        let payload = OverlayAnnotationConversion.payload(for: draft, selectionRect: selectionRect)

        XCTAssertEqual(payload.items.count, 1)
        guard case .text = payload.items[0] else {
            return XCTFail("expected only the fully-inside text item to survive")
        }
    }

    func testDraftPayloadIsEmptyForDegenerateSelectionRect() {
        var draft = OverlayAnnotationDraft()
        draft.items = [.step(center: CGPoint(x: 1, y: 1), number: 1)]

        let payload = OverlayAnnotationConversion.payload(for: draft, selectionRect: .zero)

        XCTAssertTrue(payload.items.isEmpty)
    }

    // MARK: - Multi-display ownership (PLAN.md §7)

    func testSelectionOwnershipFirstClaimWinsAndOthersAreDenied() {
        var ownership = SelectionOwnership()
        XCTAssertTrue(ownership.claim(1))
        XCTAssertTrue(ownership.isOwner(1))
        XCTAssertFalse(ownership.isOwner(2))

        // A second display racing to claim after the first loses.
        XCTAssertFalse(ownership.claim(2))
        XCTAssertTrue(ownership.isOwner(1))

        // The owner re-claiming (e.g. a resize firing another commit) stays owner.
        XCTAssertTrue(ownership.claim(1))
    }

    // MARK: - Keyboard/mouse precedence (PLAN.md §6)

    func testPrecedenceFieldEditorInterceptsEscAndReturnBeforeAnythingElse() {
        // Esc commits (keeps the typed text) rather than discarding it — PLAN.md "Text Input":
        // accidental data loss beats stale cancel semantics.
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .escapeKey,
                isFieldEditorActive: true,
                hasCommittedSelection: true,
                activeTool: .text
            ),
            .commitFieldEditor
        )
        // Return is handled entirely inside the field editor's own `doCommandBy` (newline vs.
        // ⌘-commit) — this precedence chain never sees it live while the field editor is active.
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .returnKey,
                isFieldEditorActive: true,
                hasCommittedSelection: true,
                activeTool: .text
            ),
            .ignore
        )
        // Double-click while a field editor is active does nothing (nothing else fires).
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .doubleClick,
                isFieldEditorActive: true,
                hasCommittedSelection: true,
                activeTool: .select
            ),
            .ignore
        )
    }

    func testPrecedenceEscAlwaysCancelsWholeOperationWhenNoFieldEditor() {
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .escapeKey,
                isFieldEditorActive: false,
                hasCommittedSelection: true,
                activeTool: .arrow
            ),
            .cancelOperation
        )
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .escapeKey,
                isFieldEditorActive: false,
                hasCommittedSelection: false,
                activeTool: .select
            ),
            .cancelOperation
        )
    }

    func testResizeHandleOutranksDrawingToolsSoTheSelectionStaysAdjustable() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)

        for tool in SelectionOverlayTools.ordered {
            XCTAssertEqual(
                SelectionPointerHitTest.target(
                    at: CGPoint(x: rect.maxX, y: rect.minY),
                    committedRect: rect,
                    activeTool: tool,
                    tolerance: 10
                ),
                .resizeHandle(.bottomRight),
                "\(tool.rawValue) must not swallow a click on the resize handle"
            )
        }
    }

    func testPointerFallsBackToDraftMoveOrCreateAwayFromHandles() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)

        XCTAssertEqual(
            SelectionPointerHitTest.target(
                at: CGPoint(x: rect.midX, y: rect.midY),
                committedRect: rect,
                activeTool: .rect,
                tolerance: 10
            ),
            .draft
        )
        XCTAssertEqual(
            SelectionPointerHitTest.target(
                at: CGPoint(x: rect.midX, y: rect.midY),
                committedRect: rect,
                activeTool: .select,
                tolerance: 10
            ),
            .move
        )
        XCTAssertEqual(
            SelectionPointerHitTest.target(
                at: CGPoint(x: rect.maxX + 80, y: rect.maxY + 80),
                committedRect: rect,
                activeTool: .select,
                tolerance: 10
            ),
            .createNew
        )
        XCTAssertEqual(
            SelectionPointerHitTest.target(
                at: CGPoint(x: rect.midX, y: rect.midY),
                committedRect: nil,
                activeTool: .rect,
                tolerance: 10
            ),
            .createNew
        )
    }

    func testCancellingACommittedSelectionNeedsASecondConfirmingRequest() {
        XCTAssertEqual(
            SelectionCancelPolicy.decision(hasCommittedSelection: true, isArmed: false),
            .arm
        )
        XCTAssertEqual(
            SelectionCancelPolicy.decision(hasCommittedSelection: true, isArmed: true),
            .cancel
        )
        // Nothing committed yet — nothing to lose, and no display owns the operation, so every
        // overlay must cancel outright instead of prompting.
        XCTAssertEqual(
            SelectionCancelPolicy.decision(hasCommittedSelection: false, isArmed: false),
            .cancel
        )
    }

    func testPrecedenceReturnConfirmsOnlyWithACommittedSelectionOtherwiseFullScreen() {
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .returnKey,
                isFieldEditorActive: false,
                hasCommittedSelection: true,
                activeTool: .select
            ),
            .confirmSelection
        )
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .returnKey,
                isFieldEditorActive: false,
                hasCommittedSelection: false,
                activeTool: .select
            ),
            .captureFullScreen
        )
    }

    func testPrecedenceDoubleClickConfirmsOnlyInSelectTool() {
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .doubleClick,
                isFieldEditorActive: false,
                hasCommittedSelection: true,
                activeTool: .select
            ),
            .confirmSelection
        )
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .doubleClick,
                isFieldEditorActive: false,
                hasCommittedSelection: true,
                activeTool: .arrow
            ),
            .ignore
        )
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .doubleClick,
                isFieldEditorActive: false,
                hasCommittedSelection: false,
                activeTool: .select
            ),
            .ignore
        )
    }

    // MARK: - Number-key tool shortcuts

    func testToolOrderMatchesTheToolbarRowAndExcludesCrop() {
        // The toolbar renders from this array, so its order *is* the 1-9 mapping. `.crop` is a
        // post-capture editor tool with no overlay button — `allCases` would misnumber everything.
        XCTAssertEqual(
            SelectionOverlayTools.ordered,
            [.select, .arrow, .text, .highlight, .blur, .rect, .ellipse, .steps, .emoji]
        )
        XCTAssertFalse(SelectionOverlayTools.ordered.contains(.crop))
        XCTAssertNil(SelectionOverlayTools.tool(atNumber: 0))
        XCTAssertNil(SelectionOverlayTools.tool(atNumber: SelectionOverlayTools.ordered.count + 1))
    }

    func testMainRowAndKeypadDigitsMapToTheSameToolNumber() {
        let pairs: [(UInt16, UInt16, Int)] = [
            (UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_Keypad1), 1),
            (UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_Keypad5), 5),
            (UInt16(kVK_ANSI_9), UInt16(kVK_ANSI_Keypad9), 9)
        ]

        for (mainRow, keypad, number) in pairs {
            XCTAssertEqual(SelectionOverlayInput(keyCode: mainRow), .toolNumber(number))
            XCTAssertEqual(SelectionOverlayInput(keyCode: keypad), .toolNumber(number))
        }
        // 0 is not a tool position, so it never becomes an overlay input at all.
        XCTAssertNil(SelectionOverlayInput(keyCode: UInt16(kVK_ANSI_0)))
    }

    func testModifiedNumberKeysAreNotToolShortcuts() {
        // ⌘1/⌥1/⌃1 must fall through to the responder chain untouched.
        XCTAssertNil(
            SelectionOverlayInput(keyCode: UInt16(kVK_ANSI_1), hasCommandOptionControl: true)
        )
        // Esc/Return keep working with modifiers held — only digits are gated.
        XCTAssertEqual(
            SelectionOverlayInput(keyCode: UInt16(kVK_Escape), hasCommandOptionControl: true),
            .escapeKey
        )
    }

    func testEachNumberKeySelectsItsToolboxPosition() {
        for (index, tool) in SelectionOverlayTools.ordered.enumerated() {
            XCTAssertEqual(
                SelectionOverlayPrecedence.action(
                    for: .toolNumber(index + 1),
                    isFieldEditorActive: false,
                    hasCommittedSelection: true,
                    activeTool: .select
                ),
                .selectTool(tool)
            )
        }
    }

    func testNumberKeysAreInertWithoutAToolbarOnScreen() {
        // No committed selection means no toolbar, so nothing to switch.
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .toolNumber(2),
                isFieldEditorActive: false,
                hasCommittedSelection: false,
                activeTool: .select
            ),
            .ignore
        )
        // Manual Scroll Capture (PLAN.md §2): `activeTool` must never leave `.select`.
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .toolNumber(2),
                isFieldEditorActive: false,
                hasCommittedSelection: true,
                activeTool: .select,
                allowsQuickAnnotation: false
            ),
            .ignore
        )
        // Typing into a text/emoji field editor: digits belong to the text.
        XCTAssertEqual(
            SelectionOverlayPrecedence.action(
                for: .toolNumber(2),
                isFieldEditorActive: true,
                hasCommittedSelection: true,
                activeTool: .text
            ),
            .ignore
        )
    }
}
