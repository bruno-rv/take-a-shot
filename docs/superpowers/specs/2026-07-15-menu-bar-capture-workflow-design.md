# Menu Bar Capture Workflow Design

Date: 2026-07-15
Status: Approved 2026-07-15

## Objective

Run Take a Shot as a menu-bar-only macOS application. The app must stay
available without a Dock icon or a main window, start area capture from a
configurable global shortcut, and present a compact action panel after a
successful capture.

The default shortcut is **Shift-Command-1**.

## Product scope

This feature will support:

- A persistent Take a Shot icon in the macOS menu bar.
- No Dock or application-switcher icon during ordinary operation.
- A menu with **Capture Area**, **Open Editor**, **Settings**, and **Quit**.
- A configurable global area-capture shortcut in **Settings**.
- A compact post-capture panel beside the captured area.
- **Copy**, **Save**, and **Editor** actions in the post-capture panel.
- An editor window that can close while the menu-bar app continues running.

This feature will not add:

- A separate capture history popover in the menu bar.
- New image editing capabilities.
- New save destinations or export formats.
- Configurable shortcuts for actions other than area capture.
- Automatic upload or cloud sharing.

## Application lifecycle

The app uses native SwiftUI scenes:

- `MenuBarExtra` owns the persistent menu-bar presence and primary commands.
- A named `Window` scene owns the editor and does not open at launch.
- A `Settings` scene owns shortcut configuration.
- The application runs as an accessory app so macOS does not show a Dock or
  application-switcher icon.

Launching the app shows only its menu-bar item. Selecting **Open Editor** opens
or focuses the editor window. Closing the editor leaves the menu-bar item
running. Selecting **Quit** terminates the app through its existing termination
flow.

The native scene approach replaces the current implicit `WindowGroup`. It is
preferred over a custom `NSStatusItem` and `NSWindow` coordinator because the
project targets macOS 14 and already uses SwiftUI for its root composition. It
is preferred over hiding the existing window dynamically because that approach
can flash a Dock icon or launch window and makes closed-window restoration less
reliable.

## Menu-bar commands

The menu-bar menu contains these commands:

- **Capture Area** starts the same area-selection flow as the global shortcut.
- **Open Editor** opens or focuses the editor with the current active capture.
- **Settings** opens the native settings window.
- **Quit** runs the existing coordinated termination path.

Commands expose keyboard and VoiceOver labels. **Open Editor** remains
available without an active capture so the user can access the library and
other existing app sections.

## Shortcut configuration

A shortcut value contains a Carbon-compatible key code and modifier flags. The
app stores the value in `UserDefaults` and supplies **Shift-Command-1** when no
preference exists.

The settings window provides a keyboard-shortcut recorder. A valid shortcut
must include at least one modifier so ordinary typing cannot start capture.
When the user records a valid shortcut, the app:

1. Attempts to register the new global shortcut.
2. Keeps the existing shortcut registered until the new registration succeeds.
3. Publishes the new preference only after successful registration.
4. Unregisters the old shortcut after the replacement becomes active.

If registration fails because macOS or another application owns the
combination, the app keeps the previous shortcut and displays an inline error
in **Settings**. The shortcut controller unregisters its Carbon hot key during
replacement and deinitialization and reports registration failures instead of
ignoring them.

## Capture and post-capture flow

The global shortcut and **Capture Area** command share one capture action:

1. Present area-selection overlays on every eligible display.
2. Let the user drag a region and complete or cancel selection.
3. Persist and publish a successful capture through the existing capture
   pipeline.
4. Store the capture as the active capture without opening the editor.
5. Present the post-capture action panel beside the selected rectangle.

Cancellation closes the selection overlays and returns to the menu-bar-only
state. Permission and capture failures do not present the action panel or open
the editor.

Starting another capture dismisses any existing post-capture panel before the
new selection overlays appear.

## Post-capture action panel

The selected design is a compact horizontal action panel positioned beside the
captured area. It contains a thumbnail and **Copy**, **Save**, and **Editor**.

The panel uses a non-activating floating `NSPanel` so it can appear above other
applications without moving keyboard focus. Placement prefers the space below
the captured rectangle, then above it. The coordinator clamps the final frame
to the visible frame of the display containing the capture. This keeps the
entire panel reachable near screen edges and across multiple displays.

The panel dismisses when the user:

- Selects **Copy**, **Save**, or **Editor**.
- Presses Escape.
- Clicks outside the panel.
- Starts another capture.

Each action executes at most once:

- **Copy** writes the captured image to the system clipboard.
- **Save** opens the existing save destination workflow.
- **Editor** opens or focuses the named editor window, activates the app, and
  displays the captured image.

The capture remains in the app's existing library after the panel closes.

## Component responsibilities

`TakeAShotApp` composes the menu-bar, editor, and settings scenes. It supplies
scene actions for opening the editor and settings windows without placing
SwiftUI environment values in model code.

`HotKeyController` owns registration, replacement, and removal of the Carbon
global hot key. It publishes typed registration errors and invokes the shared
capture action.

`ShortcutPreference` represents and persists the selected key and modifiers.
It owns the default shortcut and validation rules but does not register hot
keys.

`PostCapturePanelCoordinator` owns the panel window, placement, dismissal, and
action dispatch. It receives an immutable captured-image value and closures for
the three actions. It does not own capture persistence or editor state.

`AppState` continues to own the active capture. Successful publication updates
the state and requests post-capture presentation. The editor action requests
the editor scene only after `AppState` has accepted the capture.

## Error handling

The feature handles these failures explicitly:

- Missing screen-recording permission presents an actionable message with a
  path to macOS settings.
- Shortcut registration failure leaves the last working shortcut active and
  shows the rejected combination in **Settings**.
- Capture persistence failure does not publish a capture or present actions.
- Clipboard failure keeps the panel available and reports that copying failed.
- Save workflow failure keeps the capture in the library and reports the save
  error through the existing app error path.
- Editor-window presentation failure keeps the capture available in the
  library and leaves **Open Editor** available in the menu-bar menu.

No failure silently discards the captured image or disables the last working
global shortcut.

## Accessibility

The menu-bar commands, settings controls, and post-capture actions provide
descriptive VoiceOver labels and keyboard focus indicators. The action panel
supports Escape dismissal and keyboard activation without requiring pointer
input. Its placement respects the visible screen frame so macOS accessibility
overlays and the menu bar do not cover it.

The shortcut recorder announces the current shortcut, rejected combinations,
and successful replacement. The UI does not communicate state through color
alone.

## Testing strategy

### Shortcut tests

- **Shift-Command-1** is the default shortcut.
- A valid shortcut round-trips through preference storage.
- Successful replacement registers the new shortcut and unregisters the old
  shortcut exactly once.
- Failed replacement preserves the previous registration and preference.
- Shortcut validation rejects combinations without modifiers.

### Capture and action tests

- Successful capture installs the active capture and presents one action
  panel without opening the editor.
- Cancellation and capture failure do not present an action panel.
- **Copy**, **Save**, and **Editor** dispatch their action exactly once and
  dismiss the panel after success.
- Failed copy or save actions preserve access to the captured image.
- Starting another capture dismisses the previous action panel.

### Window and placement tests

- Panel placement prefers below, falls back above, and clamps to the active
  display's visible frame.
- **Editor** requests the named window after the active capture is installed.
- Closing the editor does not terminate the app or remove the menu-bar item.
- The app configuration declares accessory operation without a Dock icon.

### macOS smoke verification

Build and launch the app on macOS, then verify:

1. Only the menu-bar icon appears at launch.
2. **Shift-Command-1** opens the area selector.
3. Completing selection shows the action panel beside the captured rectangle.
4. **Copy**, **Save**, and **Editor** perform their expected actions.
5. **Editor** opens the editor window with the captured image.
6. Closing the editor returns to menu-bar-only operation.
7. Changing the shortcut in **Settings** takes effect immediately and survives
   relaunch.
8. A conflicting shortcut leaves the previous shortcut active and shows an
   actionable error.

## Success criteria

The feature is complete when Take a Shot launches without a Dock icon, remains
available from the macOS menu bar, accepts a configurable global shortcut with
**Shift-Command-1** as its default, presents the selected compact action panel
after successful area capture, and opens the editor only when the user selects
**Editor** or **Open Editor**.
