# Quick Annotation — Manual QA Checklist

Scope: PLAN.md §5–§9 (overlay annotation draft, keyboard/mouse precedence, multi-display
ownership, toolbar placement, confirm/pipeline/persistence). Automated coverage lives in
`CaptureGeometryTests`, `AnnotationModelTests`, `ScreenCaptureTests`, `CaptureLibraryTests`, and
`AppRuntimeTests`. This checklist covers what automated tests structurally can't: live AppKit
event routing, real window server behavior, and actual hardware (Retina/multi-display).

## How this pass was run

`make build` succeeded and installed to `/Applications/TakeAShot.app`. The app was launched
(`open /Applications/TakeAShot.app`) and confirmed running as a background process with no crash.

**Everything beyond that was intentionally NOT exercised in this session.** The machine this ran
on is the developer's live, actively-in-use interactive session (multiple open Claude Code windows,
a pending confirmation prompt awaiting real keyboard input at the time of this pass). Quick
Annotation's overlay takes over the whole screen and captures global mouse drags and Esc/Return
keystrokes; driving that via `cliclick`/`osascript` on a session someone is actively using risks
misfiring into their real work (e.g. answering an unrelated prompt) and was judged not safe to
automate here. The scenarios below are left for a human pass in a dedicated session, or a fork
running on an isolated machine/VM.

| # | Scenario | Result | Notes |
|---|----------|--------|-------|
| 1 | App builds via `make build`, installs to `/Applications`, launches without crashing | **Pass** | Verified: process running post-launch, no crash log. |
| 2 | Field-editor focus: clicking Text/Emoji tool then clicking the overlay opens a borderless-window-hosted `NSTextField` that actually receives keystrokes (the `.screenSaver`-level, non-activating overlay is exactly the kind of window that historically drops first-responder focus) | Not verified | Requires live interaction; see note above. |
| 3 | Enter commits the text/emoji field; Esc cancels only the field (selection/operation stay alive); clicking outside the field (focus loss) also commits | Not verified | Same. |
| 4 | Emoji tool: default emoji pre-filled, editable, popover-style entry doesn't block clicks reaching the field | Not verified | Same. |
| 5 | Toolbar hit-confinement: clicking a toolbar button (tool/palette/undo/cancel/confirm) does not also start a drag on the overlay underneath it | Not verified | Same. |
| 6 | Toolbar placement extremes: tiny selection, corner selection, selection touching a screen edge, full-display selection — toolbar always lands fully on-screen and never overlaps the selection | Not verified | Covered at the unit level by `CaptureGeometryTests` (`testToolbarFrame*`); live compositing/DPI rounding not exercised. |
| 7 | 1x display rendering: drawn items (arrow/highlight/blur/rect/ellipse/step) look correct at 1x scale | **Needs re-test** | Machine has one 1920×1080 display; scale factor not confirmed as exactly 1x vs 2x-then-downscaled without live inspection. Additionally: the live blur draft preview previously drew nothing (`AnnotationRenderer.blurRect`'s `context.makeImage()` returns nil inside the overlay's layer-backed live-draw context, silently swallowed by `try?`) — now fixed by sampling the frozen snapshot directly instead of reading the context back (`AnnotationRenderer.drawDraft`'s `source:` parameter). Unit-covered (`ImagePipelineTests.testDraftBlurPreviewSourcesPixelsFromSnapshotNotContextReadback`); the live on-screen preview while dragging a blur item is unverified and should be specifically re-checked. |
| 8 | 2x (Retina) display rendering: same, at HiDPI | **Not testable on this machine** | No Retina display attached. |
| 9 | Multi-display: dragging a selection on a second display while a partial drag exists on the first; first commit claims ownership; losing display's overlay goes inert (dimmed scrim, ignores input, clears its partial rect) | **Not testable on this machine** | Single-display hardware only. Ownership claim/deny/no-partial-release logic has direct unit coverage (`testSelectionOwnershipFirstClaimWinsAndOthersAreDenied` in `CaptureGeometryTests`), but the live AppKit wiring (`ScreenCaptureController.claimSelectionOwnership`, `SelectionOverlayView.setInert`) is not exercised end-to-end here. |
| 10 | Esc always tears down the entire operation on every display (no partial release, no hand-off) | Not verified live | `dismissOverlays()`/`cancelCurrentOperation()` order is unchanged from the pre-existing (already-shipped) cancel path; only the new ownership/inert state is unverified live. |
| 11 | Cmd+Z pops the last draft item while drafting, before Confirm | Not verified | Same. |
| 12 | Per-type out-of-selection rules while dragging: an arrow/text/shape/step that would currently be dropped previews dimmed; a highlight/blur that crosses the edge previews normally (it gets clipped, not dropped) | Not verified live | Conversion rules (intersect vs. drop) have full unit coverage in `CaptureGeometryTests`; only the live dimmed-preview rendering is unverified. |
| 13 | Confirm produces a Post-Capture panel preview showing the Baked (annotated) image, not the raw screenshot | Not verified live | Seam covered by `AppRuntimeTests.testPresentPostCaptureUsesBakedRenderedImageForPreviewWhenProvided`; live panel rendering not inspected. |
| 14 | A plain (no-annotation) area capture behaves exactly as before — same panel, same Copy/Save output | Not verified live | Byte-identical-path guarantee covered by `ScreenCaptureTests.testCaptureAreaWithEmptyPayloadNeverBakesAndPublishesNilDocument`, `CaptureLibraryTests.testPersistWithoutRenderedImageDerivesThumbnailFromRawImage`, and the full pre-existing empty-capture test suite (all still green). |

## Recommendation

Re-run this checklist by hand in a dedicated session (ideally with a second, Retina-capable
display attached) before shipping Quick Annotation. Everything that unit tests can pin down
(coordinate math, precedence decisions, ownership transitions, persistence ordering/atomicity,
the empty-payload identical-behavior guarantee, and the preview-uses-Baked-render seam) is covered
and green; what's left is genuinely live-AppKit/hardware behavior that only a human at the keyboard
can confirm.
