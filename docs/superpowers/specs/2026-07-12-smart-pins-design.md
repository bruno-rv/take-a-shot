# Smart Pins Design

Date: 2026-07-12
Status: Approved 2026-07-12

## Objective

Add lightweight floating visual references to Take a Shot. A user can pin an
active capture or a library item above other applications, keep selected pins
across relaunches, and recover control even when a pin ignores pointer input.

Smart Pins are the first stage of a broader visual workspace direction. The
v1 data model must support future reference boards without shipping board,
note, live-refresh, or cloud features now.

The product promise is:

> Capture something once. Keep it exactly where you need it.

## Product scope

Smart Pins v1 will support:

- Pinning the active capture or any image capture in the local library.
- One live pin per capture. Pinning an existing capture focuses its current
  pin rather than creating a duplicate.
- Borderless floating panels that stay above normal application windows.
- Dragging, resizing, zooming, panning, and changing opacity.
- A click-through mode with a reliable keyboard recovery path.
- Collapsing a pin into a compact edge tab and restoring it in place.
- Copying the composited image, copying OCR text, opening detected links, and
  revealing the library source.
- Optional restoration of individual pins after relaunch.
- Menu-bar actions to hide, show, or close all pins.
- Automatic pin hiding or exclusion during Take a Shot capture and recording.

Smart Pins v1 will not support:

- Named reference boards, notes, connectors, or spatial grouping.
- Live window or screen-region refresh.
- Visual comparison or version history.
- Pinning videos, animated GIF playback, arbitrary files, or web pages.
- Cloud synchronization or collaborative pin layouts.
- Independent copies of library media owned by the pin system.

## User experience

### Creating a pin

The user can create a pin through:

- The editor's **Pin** action.
- A library item's context menu.
- **Command-Shift-P** for the active capture.

Pinning an active capture first flushes pending text and annotation changes.
The pin displays the same persisted crop and annotations that image export
would render. If the flush fails, the app does not create the pin and explains
that the latest edit could not be saved.

### Pin panel

Each pin uses a non-activating `NSPanel` hosted by SwiftUI. The panel has no
standard title bar. Its controls appear when the pointer hovers over the panel
or when keyboard focus enters it. The image remains unobstructed otherwise.

The panel provides:

- Drag and corner-resize interaction.
- Zoom from 25 percent through 800 percent.
- Panning when the image is larger than the panel.
- Opacity from 20 percent through 100 percent.
- **Click Through**, **Collapse**, **Copy**, **More**, and **Close** actions.
- A context menu for OCR text, detected links, Finder reveal, and persistence.

The panel preserves the image's aspect ratio during ordinary resizing. Zoom
changes the image within the panel and does not resize the panel itself.

### Click-through recovery

Click-through mode ignores pointer input so users can interact with windows
under the pin. The following recovery paths are mandatory:

- A configurable global shortcut toggles interaction for all click-through
  pins. The default is **Control-Option-Command-P**.
- Holding **Control-Option** temporarily makes the pin under the pointer
  interactive.
- The menu-bar item lists the number of click-through pins and provides
  **Make All Pins Interactive**.

The app must register at least one recovery path before it enables
click-through mode. Registration failure leaves the pin interactive and shows
an actionable error.

### Collapse and global visibility

Collapsing converts the panel into a narrow edge tab on the nearest display
edge. The tab retains a thumbnail and a restore action. Collapse does not imply
click-through.

**Hide All Pins** records which pins were visible before hiding. **Show All
Pins** restores that exact set. Pins closed while hidden stay closed.

## Architecture

Smart Pins extend the current library-owned media architecture.

```text
Editor / Library UI
        |
        v
PinCoordinator (@MainActor)
   |---- PinWindowCoordinator ---- NSPanel lifecycle and displays
   |---- PinViewModel ------------ image, OCR actions, panel state
   |---- CaptureVisibilityLease -- capture and recording isolation
   |
   v
PinStore (actor) ----------------- versioned atomic metadata
   |
   +---- CaptureLibraryStore ----- library-owned media and annotations
```

`PinCoordinator` is the UI-facing owner of pin identity and actions. It must
not own image files. `PinStore` owns only pin metadata. `CaptureLibraryStore`
remains the only owner of capture media, thumbnails, OCR, and annotations.

### Component responsibilities

`PinCoordinator`:

- Creates, focuses, closes, hides, and restores pins.
- Enforces one live pin per capture.
- Coordinates library deletion and application termination.
- Acquires visibility leases for capture and recording.

`PinWindowCoordinator`:

- Creates one panel per active pin.
- Applies window level, click-through, frame, and collapse state.
- Observes display changes and clamps frames onto visible screens.
- Publishes exact window lifecycle completion to `PinCoordinator`.

`PinViewModel`:

- Loads persisted annotations and a display-sized composited image lazily.
- Exposes zoom, pan, opacity, OCR, link, copy, and Finder actions.
- Invalidates stale rendering tasks when the source changes.
- Releases decoded image surfaces when the panel is hidden or under memory
  pressure.

`PinStore`:

- Reads and writes versioned pin metadata under Application Support.
- Debounces layout updates for 250 milliseconds.
- Publishes metadata atomically through a temporary file and rename.
- Isolates malformed pin records so one damaged record cannot block others.

`CaptureVisibilityLease`:

- Records the exact visible-pin set when the first lease is acquired.
- Reference-counts overlapping capture and recording operations.
- Restores the recorded set only after the final lease is released.
- Never reopens a pin that the user closed while pins were hidden.

## Data model

```swift
struct PinnedReference: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let captureID: UUID
    var frame: PersistedPinFrame
    var zoom: Double
    var normalizedPan: NormalizedPoint
    var opacity: Double
    var isClickThrough: Bool
    var collapsedEdge: PinEdge?
    var restoresAfterRelaunch: Bool
    var createdAt: Date
    var updatedAt: Date
}
```

`PersistedPinFrame` stores the display identifier and the panel frame in
AppKit screen coordinates. It also stores the previous visible display frame
so restoration can preserve a relative position when display geometry changes.

Pin metadata uses a schema envelope:

```swift
struct PinStoreDocument: Codable, Sendable {
    let schemaVersion: Int
    var pins: [PinnedReference]
}
```

The initial schema version is one. Unknown future versions fail without
overwriting the source file. Duplicate `captureID` entries keep the newest
valid record and report the discarded records.

## Rendering and memory behavior

A pin displays the persisted annotation composition, not an independent edit
document. Annotation editing remains in the editor.

Rendering follows these rules:

- Render off the main actor through the existing annotation renderer.
- Size the surface for the current panel backing scale, with a 4,096-pixel
  longest-edge cap.
- Re-render after a meaningful panel-size change, source edit, or display-scale
  change.
- Coalesce rapid resize requests and publish only the latest render.
- Keep decoded pin surfaces within a 256 MiB least-recently-used budget.
- Release hidden and collapsed full surfaces first under memory pressure.
- Load the full original only for copy or explicit export actions.

Pins observe library record changes. A persisted annotation or crop update
invalidates that pin's composition. OCR-only and tag-only updates do not cause
an image render.

## Capture and recording isolation

Take a Shot must not include its pins in new output.

For ScreenCaptureKit operations, the capture filter excludes every active pin
panel when the API can represent those windows safely. Area overlays and any
path without reliable exclusion acquire a visibility lease before presenting
capture UI. Recording holds its lease through final stream cleanup, not merely
until the user presses Stop.

Lease acquisition and release are asynchronous, exact-once operations. A
capture must not begin until every relevant panel confirms it is hidden. If a
panel cannot hide, capture stops with a visible error rather than risking pin
recursion.

## Persistence and restoration

Only pins with `restoresAfterRelaunch == true` survive normal application
termination. Nonpersistent pins close without writing a restoration record.

Termination follows this order:

1. Finish or cancel active capture and recording cleanup.
2. Flush pending annotations and tags.
3. Capture final pin frames and interaction state.
4. Persist the pin document atomically.
5. Permit application termination.

Failure in steps one through four vetoes normal termination and presents a
specific recovery message. The existing termination coordinator remains the
single gate for this sequence.

During restoration:

- Skip malformed records individually and report a single summary warning.
- Skip records whose capture no longer exists.
- Clamp every restored panel so at least its recovery controls remain visible.
- Restore collapsed pins as tabs.
- Restore click-through pins only after the global recovery shortcut registers.
- Decode pin images lazily after their panels appear.

## Library ownership and deletion

Pins reference library captures by UUID. They never keep hidden media copies.

Deleting a capture with an active or persistent pin presents these choices:

- **Close Pins and Delete** removes associated pin metadata before deleting
  the capture.
- **Keep Capture** cancels deletion.
- **Export Copy First** exports the current composited image, then returns to
  the deletion confirmation. Export does not create an unmanaged pin source.

Pin metadata removal and capture deletion form one coordinated operation. If
pin metadata cannot be published, capture deletion does not begin. If capture
deletion fails, the coordinator restores the prior pin metadata and reports
any rollback failure.

## Error handling

Smart Pins use typed failures for:

- Missing or corrupt pin metadata.
- Missing, deleted, or corrupt capture media.
- Rendering and OCR action failures.
- Window creation and display-restoration failures.
- Global shortcut registration failure.
- Visibility-lease acquisition and restoration failure.
- Pin persistence and library-deletion rollback failure.

A missing capture displays a placeholder with **Locate in Library**, **Close
Pin**, and **Remove Permanently**. A persistence failure keeps the panel open
and warns that the latest layout was not saved. No failure silently deletes a
pin, capture, or user layout.

## Accessibility

Smart Pins must support:

- VoiceOver labels, values, and state announcements for every control.
- A predictable keyboard focus order when controls are visible.
- Keyboard alternatives for drag-only actions.
- Reduced-motion transitions for collapse and restore.
- Increased-contrast controls and visible keyboard focus rings.
- Screen-edge recovery that remains usable with larger accessibility text.
- A textual opacity value rather than color or transparency alone.

Click-through mode must never remove keyboard recovery or menu-bar access.

## Testing strategy

### Model and persistence tests

- Atomic save, reload, schema rejection, and malformed-record isolation.
- Duplicate capture references retain the newest valid record.
- Debounced writes preserve the final frame and interaction state.
- Normal termination flushes persistent pins and excludes transient pins.

### Window and display tests

- One panel per capture and duplicate-pin focus behavior.
- Frame restoration on matching, resized, disconnected, and replaced displays.
- Collapse and restore on every display edge.
- Exact close, hide, reopen, and rapid lifecycle completion.
- Click-through recovery when shortcut registration succeeds or fails.

### Capture integration tests

- Nested visibility leases restore the exact original visible set.
- Closing a hidden pin prevents restoration.
- Capture waits for all hide acknowledgements.
- Failed hiding prevents capture.
- Recording retains the lease through cleanup and failure paths.
- Exclusion filters contain every visible pin panel.

### Rendering and resource tests

- Rendered pins match persisted annotation and crop output.
- Rapid resize work is serialized and last-request-wins.
- Surfaces respect the 4,096-pixel and 256 MiB limits.
- Hidden and collapsed surfaces are released before visible surfaces.
- Source updates invalidate image renders, while tag changes do not.

### Accessibility and UI tests

- VoiceOver labels and focus order cover every enabled control.
- Keyboard zoom, opacity, collapse, and recovery actions work without a mouse.
- Reduced-motion and increased-contrast settings change presentation correctly.
- Missing-source and persistence errors expose actionable recovery controls.

## Acceptance criteria

Smart Pins v1 is complete when:

- A user can pin an active or library capture and keep several references
  visible throughout a work session.
- Persistent pins restore to usable positions after relaunch and display
  changes.
- A user can always recover interaction with click-through pins.
- Capture and recording output never contains visible Take a Shot pins.
- Deleting a pinned capture cannot orphan metadata or silently lose media.
- Pin rendering and restoration stay within documented memory bounds.
- All controls work through keyboard navigation and VoiceOver.
- The implementation introduces no board, live-refresh, or cloud behavior.

## Future stages

The model intentionally leaves room for two later stages:

1. Reference boards that group pins, images, and notes into named local
   workspaces.
2. Live references that refresh a source region, keep bounded versions, and
   highlight visual changes.

These stages require separate designs and are not acceptance criteria for
Smart Pins v1.
