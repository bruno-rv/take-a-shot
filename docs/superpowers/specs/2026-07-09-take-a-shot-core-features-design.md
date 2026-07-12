# Take a Shot Core Features Design

Date: 2026-07-09
Status: Approved 2026-07-10

## Objective

Turn the existing macOS SwiftUI prototype into a functional, local-first screenshot and recording application. The implementation will provide modern screen capture, scrolling capture, video and GIF recording, non-destructive annotations, optimized export, and a persistent OCR-searchable library.

Cloud upload is deliberately excluded. Cloud controls will remain disabled and clearly marked as a future feature rather than simulating a successful upload.

## Product Scope

The release will support:

- Area capture on the display containing the pointer.
- Full-display capture on any connected display.
- Individual window capture through a native window picker.
- Automatic vertical scrolling capture for a selected window, with explicit permission and compatibility errors.
- MP4 screen recording with optional system audio and microphone audio.
- Animated GIF recording without audio.
- Arrow, text, highlight, blur, and crop editing tools.
- Non-destructive undo and redo.
- Full-resolution PNG and JPEG export plus clipboard copy.
- A persistent local capture library with thumbnails, OCR text, search, and user tags.

The release will not support:

- Cloud upload, public links, accounts, or synchronization.
- Cross-device or collaborative editing.
- Horizontal or bidirectional scrolling capture.
- Capture of protected or DRM-restricted content.
- iOS. The current project remains a native macOS application with a minimum deployment target of macOS 14.

## Architectural Approach

The application will use a modular native pipeline. Platform capture and media APIs remain behind focused services, while SwiftUI owns presentation and interaction state only.

```text
Capture UI
   |
   v
CaptureCoordinator
   |---- ScreenshotCaptureEngine ---- ScreenCaptureKit
   |---- ScrollingCaptureEngine ----- FrameStitcher + Accessibility
   |---- RecordingEngine ------------ SCStream + AVAssetWriter
   |
   v
CaptureArtifact
   |---- AnnotationDocument --------- EditHistory
   |---- AnnotationRenderer --------- Core Graphics + Core Image
   |---- ImageExporter -------------- Image I/O
   |---- OCRService ----------------- Vision
   |
   v
CaptureLibraryStore
   |
   v
Application Support/TakeAShot
```

`AppState` remains `@MainActor` and becomes a UI-facing coordinator. Expensive capture, stitching, encoding, OCR, thumbnail generation, and persistence work will execute away from the main actor. Services report typed results and typed failures back to `AppState`.

## Core Data Model

### CaptureArtifact

`CaptureArtifact` represents an immutable captured source:

- Stable UUID.
- Capture kind: area, window, display, scrolling, video, or GIF.
- Creation date.
- Pixel width and height from the actual media buffer.
- Display or window metadata when available.
- Original local file URL.
- In-memory image only while actively editing.

Pixel dimensions are stored directly rather than reconstructed from `NSImage.size` and the current main screen scale.

### AnnotationDocument

`AnnotationDocument` contains the capture identifier, the active crop rectangle, and an ordered collection of annotations. Geometry is stored in normalized image coordinates from zero through one so edits are independent of canvas zoom and display scale.

Annotation variants are:

- Arrow: start point, end point, color, and stroke width.
- Text: anchor, bounds, text, font size, and color.
- Highlight: rectangle, color, and opacity.
- Blur: rectangle and blur radius.
- Crop: one document-level rectangle applied before export.

Undo and redo use bounded snapshots of the annotation list and crop rectangle. The original capture file is never modified.

### CaptureRecord

`CaptureRecord` is Codable metadata stored by the local library:

- Capture UUID and kind.
- Creation and last-edited dates.
- Original, edited-export, and thumbnail filenames.
- Pixel dimensions and duration where applicable.
- OCR text.
- User-defined tags.
- Annotation document filename when edits exist.

Only relative filenames are persisted. The store resolves them against its configured root, allowing tests to use temporary directories and preventing stale absolute paths.

## Screenshot Capture

`ScreenshotCaptureEngine` will use `SCShareableContent`, `SCContentFilter`, `SCStreamConfiguration`, and `SCScreenshotManager`.

- Area mode creates selection overlays for all connected displays. Completing a selection identifies its owning display, converts the local point rectangle to ScreenCaptureKit source coordinates, and captures only that region.
- Fullscreen mode captures the display containing the pointer when invoked. The main UI may also select another connected display.
- Window mode presents current on-screen windows excluding Take a Shot itself. The selected `SCWindow` is captured with a desktop-independent window filter.
- Cursor inclusion and desktop exclusion are mapped to `SCStreamConfiguration` and content filtering rather than simulated UI state.
- Delay is handled by an async task that can be cancelled before capture begins.

Capture permission denial produces a visible explanation and an action that opens the correct System Settings pane. Unsupported or disappeared windows produce an error; no capture mode silently falls back to area capture.

## Scrolling Capture

Scrolling capture targets a selected, vertically scrollable window. It uses a guided automatic process:

1. The user selects a window and brings it to the foreground.
2. The app verifies Screen Recording and Accessibility permissions.
3. The engine captures the first visible frame.
4. It posts a controlled vertical scroll event at the window center.
5. After a short content-settle interval, it captures the next frame.
6. `FrameStitcher` downscales frames to luminance, ignores stable top and bottom chrome, and finds the largest confident vertical overlap.
7. Only the novel strip is appended to the output image.
8. Capture stops when frames repeat, overlap confidence drops below the accepted threshold, the user cancels, or a safety limit is reached.

Safety limits are 100 frames, 30,000 output pixels, and 60 seconds. The engine writes intermediate strips to temporary storage rather than retaining every full-resolution frame in memory.

Apps that ignore synthetic scrolling, virtualized content that changes between frames, protected content, and low-confidence overlap produce explicit failure or partial-result messages. A partial result may be saved only after user confirmation.

## Video and GIF Recording

The project will retain macOS 14 support. `SCRecordingOutput` is therefore not the primary implementation because it requires macOS 15. `RecordingEngine` will receive `SCStream` video and system-audio sample buffers and write them through `AVAssetWriter`.

MP4 behavior:

- H.264 video in an MP4 container at up to 30 frames per second.
- Display or selected-window recording.
- Optional system audio from ScreenCaptureKit.
- Optional microphone audio captured through `AVCaptureSession` and synchronized to the asset-writer timeline.
- Pause is excluded from the first release; start, stop, elapsed time, and cancellation are supported.

GIF behavior:

- Video frames are sampled at no more than 10 frames per second.
- The longest image edge is capped at 1280 pixels.
- Duration is capped at 60 seconds.
- Frames are encoded incrementally with `CGImageDestination` and GIF timing metadata.
- Audio controls are disabled in GIF mode.

Recording writes to a temporary file first. Successful finalization atomically moves the file into the library. Cancellation and failure remove temporary media. The UI always reflects the recording state machine: idle, preparing, recording, stopping, completed, or failed.

## Annotation Editing and Rendering

The editor maps pointer gestures into image coordinates using the displayed image content rectangle, accounting for aspect-fit letterboxing and zoom.

- Arrow: drag from tail to head.
- Text: click to place an inline text editor, then drag the resulting text box.
- Highlight: drag a rectangle.
- Blur: drag a rectangle and preview the affected area.
- Crop: drag and resize the retained image rectangle.

Selection handles allow moving and resizing existing annotations. Delete removes the selected annotation. Undo and redo operate on every create, move, resize, edit, delete, and crop action.

`AnnotationRenderer` composites at the original pixel resolution. Core Graphics draws arrows, text, and highlights; Core Image applies blur only inside blur rectangles. Crop is applied last to the rendered result. Preview rendering may use a downsampled image, but export always uses the original.

## Export and Clipboard

`ImageExporter` accepts an immutable source image and optional annotation document.

- PNG uses lossless Image I/O encoding directly from `CGImage`.
- JPEG uses configurable compression quality and a solid background for alpha content.
- Clipboard copy publishes the rendered `NSImage` on the main actor after background rendering completes.
- File writes are atomic and occur outside the main actor.
- A single rendered result may be reused for copy, save, thumbnail generation, and library persistence during one export operation.

The existing TIFF intermediary will be removed. Date formatting will use a reusable formatter or `FormatStyle` rather than creating a formatter per save.

## Local Library and OCR

`CaptureLibraryStore` is an actor that serializes writes beneath:

```text
~/Library/Application Support/TakeAShot/
  index.json
  originals/
  exports/
  thumbnails/
  annotations/
  temporary/
```

Metadata updates use write-to-temporary-and-rename semantics. Missing or corrupt individual files are reported and skipped without discarding the rest of the index.

After an image is persisted, `OCRService` runs a Vision text-recognition request on a background task. OCR results update the record asynchronously. Library search matches title, OCR text, capture kind, and tags with case- and diacritic-insensitive comparison.

The inspector will display real records rather than the hardcoded sample array. It will provide search, tag editing, reopen-in-editor, copy, export, reveal-in-Finder, and delete actions. Deletion removes metadata and owned files after confirmation.

Thumbnails are generated once with a maximum dimension of 512 pixels and loaded lazily. Full-resolution images are loaded only when editing, copying, or exporting.

## UI Integration

The existing visual direction is retained while controls become state-driven:

- Capture rail dispatches each mode to a distinct coordinator action.
- Window capture and recording present a source picker.
- Scrolling capture displays progress and cancellation controls.
- Toolbar tools edit the active annotation document.
- Undo, redo, zoom, stroke, color, and opacity controls become functional.
- Recording controls show format, audio options, elapsed time, and stop/cancel states.
- Inspector displays real image dimensions and library records.
- Cloud upload controls are disabled and labeled "Coming later."

The unused mobile `ContentView` and `EditorViews` are removed from the macOS target. The dotted canvas background is rendered as one compound path or a cached tile rather than one `Path` allocation per dot.

## Error Handling

Services return domain-specific errors with a user-facing message and optional recovery action. Required cases include:

- Screen Recording permission denied.
- Accessibility permission denied for scrolling capture.
- Microphone permission denied while microphone audio is requested.
- Window or display disappears before capture starts.
- No confident scrolling-frame overlap.
- Recording encoder cannot start or finalize.
- Export or library storage is unavailable.
- OCR fails for an otherwise valid capture.

OCR failure does not fail capture persistence. Optional microphone denial falls back to recording without microphone only after informing the user. Capture and export failures never claim success and never create a library record pointing to an incomplete file.

## Testing Strategy

An XCTest target will be added. Platform APIs will sit behind protocols so deterministic components can be tested without triggering permissions or screen capture.

Unit coverage includes:

- Point-to-pixel and display-coordinate conversion on one and multiple displays.
- Annotation normalization and canvas-to-image mapping.
- Undo and redo behavior.
- Rendering arrows, highlights, blur, text, and crop against synthetic images.
- Scrolling overlap detection, repeated-frame stopping, low-confidence failure, and safety limits.
- Recording state transitions and writer cleanup using test doubles.
- GIF timing metadata and frame-limit enforcement.
- Atomic library writes, index reload, deletion, search, and corrupt-record recovery in a temporary directory.
- OCR result integration through a stub OCR service.

Verification also includes:

- Debug and Release builds for the macOS target.
- Xcode static analysis.
- Manual area, display, and window capture across mixed-scale displays.
- Manual scrolling capture in Safari and a standard AppKit scroll view.
- Manual MP4 and GIF recording with audio combinations.
- Permission-denied and permission-restored flows.
- Instruments checks for main-thread stalls and memory growth during large scrolling captures and recordings.

## Delivery Sequence

Implementation proceeds in dependency order:

1. Introduce models, protocols, XCTest target, and pure geometry/export tests.
2. Implement ScreenCaptureKit screenshot capture and optimized Image I/O export.
3. Implement local persistence, thumbnails, OCR, and library search.
4. Implement annotation document, editor gestures, undo/redo, and renderer.
5. Implement scrolling capture and frame stitching.
6. Implement MP4 recording, microphone/system audio integration, and GIF recording.
7. Connect all controls, remove placeholder state, optimize canvas rendering, and remove unused mobile UI.
8. Run automated and manual verification, then resolve performance or correctness regressions.

Each stage leaves the application buildable. Later stages consume stable interfaces established by earlier stages rather than expanding the existing monolithic controller.

## Acceptance Criteria

The work is complete when:

- Every enabled capture and editing control performs its labeled operation.
- Area, display, and window capture work on multiple displays without main-display coordinate assumptions.
- Scrolling capture creates a stitched image or reports a clear incompatibility without saving corrupt output.
- MP4 and GIF recordings finalize into playable files and clean up failed or cancelled output.
- Annotations render identically in preview and full-resolution export within normal scaling tolerance.
- Copy and file export do not perform TIFF conversion or block the main actor with encoding or disk I/O.
- Captures persist across launches and are searchable by OCR text and tags.
- Cloud controls cannot simulate upload success.
- The macOS project builds and analyzes successfully, and the new automated test suite passes.
