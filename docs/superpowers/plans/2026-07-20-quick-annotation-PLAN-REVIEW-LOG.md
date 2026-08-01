# Plan Review Log: Quick Annotation (Flameshot-style overlay toolbar)
Act 1 (grill-with-docs) complete — plan locked, CONTEXT.md + ADR-0001 created. MAX_ROUNDS=5.

## Round 1 — Codex
VERDICT: REVISE — 14 findings (verbatim critique preserved below):

The plan is not implementation-ready. Material flaws:

1. **Coordinate-model contradiction:** `PLAN.md:9,16` and ADR 0001 claim `AnnotationItem`s use overlay-local points, but `NormalizedPoint`/`NormalizedRect` clamp values to 0–1 (`CaptureModels.swift:209-230`), corrupting point coordinates immediately.  
   **Fix:** Store pre-capture items in an unclamped `OverlayAnnotationDraft`, converting once to normalized `AnnotationItem`s at Confirm, and update the ADR.

2. **Renderer API does not exist:** The plan assumes reusable per-item CGContext drawing, but `AnnotationRenderer` exposes only `render(source:document:)`; item drawing and coordinate helpers are private (`ImagePipeline.swift:81-283`).  
   **Fix:** Add a documented CGContext document/item rendering API with an explicit coordinate transform and pixel-alignment tests.

3. **Annotation Document cannot traverse capture:** The overlay callback and `AreaSelection` carry only geometry, `captureArea` publishes only an image, and `receiveCapture` creates a new empty document (`CaptureController.swift:316-413,1100-1114`; `Models.swift:86-95,407-419`).  
   **Fix:** Define one capture envelope containing selection and annotation draft/document, then persist and publish that exact document.

4. **Persistence/Bake flow is wrong:** `CapturePersisting` accepts only `CapturedImage`, while the existing transactional `persist(image:annotations:)` path is unused and thumbnails are generated from the raw image (`CaptureLibrary.swift:373-475`).  
   **Fix:** Persist image, Annotation Document, and annotated thumbnail atomically through the existing annotation-aware store before publication.

5. **Post-publication attachment creates a durability race:** Annotation saving is asynchronous (`Models.swift:937-956`), so UI/actions can observe an empty document or the app can exit before it is saved.  
   **Fix:** Complete the image/document/thumbnail transaction before publishing the capture or triggering clipboard/panel actions.

6. **`AreaSelection.localRect` is fictitious:** The plan and ADR rely on that convention, but `AreaSelection` stores only a global `rect`; `localRect` is merely an initializer argument (`Models.swift:86-95`).  
   **Fix:** Add an explicit display-local geometry API or rewrite the conversion design around the existing global rectangle.

7. **Multi-display ownership is unspecified:** Every display currently has an independently active overlay capable of selecting and confirming (`CaptureController.swift:489-526,1186-1276`).  
   **Fix:** Add controller-owned active-display state broadcast to all overlays, with deterministic ownership transfer/cancellation behavior.

8. **Toolbar placement guarantee is impossible:** A full-display selection leaves no exterior space, contradicting “never overlaps the selection interior.”  
   **Fix:** Specify a fallback such as a separate panel or capture-excluded in-selection toolbar and test full-screen, tiny, and edge selections.

9. **Resize semantics can corrupt annotations:** Selection resizing is not display-clamped, capture later rejects out-of-bounds rectangles, and normalization silently clamps excluded annotation geometry (`CaptureController.swift:1219-1235`; `ScreenCaptureEngine.swift:131-138`).  
   **Fix:** Clamp selection geometry and explicitly choose whether outlying annotations prevent resize, clip, or are discarded.

10. **Step Badge has no editable size:** `StepAnnotation` contains only center and number, yet editor resizing/hit-testing requires bounds (`AnnotationEditor.swift:887-910,1015-1210`).  
    **Fix:** Add normalized diameter/radius or declare badges fixed-size and remove resize handles, including Retina/export scaling rules.

11. **Keyboard cancellation is ambiguous:** Return is discussed, but Esc currently means both cancel pending text and cancel area capture (`README.md:54-56`; `CaptureController.swift:1260-1265`).  
    **Fix:** Define responder precedence: first Esc cancels active text/popovers; a subsequent Esc cancels Quick Annotation and capture.

12. **Blur can be mistaken for secure redaction:** The application preserves and can reveal the unannotated original (`README.md:63-65,91-98`), so sensitive blurred pixels remain recoverable.  
    **Fix:** Label Blur as non-redacting or implement a separate irreversible redaction workflow that does not retain source pixels.

13. **“Reuse editor palette” is not implementable as written:** The palette is private to `MacInspector` (`MacContentView.swift:673-679`), encouraging duplication and drift.  
    **Fix:** Extract a shared palette/style definition with accessibility labels for both editor and Selection Overlay.

14. **The test plan ignores the highest-risk integrations:** It omits persistence rollback, annotated clipboard/panel output, reopen behavior, multi-display ownership, AppKit focus, Esc/Return routing, toolbar event interception, and preview-vs-Bake alignment.  
    **Fix:** Add controller/persistence integration tests and an AppKit overlay harness covering those flows before implementation is accepted.

VERDICT: REVISE
### Claude's response (round 1)
Accepted 13/14 outright, 1 partially:
1. Accepted — draft type `OverlayAnnotationDraft`, unclamped global coords; conversion once at Confirm. ADR-0001 updated.
2. Accepted — new public renderer entry point with coordinate-transform contract + alignment tests (Approach §2).
3. Accepted — capture envelope (selection + document) threaded through overlay → controller → pipeline → receiveCapture (§9).
4. Accepted — atomic persist via existing `persist(image:annotations:)` incl. annotated thumbnail (§9).
5. Accepted — transaction completes before publication/clipboard/panel (§9).
6. Accepted — dropped fictitious `localRect`; draft uses global coords matching `AreaSelection.rect` (§5).
7. Accepted — controller-owned active-display ownership, broadcast to overlays, deterministic claim/release (§7).
8. Accepted — placement fallback inside selection bottom edge; safe because overlay hides pre-capture (§8).
9. Accepted — selection clamped to display bounds; outlying annotations clipped at Bake, never discarded (§5).
10. Accepted — Step Badges fixed-size (fraction of min image dimension), no resize handles (§1).
11. Accepted — explicit Esc/Return precedence chain, README documented, logic unit-tested (§6, §10).
12. Accepted — Blur labeled cosmetic/non-redacting in help text; irreversible redaction explicitly out of scope.
13. Accepted — shared palette extracted from MacInspector (§4).
14. Partially accepted — added persistence-rollback, envelope-seeding, ownership, Esc/Return, preview-vs-Bake alignment tests (§10). AppKit overlay UI harness rejected for v1 (cost ≫ value for a solo project); toolbar interception + focus covered by a documented manual checklist instead.

## Round 2 — Codex
VERDICT: REVISE — 10 findings (full critique in /tmp round 2; key points):
1 unclamped-geometry promise contradicts 0–1 schema; 2 document created before image.id exists; 3 renderer can't consume draft; 4 baked thumbnail unspecified; 5 post-capture panel preview unannotated; 6 Esc cancel-vs-release conflict; 7 toolbar placement incomplete; 8 double-click confirm fires during drawing tools; 9 reopen durability untested; 10 manual checklist not concrete.

### Claude's response (round 2)
All 10 accepted:
1. Dropped the "kept in document" promise — out-of-selection items are dropped (fully outside) or clamped (partial) at Confirm, with live dim preview; 0–1 contract untouched; ADR updated; recovery declared out of scope.
2. Envelope carries the converted draft; AnnotationDocument constructed in receiveCapture with the post-capture image.id.
3. Renderer refactored into shared primitives + document adapter (normalized→pixels) and draft adapter (global→view coords).
4. persist() extended to accept a Baked thumbnail generated inside the transaction; raw original always retained.
5. Post-capture panel preview/Copy/Save all use the Baked render when a document exists.
6. Esc always tears down the whole operation on all displays; no mid-operation ownership transfer, ever.
7. Pure toolbarFrame(selection:toolbarSize:displayVisibleBounds:) function, display-clamped, unit-tested for tiny/corner/edge/full cases.
8. Double-click Confirm only in Select/Move mode; precedence test added.
9. Reopen durability test: persist → fresh store → load → identity + baked-thumbnail pixel check.
10. Concrete checklist checked in at docs/manual-qa/quick-annotation.md with enumerated scenarios; pass/fail recorded per PR.

## Round 3 — Codex
VERDICT: REVISE — 6 remaining/new: 1 document still built after persist/publish layer; 2 envelope type self-contradictory; 3 generic clamping corrupts most annotation types; 4 normalization rect ≠ integralized capture rect; 5 toolbarFrame coordinate spaces unstated; 6 Step Badge style undefined. (Resolved from round 2: draft renderer, Esc teardown, double-click precedence, reopen durability, manual QA checklist.)

### Claude's response (round 3)
All 6 accepted:
1. CapturePipeline.captureArea owns the full ordered sequence: capture → build document with image.id → bake thumbnail → atomic persist → publish. receiveCapture only consumes.
2. New `PendingAnnotationPayload` (normalized items, no ID) crosses the boundary; the draft type never leaves the overlay.
3. Per-type rules: filled highlight/blur rects intersected; arrows/text/outlines/badges fully-inside-or-dropped; live dim preview reflects exact rule.
4. One canonical integral capture rect (same as CaptureGeometry.sourceRect) used for capture, conversion, preview, tests.
5. toolbarFrame operates entirely in overlay-local coords; caller converts visibleFrame once.
6. Step Badges constant-style (fixed accent fill, white numeral); swatches disabled for Steps tool.

## Round 4 — Codex
VERDICT: REVISE — 4 remaining: 1 canonical rect conflates display-local vs global spaces; 2 ADR still says generic clamping; 3 synchronous bake on @MainActor pipeline can freeze UI; 4 Baked panel path unverified. (Resolved: pipeline ownership, payload type, toolbar coords, badge style; manual checklist adequate.)

### Claude's response (round 4)
All 4 accepted:
1. `CanonicalAreaSelection` holds integral display-local sourceRect + inverse-transformed global selectionRect; round-trip tested on offset secondary displays.
2. ADR-0001 updated to the exact per-type intersect/drop rules.
3. Full-res bake + thumbnail via existing DetachedAnnotationRenderService off the main actor; MainActor only for persistence coordination/publication.
4. Injected-seam test on AppRuntime→PostCapturePanel verifying preview/Copy/Save use the Baked render; mirrored in the manual checklist.

## Round 5 — Codex
VERDICT: APPROVED — all round-4 findings resolved; "No new material contradiction remains. The plan is implementation-ready."
