import CoreGraphics
import Carbon
import Foundation

enum CaptureGeometry {
    static func sourceRect(selection: CGRect, display: DisplayGeometry) -> CGRect {
        CGRect(
            x: selection.minX - display.frame.minX,
            y: display.frame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        ).integral
    }

    static func pixelSize(rect: CGRect, scale: CGFloat) -> PixelSize {
        PixelSize(
            width: Int((rect.width * scale).rounded()),
            height: Int((rect.height * scale).rounded())
        )
    }

    /// Clamps `rect` so it stays fully within `bounds` (the owning display's local — 0…width,
    /// 0…height — extent), shrinking it only if it's larger than `bounds` itself. Used to keep
    /// Selection Overlay resize/move from dragging a slice onto another display's pixels.
    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var size = rect.size
        size.width = min(size.width, bounds.width)
        size.height = min(size.height, bounds.height)
        var origin = rect.origin
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    /// Maps a global selection rect to the pixel rect a frozen per-display snapshot must be
    /// cropped to, for the exact same slice a live `captureArea` would have produced (WYSIWYG —
    /// the Selection Overlay's pre-capture snapshot and the final persisted image agree pixel for
    /// pixel). Same transform as the live path (`sourceRect` then × `display.scale`), clamped to
    /// `imagePixelSize` so a stale or unexpectedly-sized snapshot can't crop outside its own
    /// bounds — the result may be zero-size (`.isNull`/empty) if the rects don't overlap at all,
    /// which callers treat as "no usable snapshot" and fall back to a live capture.
    static func cropRectForAreaSelection(
        _ selection: CGRect,
        display: DisplayGeometry,
        imagePixelSize: PixelSize
    ) -> CGRect {
        let local = sourceRect(selection: selection, display: display)
        let pixelRect = CGRect(
            x: local.minX * display.scale,
            y: local.minY * display.scale,
            width: local.width * display.scale,
            height: local.height * display.scale
        ).integral
        let imageBounds = CGRect(x: 0, y: 0, width: imagePixelSize.width, height: imagePixelSize.height)
        return pixelRect.intersection(imageBounds)
    }
}

/// One selection, computed once, holding both spaces it needs to agree on: the integral
/// display-local `sourceRect` ScreenCaptureKit captures (identical to `CaptureGeometry.sourceRect`)
/// and its inverse-transformed `selectionRect` — the exact global AppKit rect that maps back to
/// that same integral local rect. Capture uses `sourceRect`; draft-annotation normalization uses
/// `selectionRect`, so both stay pixel-consistent even on displays with a non-zero origin.
struct CanonicalAreaSelection: Equatable, Sendable {
    let sourceRect: CGRect
    let selectionRect: CGRect
    let display: DisplayGeometry

    init(selection: CGRect, display: DisplayGeometry) {
        let local = CaptureGeometry.sourceRect(selection: selection, display: display)
        sourceRect = local
        self.display = display
        selectionRect = CGRect(
            x: local.minX + display.frame.minX,
            y: display.frame.maxY - local.minY - local.height,
            width: local.width,
            height: local.height
        )
    }
}

/// One of the 8 resize handles drawn around a selection rect (corners + edge midpoints).
enum SelectionHandle: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right

    /// Returns the handle whose point falls within `tolerance` of `point`, if any.
    /// Corners take priority over edge midpoints when zones overlap on tiny rects.
    static func hitTest(_ point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> SelectionHandle? {
        allCases.first { handle in
            let handlePoint = handle.point(in: rect)
            return abs(point.x - handlePoint.x) <= tolerance && abs(point.y - handlePoint.y) <= tolerance
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        }
    }

    /// Resizes `rect` by moving this handle to `location`, normalizing min/max so
    /// dragging past the opposite edge flips the rect instead of producing negative size.
    func resized(_ rect: CGRect, to location: CGPoint) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch self {
        case .topLeft, .left, .bottomLeft:
            minX = location.x
        case .topRight, .right, .bottomRight:
            maxX = location.x
        case .top, .bottom:
            break
        }

        switch self {
        case .topLeft, .top, .topRight:
            maxY = location.y
        case .bottomLeft, .bottom, .bottomRight:
            minY = location.y
        case .left, .right:
            break
        }

        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }
}

/// Where a mouse-down on the Selection Overlay goes. Resize handles outrank Quick Annotation
/// drawing, so the selection stays adjustable while a drawing tool is active — the same chain
/// `SelectionOverlayPrecedence` gives the keyboard, kept out of `mouseDown` so it stays testable.
enum SelectionPointerTarget: Equatable {
    case resizeHandle(SelectionHandle)
    /// Draw/place a Quick Annotation item — any point, inside or outside the selection (items
    /// landing outside are drawn dimmed and dropped at Confirm).
    case draft
    case move
    case createNew
}

enum SelectionPointerHitTest {
    /// - `tolerance`: the handle grab radius; callers tighten it while a drawing tool is active so
    ///   the handles don't carve dead zones out of the selection border.
    static func target(
        at point: CGPoint,
        committedRect: CGRect?,
        activeTool: AnnotationTool,
        tolerance: CGFloat
    ) -> SelectionPointerTarget {
        guard let rect = committedRect else { return .createNew }
        if let handle = SelectionHandle.hitTest(point, in: rect, tolerance: tolerance) {
            return .resizeHandle(handle)
        }
        if activeTool != .select { return .draft }
        return rect.contains(point) ? .move : .createNew
    }
}

/// Esc and the toolbar's ✕ never discard a committed selection outright: the first request arms a
/// confirmation, the second one goes through. Before a selection is committed there is nothing to
/// lose, so cancelling stays immediate — which also keeps every non-owner display's overlay from
/// putting up a prompt of its own (no `SelectionOwnership` claim exists yet at that point).
enum SelectionCancelDecision: Equatable {
    case arm
    case cancel
}

enum SelectionCancelPolicy {
    static func decision(hasCommittedSelection: Bool, isArmed: Bool) -> SelectionCancelDecision {
        hasCommittedSelection && !isArmed ? .arm : .cancel
    }
}

/// Pure placement for the Selection Overlay's floating toolbar (PLAN.md §8). All inputs and the
/// output are in overlay-LOCAL coordinates — the caller converts `NSScreen.visibleFrame` to
/// overlay-local once before calling; this function never sees or returns global screen coords.
enum SelectionToolbarPlacement {
    static func toolbarFrame(
        selection: CGRect,
        toolbarSize: CGSize,
        visibleBounds: CGRect,
        spacing: CGFloat = 10
    ) -> CGRect {
        // Overlay coords are AppKit non-flipped (y-up): "below" the selection is the smaller-y
        // side, "above" is the larger-y side.
        let belowY = selection.minY - spacing - toolbarSize.height
        let aboveY = selection.maxY + spacing
        let preferredY: CGFloat
        if belowY >= visibleBounds.minY {
            preferredY = belowY
        } else if aboveY + toolbarSize.height <= visibleBounds.maxY {
            preferredY = aboveY
        } else {
            // Neither side fits (selection spans the full display) — fall back to hugging the
            // selection's own bottom edge; the final clamp keeps it inside `visibleBounds`.
            preferredY = selection.minY + spacing
        }

        let centeredX = selection.midX - toolbarSize.width / 2
        let maxX = max(visibleBounds.minX, visibleBounds.maxX - toolbarSize.width)
        let maxY = max(visibleBounds.minY, visibleBounds.maxY - toolbarSize.height)
        return CGRect(
            x: min(max(centeredX, visibleBounds.minX), maxX),
            y: min(max(preferredY, visibleBounds.minY), maxY),
            width: toolbarSize.width,
            height: toolbarSize.height
        )
    }
}

/// Quick Annotation draft items held by the Selection Overlay: unclamped, display-global point
/// coordinates (same convention as `AreaSelection.rect`), never persisted, never leaving the
/// overlay. Converted to a `PendingAnnotationPayload` exactly once, at Confirm, via
/// `OverlayAnnotationConversion` (docs/adr/0001, PLAN.md §5).
struct OverlayAnnotationDraft: Equatable {
    var items: [AnnotationDraftItem] = []
}

/// Converts an `OverlayAnnotationDraft` into normalized `AnnotationItem`s against `selectionRect`
/// (the same global-coords rect `CanonicalAreaSelection` pairs with its integral `sourceRect`).
/// Per-type out-of-selection rules (PLAN.md §5): highlight/blur rects are intersected with
/// `selectionRect`; arrow/text/shape/step are kept only if fully inside, otherwise dropped.
enum OverlayAnnotationConversion {
    static func isRetained(_ item: AnnotationDraftItem, in selectionRect: CGRect) -> Bool {
        switch item {
        case let .arrow(start, end, _, _):
            return selectionRect.contains(start) && selectionRect.contains(end)
        case let .text(bounds, _, _, _):
            return selectionRect.contains(bounds)
        case let .highlight(rect, _, _), let .blur(rect, _, _):
            let clipped = rect.intersection(selectionRect)
            return !clipped.isNull && clipped.width > 0 && clipped.height > 0
        case let .shape(_, rect, _, _):
            return selectionRect.contains(rect)
        case let .step(center, _):
            return selectionRect.contains(center)
        }
    }

    /// - `styleScale`: the capture display's backing scale factor. Draft items carry lengths in
    ///   display POINTS (that's the space the overlay draws in), while `AnnotationRenderer` applies
    ///   them as image PIXELS against a capture that is `points × scale` big. Without this
    ///   conversion a 4-point stroke bakes as 4 pixels — half its previewed thickness on a 2x
    ///   display — breaking the frozen-overlay WYSIWYG promise. Only true lengths convert;
    ///   `highlight`'s amount is an opacity and steps size themselves off the image, so both are
    ///   already resolution-independent.
    static func payload(
        for draft: OverlayAnnotationDraft,
        selectionRect: CGRect,
        styleScale: CGFloat = 1
    ) -> PendingAnnotationPayload {
        guard selectionRect.width > 0, selectionRect.height > 0 else {
            return PendingAnnotationPayload(items: [])
        }
        let items: [AnnotationItem] = draft.items.compactMap { item in
            guard isRetained(item, in: selectionRect) else { return nil }
            return normalizedItem(for: item, in: selectionRect, styleScale: styleScale)
        }
        return PendingAnnotationPayload(items: items)
    }

    private static func normalizedItem(
        for item: AnnotationDraftItem,
        in rect: CGRect,
        styleScale: CGFloat
    ) -> AnnotationItem {
        func scaled(_ length: Double) -> Double { length * Double(styleScale) }

        switch item {
        case let .arrow(start, end, color, strokeWidth):
            return .arrow(ArrowAnnotation(
                id: UUID(),
                start: normalizedPoint(start, in: rect),
                end: normalizedPoint(end, in: rect),
                color: color,
                strokeWidth: scaled(strokeWidth)
            ))
        case let .text(bounds, text, fontSize, color):
            return .text(TextAnnotation(
                id: UUID(),
                bounds: normalizedRect(bounds, in: rect),
                text: text,
                fontSize: scaled(fontSize),
                color: color
            ))
        case let .highlight(itemRect, color, amount):
            return .highlight(RectAnnotation(
                id: UUID(),
                rect: normalizedRect(itemRect.intersection(rect), in: rect),
                color: color,
                amount: amount
            ))
        case let .blur(itemRect, color, amount):
            return .blur(RectAnnotation(
                id: UUID(),
                rect: normalizedRect(itemRect.intersection(rect), in: rect),
                color: color,
                amount: scaled(amount)
            ))
        case let .shape(kind, itemRect, color, strokeWidth):
            return .shape(ShapeAnnotation(
                id: UUID(),
                kind: kind,
                rect: normalizedRect(itemRect, in: rect),
                color: color,
                strokeWidth: scaled(strokeWidth)
            ))
        case let .step(center, number):
            return .step(StepAnnotation(
                id: UUID(),
                center: normalizedPoint(center, in: rect),
                number: number
            ))
        }
    }

    /// `rect`'s top edge is at `maxY` in AppKit's y-up global space; normalized y=0 is the top of
    /// the image, so it flips.
    private static func normalizedPoint(_ point: CGPoint, in rect: CGRect) -> NormalizedPoint {
        NormalizedPoint(
            x: Double((point.x - rect.minX) / rect.width),
            y: Double((rect.maxY - point.y) / rect.height)
        )
    }

    private static func normalizedRect(_ subRect: CGRect, in rect: CGRect) -> NormalizedRect {
        NormalizedRect(
            x: Double((subRect.minX - rect.minX) / rect.width),
            y: Double((rect.maxY - subRect.maxY) / rect.height),
            width: Double(subRect.width / rect.width),
            height: Double(subRect.height / rect.height)
        )
    }
}

/// Multi-display ownership for an in-progress area-selection operation (PLAN.md §7). The first
/// display to commit a selection rect claims ownership for the remainder of the operation — there
/// is no transfer or release mid-operation; ownership only ends when the whole operation ends
/// (Confirm, Esc, or toolbar Cancel tearing down every overlay).
struct SelectionOwnership: Equatable {
    private(set) var ownerDisplayID: CGDirectDisplayID?

    /// Attempts to claim ownership for `displayID`. Returns `true` if this call owns it now
    /// (newly claimed, or `displayID` already owned it); `false` if another display got there
    /// first, in which case the caller must go inert.
    mutating func claim(_ displayID: CGDirectDisplayID) -> Bool {
        if let ownerDisplayID {
            return ownerDisplayID == displayID
        }
        ownerDisplayID = displayID
        return true
    }

    func isOwner(_ displayID: CGDirectDisplayID) -> Bool {
        ownerDisplayID == displayID
    }
}

/// The Selection Overlay's single keyboard/mouse precedence chain (PLAN.md §6). `SelectionOverlayView`
/// calls this instead of encoding the chain ad hoc across `keyDown`/`mouseDown` so it stays one
/// extractable, testable decision point.
enum SelectionOverlayInput: Equatable {
    case escapeKey
    case returnKey
    case doubleClick
    /// A bare number key, 1-9 — the toolbar tool at that 1-based position.
    case toolNumber(Int)

    /// - `hasCommandOptionControl`: ⌘/⌥/⌃ held. Number keys only pick tools unmodified, so ⌘1 and
    ///   friends fall through to the responder chain untouched.
    init?(keyCode: UInt16, hasCommandOptionControl: Bool = false) {
        switch keyCode {
        case UInt16(kVK_Escape): self = .escapeKey
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter): self = .returnKey
        default:
            guard !hasCommandOptionControl,
                  let number = SelectionOverlayTools.number(forKeyCode: keyCode) else { return nil }
            self = .toolNumber(number)
        }
    }
}

/// The Selection Overlay toolbar's tool row in display order, which is also the number-key
/// mapping: key N picks the Nth tool. `SelectionOverlayToolbarView` renders from this same array
/// so the buttons and the shortcuts can never drift apart. `.crop` is deliberately absent — it is
/// a post-capture editor tool with no overlay affordance, so `AnnotationTool.allCases` is the
/// wrong source here.
enum SelectionOverlayTools {
    static let ordered: [AnnotationTool] = [
        .select, .arrow, .text, .highlight, .blur, .rect, .ellipse, .steps, .emoji
    ]

    /// Main-row and keypad digits both map, matching how `.returnKey` accepts either Enter.
    private static let numbersByKeyCode: [UInt16: Int] = [
        UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3,
        UInt16(kVK_ANSI_4): 4, UInt16(kVK_ANSI_5): 5, UInt16(kVK_ANSI_6): 6,
        UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8, UInt16(kVK_ANSI_9): 9,
        UInt16(kVK_ANSI_Keypad1): 1, UInt16(kVK_ANSI_Keypad2): 2, UInt16(kVK_ANSI_Keypad3): 3,
        UInt16(kVK_ANSI_Keypad4): 4, UInt16(kVK_ANSI_Keypad5): 5, UInt16(kVK_ANSI_Keypad6): 6,
        UInt16(kVK_ANSI_Keypad7): 7, UInt16(kVK_ANSI_Keypad8): 8, UInt16(kVK_ANSI_Keypad9): 9
    ]

    static func number(forKeyCode keyCode: UInt16) -> Int? {
        numbersByKeyCode[keyCode]
    }

    /// `number` is 1-based as typed; `nil` for anything outside the row.
    static func tool(atNumber number: Int) -> AnnotationTool? {
        guard number >= 1, number <= ordered.count else { return nil }
        return ordered[number - 1]
    }
}

enum SelectionOverlayAction: Equatable {
    case cancelFieldEditor
    case commitFieldEditor
    case confirmSelection
    case captureFullScreen
    case cancelOperation
    case selectTool(AnnotationTool)
    case ignore
}

enum SelectionOverlayPrecedence {
    /// - `isFieldEditorActive`: a text/emoji field editor currently owns focus — it intercepts
    ///   Esc/Return first and nothing else fires.
    /// - `activeTool`: double-click only confirms while `.select` (Select/Move) is active; other
    ///   tools treat a double-click as two clicks of that tool.
    /// - `allowsQuickAnnotation`: `false` for the Manual Scroll Capture intent, where the toolbar
    ///   never appears and `activeTool` must never leave `.select` — number keys go inert there.
    static func action(
        for input: SelectionOverlayInput,
        isFieldEditorActive: Bool,
        hasCommittedSelection: Bool,
        activeTool: AnnotationTool,
        allowsQuickAnnotation: Bool = true
    ) -> SelectionOverlayAction {
        if isFieldEditorActive {
            switch input {
            // Esc now commits (keeps the typed text) instead of discarding it (PLAN.md "Text
            // Input" — accidental data loss beats stale cancel semantics). Return is handled
            // entirely inside the field editor's own `doCommandBy` (newline vs. ⌘-commit), so this
            // precedence chain never sees it live — kept `.ignore` here for completeness/tests.
            // Digits belong to whoever is typing, and the field editor is first responder anyway.
            case .escapeKey: return .commitFieldEditor
            case .returnKey: return .ignore
            case .doubleClick: return .ignore
            case .toolNumber: return .ignore
            }
        }
        switch input {
        case .escapeKey:
            return .cancelOperation
        case .returnKey:
            return hasCommittedSelection ? .confirmSelection : .captureFullScreen
        case .doubleClick:
            guard hasCommittedSelection, activeTool == .select else { return .ignore }
            return .confirmSelection
        case let .toolNumber(number):
            // Same gate as the toolbar itself: no toolbar on screen, no tool switching.
            guard allowsQuickAnnotation, hasCommittedSelection,
                  let tool = SelectionOverlayTools.tool(atNumber: number) else { return .ignore }
            return .selectTool(tool)
        }
    }
}
