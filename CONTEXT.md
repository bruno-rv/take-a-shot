# Take a Shot

A local-first macOS menu-bar screenshot and screen-recording studio: capture (area/window/fullscreen/scrolling), annotate, and export — no cloud.

## Language

**Selection Overlay**:
The per-display transparent AppKit window shown during area capture, where the user draws and resizes the capture rectangle over the live screen.
_Avoid_: slicer, area picker

**Quick Annotation**:
Markup (arrows, text, shapes, etc.) drawn directly on the Selection Overlay before the capture is confirmed.
_Avoid_: pre-capture editing, overlay drawing

**Annotation Document**:
The set of annotation items (plus optional crop) attached to a capture, stored in normalized 0–1 coordinates so it is resolution-independent and stays editable.
_Avoid_: markup layer, edits

**Bake**:
Rasterizing the Annotation Document onto the captured pixels to produce the final image for clipboard, export, or library thumbnail. Baking never destroys the Annotation Document.
_Avoid_: flatten, merge

**Confirm**:
The explicit action (Return or double-click) that ends area selection, hides the Selection Overlay, and triggers the capture.
_Avoid_: accept, commit

**Step Badge**:
An auto-incrementing numbered marker (1, 2, 3…) placed by the steps tool.
_Avoid_: counter, bullet

**Stitch**:
Combining successive overlapping frames of scrolled content into one tall image by matching shared rows; only novel rows are added.
_Avoid_: merge, glue, panorama

**Auto Scrolling Capture**:
The scrolling capture where the app drives the target window's scrolling itself and stitches until content stops changing.
_Avoid_: scroll grab

**Manual Scroll Capture**:
The scrolling capture where the person scrolls the content inside a selected region themselves while the app samples that region and stitches, until they press Done.
_Avoid_: live scroll, freehand scroll

**Scroll HUD**:
The small floating control shown during Manual Scroll Capture with the stitched height, Done, and Cancel.
_Avoid_: progress pill, toolbar
