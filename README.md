# Take a Shot

<p align="center">
  <img src="docs/assets/app-icon.png" alt="Take a Shot app icon" width="160">
</p>

Native macOS SwiftUI app for a screenshot capture and annotation workflow inspired by desktop screenshot utilities.

## Open

Open `TakeAShot.xcodeproj` in Xcode, choose the `TakeAShot` scheme, then run on My Mac. From Codex, use the Run action or:

```bash
./script/build_and_run.sh
```

## Capture Flow

- Press `Shift Option 5` anywhere on macOS to open the capture overlay.
- Drag a rectangle to capture a selected slice of the screen.
- Press `Return` while the overlay is visible to capture the whole screen.
- Press `Esc` to cancel.
- After capture, a floating thumbnail appears on the left side with `Copy`, `Save`, `Edit`, close, pin, and upload-style controls.
- The screenshot also loads into the main editor canvas, where the inspector can copy it again.

macOS may ask for Screen Recording permission the first time capture runs. If permission is denied, the app opens the Screen Recording privacy settings pane.

## Notes

The app currently implements real area/fullscreen capture, clipboard copy, PNG save, a floating thumbnail, and a native editor shell. Window capture, scrolling capture, recording, cloud upload, and advanced annotation editing are UI placeholders for future work.
