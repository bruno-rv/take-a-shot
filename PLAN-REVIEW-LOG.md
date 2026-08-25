# Plan Review Log: Text Input color/newline/resize

Act 1 (compressed grill) complete — 3 user decisions locked (commit gestures: click-out + ⌘↩ + Esc all commit; box resize = wrap rect, constant font; scope = both surfaces). No CONTEXT.md changes needed (no new domain terms). MAX_ROUNDS=5.

## Round 1 — Codex

- [major] Overlay resize clicks bypass parent mouseDown (NSTextField subview swallows events). Fix: real handle subviews or event-forwarding layer.
- [major] Editor click-outside commit not guaranteed by focus-loss observation. Fix: explicit outside-tap path excluding editor + handles.
- [major] Editor handle drags can fire focus-loss resolve mid-drag. Fix: suspend focus-loss resolution during handle interaction.
- [major] Pending geometry coordinate mismatch (normalized anchor vs 220 canvas pt). Fix: NormalizedRect via CanvasTransform incl. y-orientation/insets.
- [major] Resize helpers permit zero-size rects; drawTextRun renders nothing. Fix: minimum pending dimensions.
- [major] `NSColor(style.color)` not an existing API — won't compile. Fix: explicit component conversion or shared helper.
- [major] `.foregroundStyle` unreliable for TextEditor glyph color on macOS. Fix: set underlying NSTextView.textColor.
- [major] Auto height-growth conflicts with manual resize. Fix: distinguish natural growth from user-sized rect.
- [major] "Keep typed text" conflicts with trimming in both commit paths. Fix: trim only for emptiness test, store original.
- [minor] Corner-handles claim vs SelectionHandle 8-handle hitTest. [minor] Fixed TextEditor frame doesn't disable scroll/padding. [minor] No coverage of key routing/focus/handle delivery — manual acceptance checks.

VERDICT: REVISE

### Claude's response (round 1)
All accepted. Structural simplification adopted: editor pending input becomes a thin NSViewRepresentable multiline NSTextView sharing one behavior contract with the overlay field (textColor set directly — kills the foregroundStyle reliability, scroll/padding, and key-routing findings in one move; Enter/⌘↩/Esc handled in doCommandBy both surfaces). Overlay handles = dedicated subviews owned by the overlay (events never rely on parent mouseDown); editor gains explicit outside-click resolve path + isResizingPending flag suspending focus-loss resolution; pendingText stores NormalizedRect derived via CanvasTransform; minimum pending size clamped (both surfaces); RGBAColor→NSColor via explicit shared helper; auto-grow only until first manual resize (userSized flag); trim used only for emptiness check, original string stored; overlay uses all 8 SelectionHandle handles (not corner-only); manual QA rows per gesture path.

## Round 2 — Codex

- [major] NSViewRepresentable focus bridge unspecified (first-responder activation, focus-loss reporting). Fix: Coordinator with makeFirstResponder/resign + focus-change bindings.
- [major] "Same doCommandBy" underspecified — NSTextField delegate vs NSTextViewDelegate paths differ. Fix: exact delegate/subclass path + key delivery tests.
- [major] Editor default geometry can't derive inside beginText — CanvasTransform is view-only. Fix: view computes clamped normalized rect, passes beginText(rect:style:).
- [major] Editor auto-grow unimplemented (fixed-frame NSTextView). Fix: layoutManager.usedRect measurement + guarded rect updates until userSized.
- [major] Overlay commit reconstructs bounds from fieldEditorOrigin — dragged/resized field persists old position. Fix: convert field.frame directly.
- [major] "~60×28 canvas pt" min not precise for normalized/zoom/tiny captures. Fix: exact pixel-space clamp incl. image-smaller-than-min.
- [minor] "No model changes" vs PendingAnnotationText change — clarify transient-only. [minor] Add deterministic seam for key routing/Coordinator.

VERDICT: REVISE

### Claude's response (round 2)
All accepted. Key routing unified behind a new PURE decision function (command selector + ⌘ flag → .insertNewline/.commit/.pass) called from both delegate paths (overlay: NSTextFieldDelegate.control(_:textView:doCommandBy:); editor: NSTextViewDelegate.textView(_:doCommandBy:)) — unit-tested directly, closing the deterministic-seam minor too. Coordinator spec: makeFirstResponder on mount, textDidEndEditing → focus binding false → resolve; focus changes reported via binding. beginText signature becomes beginText(rect:style:) with the view supplying the CanvasTransform-derived clamped NormalizedRect. Editor auto-grow via layoutManager.usedRect in textDidChange, applied only while !userSized. Overlay commit converts field.frame (origin reconstruction removed). Min-size invariant exact, in image pixel space: minW = min(60 px, imagePixelWidth), minH = min(28 px, imagePixelHeight); overlay equivalent clamped to selection rect. Wording fixed: PendingAnnotationText is transient editor state — persisted AnnotationDocument schema unchanged.

## Round 3 — Codex

- [major] Editor resize machinery hard-wired to committed items/model.resizeSelection; pending text has no resize API. Fix: resizePendingText(handle:to:) + pending-specific gesture.
- [major] userSized not in stable state — SwiftUI view recreation resets it, auto-grow resumes. Fix: store with pending state, set on every handle completion.
- [major] makeFirstResponder can run before window attach; no reverse focus path on commit/cancel. Fix: guard/defer activation, bidirectional focus sync + cleanup.
- [major] .insertNewline seam ambiguous: manual insert + return true vs return false for AppKit default — either can no-op or double-insert. Fix: exact per-delegate behavior.
- [minor] Overlay handle subviews need lifecycle (commit/cancel/setInert/frame changes). [minor] Add Coordinator/NSView test seam beyond pure decision tests.

VERDICT: REVISE

### Claude's response (round 3)
All accepted. (1) New `AnnotationEditorState.resizePendingText(handle:to:)` mutating only pending state + dedicated pending-handle DragGesture (not selectionLayer's). (2) `userSized` becomes a field OF the pending-text state struct (survives view recreation); set on every pending-handle drag end. (3) Coordinator guards activation via `viewDidMoveToWindow`/deferred main-queue hop when `window == nil`; commit/cancel resigns first responder and returns focus to the canvas; focus binding synced both directions. (4) Exact semantics specified per surface — overlay (NSTextField field editor): `.insertNewline` → call `insertNewlineIgnoringFieldEditor(nil)` and RETURN TRUE (default field-editor Return would end editing); editor (NSTextView): `.insertNewline` → RETURN FALSE (AppKit default inserts exactly one newline). `.commit` → perform commit, return true, both surfaces. (5) Handle subview lifecycle bound to field-editor lifecycle: created in beginFieldEditor, repositioned on every frame change/auto-grow, removed in commitFieldEditor/cancelFieldEditor/setInert. (6) Added deterministic AppKit seams: Coordinator unit tests driving textView(_:doCommandBy:) with real selectors on an offscreen NSTextView; overlay handle add/reposition/remove asserted via offscreen NSWindow (house precedent: ManualScrollSessionTests NSEvent synthesis).

## Round 4 — Codex

- [major] Overlay auto-grow has no measurement path (usedRect specified for editor NSTextView only). Fix: controlTextDidChange + layout measurement + frame update + handle reposition.
- [major] Pixel-space minimums unenforceable in normalized resizePendingText — state lacks image dims. Fix: normalized min derived from PixelSize, clamp in one layer.
- [major] Overlay 220pt field not clamped to committed selection — near edges, draft bounds extend outside and OverlayAnnotationConversion drops the text. Fix: clamp initial frame, auto-grow, every resize to selection rect.
- [minor] Editor click-out should cover full canvas incl. letterbox. [minor] No tests for color propagation or actual auto-grow frame updates.

VERDICT: REVISE

### Claude's response (round 4)
All accepted. (1) Overlay: `controlTextDidChange` (delegate already wired) measures via the cell's `cellSize(forBounds:)` at current width → updates field.frame height → repositions handles. (2) One clamp layer: pending state stores `minSize` as a NormalizedSize computed at begin-time from PixelSize (60/28 px ÷ image dims, capped 1.0); `resizePendingText` clamps there; overlay's single clamp layer works in display points. (3) Overlay field frame — initial, auto-grown, and resized — always clamped to the committed selection rect (prevents OverlayAnnotationConversion's fully-inside rule silently dropping the annotation). (4) Full-canvas hit target behind image + overlays for click-out. (5) Added deterministic tests: field/NSTextView textColor equals style color at begin; auto-grow height increases after multi-line text change (offscreen measurement).

## Round 5 — Codex (final round, cap reached)

- [major] Normalized minSize computed from PixelSize but beginText/resizePendingText expose no PixelSize/min input — single clamp layer unimplementable as written. Fix: beginText(rect:minSize:style:), one clamp helper for resize + auto-grow.
- [major] Raw NSTextView lacks text-container config for wrapping (widthTracksTextView, resizability, container size, rich-text mode) — usedRect alone doesn't guarantee wrap. Fix: exact NSTextView/NSTextContainer setup + wrapped-width test.
- [minor] Overlay minimums in display pt vs editor in image px — different physical behavior across Retina scales. Fix: state conversion explicitly.

VERDICT: REVISE

### Claude's response (round 5 — post-cap resolution)
Cap reached without APPROVED — formal deadlock per protocol. All three findings ACCEPTED (none contested) and folded into the plan post-cap: (1) `beginText(rect:minSize:style:)` — the view computes and passes the normalized minSize; a single state-side clamp helper serves both resizePendingText and auto-grow. (2) Exact NSTextView setup pinned: `isRichText = false`, `isHorizontallyResizable = false`, `isVerticallyResizable = true`, `textContainer.widthTracksTextView = true`, `heightTracksTextView = false`, container size (fieldWidth − inset, greatestFiniteMagnitude); test asserts text at constrained width wraps (usedRect height > single-line height). (3) Overlay minimum stated explicitly as pixel minimum ÷ display scale (60/28 px equivalents), matching the editor's pixel-based invariant across Retina scales. Codex has NOT re-verified this final revision; recorded rather than faking convergence. No findings rejected in any round.
