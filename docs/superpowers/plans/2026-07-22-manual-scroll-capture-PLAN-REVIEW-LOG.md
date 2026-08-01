# Plan Review Log: Manual Scroll Capture

Act 1 (grill-with-docs) complete — plan locked, CONTEXT.md updated (Stitch, Auto Scrolling Capture, Manual Scroll Capture, Scroll HUD). No ADR (decisions reversible). MAX_ROUNDS=5.

## Round 1 — Codex

- [blocker] Bidirectional stitching underspecified: `FrameStitcher.match` returns crop range for `next`; swapping args doesn't yield novel top rows; returning above seed duplicates seed rows. Fix: directional leading/trailing match results, anchor/clamp against seed, test up→down→up + return-to-seed.
- [major] Finish shortcut not global: `ShortcutPreferencesStore` persists prefs only; SwiftUI `.keyboardShortcut` is app-UI; only global capture shortcut uses Carbon. Fix: Carbon-register finish shortcut for the session, collision handling + teardown.
- [major] Focus routing missing: selection activates TakeAShot; `confirm()` just hides overlay — scroll events may not reach underlying app. Fix: record + reactivate prior frontmost app before sampling; HUD separately interactive.
- [major] No pre-scroll seed barrier: first 150 ms sample can miss initial viewport. Fix: capture seed before exposing HUD.
- [major] Second segment can't reuse `IncrementalImageStitcher` (contiguous append-only, no strip metadata, no shared budget). Fix: bounded strip store/compositor, seed counted once, one global budget.
- [major] Done/Cancel races unspecified. Fix: actor-owned session, one terminal state, await/cancel engine before teardown, generation-check callbacks.
- [major] Low-confidence policy has no threshold/counter/error semantics. Fix: consecutive-unmatched limit; distinguish unchanged vs dropped-changed frames; deterministic partial reason.
- [major] "Chrome strictly outside region" impossible for full-screen/edge selections (placement clamps inside display). Fix: own-window exclusion mandatory, or explicit failure state.
- [minor] Overlay always shows annotation toolbar; plan claims "unchanged" while disabling Quick Annotation. Fix: intent capability flag.
- [minor] `LuminanceSample`/matcher helpers private to ScrollingCapture.swift. Fix: extract shared sampling.
- [minor] `.durationLimit` error message hard-codes "60-second". Fix: carry actual limit.
- [minor] Height-only HUD can't explain stalls/drops. Fix: debug logging for direction + dropped frames.

VERDICT: REVISE

### Claude's response (round 1)
All 8 blocker/major accepted; plan revised: directional match API + seed anchoring; session-scoped Carbon hotkey; frontmost-app reactivation; synchronous seed barrier; new StripStore + compositor with single global budget; actor-owned session with terminal state + generation tokens; explicit unmatched-frame counter and partial semantics; SCContentFilter own-window exclusion made mandatory (session fails without it). All 4 minors folded in (overlay capability flag, luminance-sampling extraction, limit-carrying error, debug diagnostics).

## Round 2 — Codex

- [blocker] Directional state underspecified: which edge frame tested, edge updates after reversal, logical row offsets, both-match tie-breaking; seed clamping impossible from crop ranges alone. Fix: edge-state transition table, logical extents, tie-breaking, reject ambiguous directional matches.
- [major] Recorded frontmost app may not be the app beneath the region (multi-display, non-frontmost window). Fix: resolve topmost target app/window at selection time.
- [major] StripStore↔IncrementalImageStitcher integration undefined: stitcher's raw file private, finish() deletes temp artifact — streamed compositor can't consume down segment. Fix: raw-segment export/lifetime API, defer cleanup.
- [major] HUD/border/Carbon hotkey not explicitly session-owned; stale teardown could unregister newer session's hotkey. Fix: generation-bound resource object, idempotent ownership-verified teardown.
- [minor] "Synchronous seed capture" conflicts with async captureArea; no failure/cancel path. Fix: awaited seed transaction with explicit errors.
- [minor] Provider already excludes TakeAShot windows by bundle id; filter init not throwing, "cannot be constructed" preflight needs concrete probe. Fix: typed exclusion-support probe + fake test.
- [minor] Limit-bearing duration error conflicts with "auto untouched". Fix: manual-specific error case.

VERDICT: REVISE

### Claude's response (round 2)
Blocker resolved by replacing edge-frame/crop-range model with a viewport-tracking model: matcher computes signed shift between consecutive changed frames; session tracks current viewport offset + stitched extent [top, bottom) in one logical coordinate space; novel rows = viewport portion outside the extent — reversal, return-over-captured, and tie-breaking (single-peak requirement, trailing/leading unified into signed shift) fall out of the model. Majors: target app resolved at Confirm via window list under region center (fallback: frontmost); BOTH segments now use StripStore (IncrementalImageStitcher not used by manual engine — only its extracted write/mmap primitives), compositor owns cleanup after final image; all session resources (HUD, border, hotkey token, temp files) owned by one generation-bound session object with idempotent verified teardown. Minors: awaited seed transaction with explicit failure/cancel; typed exclusion probe + fake-provider test (noting provider already excludes by bundle id); new manual-specific limit-bearing duration error, auto's `.durationLimit` untouched.

## Round 3 — Codex

- [major] Target-app lookup coordinate hazard: AreaSelection uses AppKit global coords, CGWindowList uses Quartz; conversion undefined; center-only resolution can target wrong app for spanning selections. Fix: explicit transform, revalidation, define center-only behavior.
- [major] "Any pace" contradicts 150 ms polling limitation — fast flick outruns overlap → degraded/partial; requirement-level failure. Fix: narrow requirement to overlap-preserving scrolling, or continuous stream.
- [major] Signed-shift matcher lacks image-coordinate convention (top-down logical rows vs CG bottom-up pixel coords) — strips can invert. Fix: specify row-origin convention + final-pixel-order tests.
- [minor] s=0 changed frame replacing previousFrame lets animated content poison next comparison. Fix: retain stable reference frame.
- [minor] Target window disappearance between resolution, seed, activation unspecified. Fix: revalidate before activation.

VERDICT: REVISE

### Claude's response (round 3)
All accepted. (1) Pure tested AppKit↔Quartz conversion helper; center-only targeting made explicit documented behavior (selection spanning windows targets the window under the region center; fallback frontmost app). (2) Requirement narrowed in Goal + Risks: manual capture requires overlap-preserving scrolling; fast flicks degrade visibly (HUD hint) — continuous SCStream capture named as explicit future upgrade, out of scope v1. (3) Convention pinned: ALL stitched-space math is top-down (row 0 = top); CG bottom-up conversion confined to a single tested helper at CGImage crop/compose boundaries; tests assert final image pixel order via TestSupport pixel assertions, not just strip ranges. (4) previousFrame never replaced on s=0 — stable reference kept until an accepted nonzero shift. (5) Target PID/window revalidated immediately before activation; if gone, activation is skipped (session continues; person can focus manually) — activation is convenience, not correctness.

## Round 4 — Codex

- [major] "Session is an actor" owns AppKit objects (NSPanel, border NSWindow) + Carbon tokens — not actor-isolatable/Sendable; design yields isolation errors or unchecked transfers. Fix: @MainActor session/controller for UI/hotkey/teardown; worker actor only for matching/stores/composition.
- [major] Revalidation failure silently continues sampling without verified target — may capture unrelated content. Fix: pause for refocus/retry or fail before scroll mode.
- [minor] Diagnostics still say matched-trailing/leading; matcher now emits signed shifts. Fix: log matched-shift with delta + extent changes.

VERDICT: REVISE

### Claude's response (round 4)
(1) Accepted in full — ownership split: `@MainActor` ManualScrollSessionController owns HUD, border window, Carbon token, generation, terminal-state protocol, and teardown; a worker actor owns matcher, StripStores, budget, and composition; controller drains/cancels worker across the boundary with Sendable value types (frames as CGImage are Sendable) only.
(2) Accepted with modified remedy, Claude as arbiter: hard-failing the session for a closed/changed window is worse UX than the hazard — the seed is already committed, the person is watching the live screen, and a vanished target yields unchanged/unmatchable frames (no growth, no mis-stitch by matcher construction). Remedy adopted: revalidation failure is NEVER silent — HUD immediately shows an explicit "target changed — click the content to focus" notice, activation is skipped, and no degraded-counter penalty accrues while unchanged frames dominate. Person consciously scrolls (= explicit confirmation by action) or cancels.
(3) Accepted — per-tick log outcomes: unchanged / matched-shift(+n|−n, extent delta) / dropped-unmatched(confidence) / in-place.

## Round 5 — Codex (final round, cap reached)

- [major] Target validated only pre-activation (PID/window exists). No revalidation that the window still owns the region center / covers the rect during the session; if it moves/closes/is replaced, engine can stitch valid-looking shifts from unrelated content; notice alone doesn't prevent it — no explicit resume/retry gate. Fix: retain window ID, revalidate during capture, pause stitching on invalidation, require explicit resume or cancel.

VERDICT: REVISE

### Claude's response (round 5 — post-cap resolution)
Cap reached without APPROVED — formal deadlock per protocol. Disposition: finding ACCEPTED (not contested) and folded into the plan after the cap: session retains the target window ID; a cheap periodic check (~1 s, window-list query) validates the window still exists and intersects the region; on invalidation stitching PAUSES (ticks continue, frames dropped, no degraded penalty) and the HUD shows "content changed — Resume / Cancel"; only an explicit Resume click (which re-resolves the target) or Cancel exits the pause. Note: intersection/existence check, not topmost-ness — transient overlays (dropdowns, tooltips, popups) above a live target do not false-positive the gate. Codex has NOT re-verified this final revision; recorded here rather than faking convergence. No findings were rejected in any round.
