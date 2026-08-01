# Manual Scroll Capture — Manual QA Checklist

Scope: PLAN.md (Manual Scroll Capture, full plan) — target resolution, seed transaction, border/HUD
windows, session-scoped hotkey, the ~150 ms capture loop, mid-session target monitoring, and the
result/partial-confirmation path. Automated coverage lives in `ManualScrollCaptureTests` (phase-1
matcher/viewport/StripStore/budget/compose logic) and `ManualScrollSessionTests` (coordinate
conversion, engine tick outcomes — unchanged/in-place/matched/dropped/degraded, duration and budget
caps, pause/resume monitoring, compose, the Quick Annotation capability flag). This checklist covers
what those structurally can't: live scrolling input, real window-server target resolution, HUD/border
window compositing, and Carbon hotkey registration against the live system.

## How this pass was run

Not yet run — this checklist is being delivered alongside the implementation, per PLAN.md §10. Run
it in a dedicated interactive session (same caution as `quick-annotation.md`: this feature takes
over global mouse/keyboard-adjacent state — the Selection Overlay and a session-scoped global
hotkey — so it should not be driven via `cliclick`/`osascript` against someone's live, in-use
session).

| # | Scenario | Result | Notes |
|---|----------|--------|-------|
| 1 | Rail button "Scroll Area" (or the ⌃⌥⇧S shortcut) opens the Selection Overlay with no Quick Annotation toolbar available | Not verified | Toolbar suppression has unit coverage (`ManualScrollSessionTests.testManualScrollOverlayHidesTheQuickAnnotationToolbar...`); live overlay rendering is not. |
| 2 | Dragging a region over a **browser page** and scrolling with the mouse wheel/trackpad grows the stitched height live in the Scroll HUD, with no visible seams or duplicated rows in the result | Not verified | |
| 3 | Same, over a **Terminal window's scrollback** (monospace text, sharp edges — a good stress case for the correlation matcher) | Not verified | |
| 4 | **Momentum scroll** (a fast trackpad flick that keeps gliding after the gesture ends) — expect either a clean stitch or a visible "content not matching reliably" HUD hint if samples outrun the ~150 ms cadence (documented v1 limitation, PLAN.md Risks) | Not verified | |
| 5 | **Scroll past the top, then back down** — content already captured must not duplicate or corrupt; the stitched height should not grow while re-covering already-captured rows | Not verified | Viewport/extent "return across seed adds zero rows" logic has full unit coverage (`ManualScrollCaptureTests`); only the live re-scroll path is unverified. |
| 6 | **Edge-touching selection** (region starts at x=0, or spans full display width/height) — border window must not visually break, and the capture itself must not include Take a Shot's own border/HUD chrome | Not verified | Own-window exclusion mechanism (bundle-id filter) is unit-tested at the provider level; the edge-touching compositing case is not. |
| 7 | **Second display**: draw the selection on a non-primary display, scroll content there — target resolution, border/HUD placement, and the AppKit↔Quartz coordinate conversion must all use the correct display's geometry | Not verified | Coordinate-conversion math has unit coverage; multi-display target resolution against the live window server does not. |
| 8 | **Hotkey collision fallback**: trigger a scenario where the session-scoped ⌃⌥⇧S registration fails (e.g. another app already holds that exact combination) — the HUD must show the "Shortcut unavailable — use the HUD buttons" notice, and Done/Cancel via the HUD buttons must still work | Not verified | Collision handling itself is a straightforward catch (not independently unit-tested — Carbon hotkey collision is not reliably reproducible in-process; see BUILD_REPORT deviations). |
| 9 | **Target-window close mid-session**: start scrolling a specific app window, then quit or close that window while the session is active — the HUD must switch to "Content changed — Resume or Cancel" within ~1 second (the ~7-tick monitor interval), accept no frames while paused, and Resume must either recover (if another window resolves under the same region) or stay paused | Not verified | Pause/invalidation/resume state machine has full unit coverage against a fake resolver; only the live window-close detection is unverified. |
| 10 | Clicking **Done** shows the same "Use Partial"/"Discard" dialog as Auto Scrolling Capture when the session ended degraded or capped, and a clean Done opens the result directly in the editor (kind `.scrolling`, same as Auto) | Not verified | Result routing through `CapturePipeline.persistAndPublish`/`confirmUsingPartialCapture` is shared code, already exercised for Auto Scrolling Capture and by `ScreenCaptureTests`; the manual-scroll call site itself is not independently live-tested. |
| 11 | Clicking **Cancel** (or pressing Esc during the *selection* phase, before scroll mode starts) leaves no temp files behind and does not open the editor | Not verified | Temp-file cleanup on every terminal path has full unit coverage at the `StripStore`/worker level (`ManualScrollCaptureTests`); live cancel-during-an-active-session is not. |

## Recommendation

Run this checklist once on a dedicated, non-shared macOS session (ideally with a second display and
a spare app window that can be safely closed mid-test for scenario 9) before shipping Manual Scroll
Capture to end users. None of these scenarios are exercised by CI.
