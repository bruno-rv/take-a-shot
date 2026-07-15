# Menu Bar Capture Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Take a Shot as a menu-bar-only app with a configurable global
capture shortcut and a post-capture Copy, Save, or Editor panel.

**Architecture:** Native SwiftUI `MenuBarExtra`, `Window`, and `Settings`
scenes compose an accessory macOS app. Typed shortcut, hot-key, capture
publication, and panel-coordinator boundaries keep Carbon and AppKit behavior
testable while `AppState` remains the owner of the accepted capture.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Carbon, ScreenCaptureKit, XCTest,
Xcode 16, and macOS 14.

## Global constraints

- Preserve macOS 14 as the deployment target.
- Add no package dependency.
- Show no Dock or application-switcher icon during ordinary operation.
- Use **Shift-Command-1** as the default area-capture shortcut.
- Require at least one modifier in a recorded shortcut.
- Keep the previous shortcut active when replacement registration fails.
- Present post-capture actions only after persistence and `AppState` install
  succeed.
- Use PNG as the single **Save** action's lossless default format.
- Keep every new panel and window fully reachable on the active display.
- Preserve the existing coordinated termination path.
- Follow test-driven development: observe the intended failure before adding
  production behavior.
- Update `TakeAShot.xcodeproj/project.pbxproj` whenever a task adds a Swift
  source or test file because this project does not use synchronized groups.

---

### Task 1: Model and persist the capture shortcut

**Files:**

- Create: `TakeAShot/ShortcutPreference.swift`
- Create: `TakeAShotTests/ShortcutPreferenceTests.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: Carbon key codes and modifier constants.
- Produces: `ShortcutPreference`, `ShortcutPreference.default`,
  `ShortcutPreference.isValid`, `ShortcutPreference.displayName`, and
  `ShortcutPreferenceStore`.

- [ ] **Step 1: Add the source and test file references to the Xcode project**

Add `PBXFileReference` and `PBXBuildFile` records for both files, place the
files in the existing `TakeAShot` and `TakeAShotTests` groups, and add them to
the corresponding Sources phases. Use new unique 24-character hexadecimal
identifiers consistent with the existing project file.

- [ ] **Step 2: Write failing shortcut model and storage tests**

Create `TakeAShotTests/ShortcutPreferenceTests.swift`:

```swift
import Carbon
import XCTest
@testable import TakeAShot

final class ShortcutPreferenceTests: XCTestCase {
    func testDefaultIsShiftCommandOne() {
        XCTAssertEqual(ShortcutPreference.default.keyCode,
                       UInt32(kVK_ANSI_1))
        XCTAssertEqual(ShortcutPreference.default.modifiers,
                       UInt32(shiftKey | cmdKey))
        XCTAssertEqual(ShortcutPreference.default.displayName, "⇧⌘1")
    }

    func testValidationRequiresASupportedModifier() {
        XCTAssertFalse(ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_1), modifiers: 0
        ).isValid)
        XCTAssertTrue(ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey)
        ).isValid)
    }

    func testStoreRoundTripsAndFallsBackToDefault() throws {
        let suite = "ShortcutPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutPreferenceStore(defaults: defaults,
                                            key: "captureShortcut")

        XCTAssertEqual(store.load(), .default)
        let custom = ShortcutPreference(
            keyCode: UInt32(kVK_ANSI_2),
            modifiers: UInt32(optionKey | cmdKey)
        )
        try store.save(custom)
        XCTAssertEqual(store.load(), custom)
    }
}
```

- [ ] **Step 3: Run the focused test and confirm RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project TakeAShot.xcodeproj -scheme TakeAShot -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/take-a-shot-menu-bar-derived \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:TakeAShotTests/ShortcutPreferenceTests
```

Expected: compilation fails because `ShortcutPreference` and
`ShortcutPreferenceStore` do not exist.

- [ ] **Step 4: Implement the shortcut value and store**

Create `TakeAShot/ShortcutPreference.swift` with these concrete declarations:

```swift
import Carbon
import Foundation

struct ShortcutPreference: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let `default` = ShortcutPreference(
        keyCode: UInt32(kVK_ANSI_1),
        modifiers: UInt32(shiftKey | cmdKey)
    )

    var isValid: Bool {
        let supported = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return modifiers & supported != 0
    }

    var displayName: String {
        ShortcutDisplayName.make(keyCode: keyCode, modifiers: modifiers)
    }
}

struct ShortcutPreferenceStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard,
         key: String = "captureShortcut") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> ShortcutPreference {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(
                  ShortcutPreference.self, from: data
              ), value.isValid else { return .default }
        return value
    }

    func save(_ value: ShortcutPreference) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }
}
```

Implement `ShortcutDisplayName.make` in the same file with an explicit mapping
for digits `0...9` and modifier glyphs ordered Control, Option, Shift, Command.
Return the numeric key code in brackets for an unmapped key so Settings never
shows an empty shortcut.

- [ ] **Step 5: Run the focused test and confirm GREEN**

Run the command from Step 3. Expected: all three tests pass.

- [ ] **Step 6: Commit the shortcut model**

```bash
git add TakeAShot/ShortcutPreference.swift \
  TakeAShotTests/ShortcutPreferenceTests.swift \
  TakeAShot.xcodeproj/project.pbxproj
git commit -m "feat: model configurable capture shortcut"
```

---

### Task 2: Replace the fixed Carbon hot key safely

**Files:**

- Create: `TakeAShot/HotKeyController.swift`
- Create: `TakeAShotTests/HotKeyControllerTests.swift`
- Modify: `TakeAShot/CaptureController.swift:406-443`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: `ShortcutPreference` and `ShortcutPreferenceStore` from Task 1.
- Produces: `HotKeyRegistering`, `CarbonHotKeyRegistrar`,
  `HotKeyRegistrationError`, and `HotKeyController` with
  `start()`, `replace(with:)`, `currentShortcut`, and `registrationError`.

- [ ] **Step 1: Add both new files to the Xcode project**

Add the app and test file records to their groups and Sources phases exactly as
in Task 1, using distinct project identifiers.

- [ ] **Step 2: Write failing registration-order and rollback tests**

Create `TakeAShotTests/HotKeyControllerTests.swift` with a recorder registrar
that returns integer-backed tokens and can fail the next registration. Test:

```swift
@MainActor
func testSuccessfulReplacementRegistersBeforePersistingAndUnregistering() {
    let fixture = HotKeyFixture(initial: .default)
    fixture.controller.start()
    let replacement = ShortcutPreference(
        keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey | cmdKey)
    )

    XCTAssertTrue(fixture.controller.replace(with: replacement))
    XCTAssertEqual(fixture.registrar.events, [
        .register(.default), .register(replacement), .unregister(1)
    ])
    XCTAssertEqual(fixture.store.load(), replacement)
    XCTAssertEqual(fixture.controller.currentShortcut, replacement)
}

@MainActor
func testFailedReplacementKeepsRegistrationAndPreference() {
    let fixture = HotKeyFixture(initial: .default)
    fixture.controller.start()
    fixture.registrar.failNextRegistration = true
    let rejected = ShortcutPreference(
        keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(controlKey | cmdKey)
    )

    XCTAssertFalse(fixture.controller.replace(with: rejected))
    XCTAssertEqual(fixture.registrar.events, [
        .register(.default), .register(rejected)
    ])
    XCTAssertEqual(fixture.store.load(), .default)
    XCTAssertEqual(fixture.controller.currentShortcut, .default)
    XCTAssertNotNil(fixture.controller.registrationError)
}
```

Add tests proving invalid shortcuts never reach the registrar and releasing the
controller unregisters the active token once.

- [ ] **Step 3: Run the focused test and confirm RED**

Run the Task 1 test command with
`-only-testing:TakeAShotTests/HotKeyControllerTests`. Expected: compilation
fails because the injectable hot-key interfaces do not exist.

- [ ] **Step 4: Implement the injectable controller and Carbon adapter**

Create `TakeAShot/HotKeyController.swift` around these interfaces:

```swift
protocol HotKeyRegistering: AnyObject {
    associatedtype Token
    func register(_ shortcut: ShortcutPreference,
                  action: @escaping @MainActor () -> Void) throws -> Token
    func unregister(_ token: Token)
}

enum HotKeyRegistrationError: LocalizedError, Equatable {
    case invalidShortcut
    case registrationFailed(OSStatus)
    case preferenceSaveFailed
}

@MainActor
final class HotKeyController<Registrar: HotKeyRegistering>: ObservableObject {
    @Published private(set) var currentShortcut: ShortcutPreference
    @Published private(set) var registrationError: HotKeyRegistrationError?

    func start()
    @discardableResult func replace(with shortcut: ShortcutPreference) -> Bool
}
```

Implement `start()` by registering the stored shortcut once. Implement
`replace(with:)` in this exact order: validate, no-op if unchanged, register a
new token, save the preference, swap tokens, unregister the old token, publish
the new current shortcut. If saving fails, unregister the new token and retain
the old token. `deinit` removes the active token.

`CarbonHotKeyRegistrar` installs one application event handler, assigns a
unique `EventHotKeyID` per registration, maps callbacks to main-actor actions,
checks every `OSStatus`, and unregisters each `EventHotKeyRef` exactly once.

Delete the fixed singleton implementation from
`CaptureController.swift:412-443`. Remove the old launch-time `register()` call
from `AppDelegate`; Task 5 will start the runtime-owned controller.

- [ ] **Step 5: Run focused shortcut and hot-key tests**

Run both `ShortcutPreferenceTests` and `HotKeyControllerTests`. Expected: all
tests pass without Carbon registration warnings.

- [ ] **Step 6: Commit the hot-key controller**

```bash
git add TakeAShot/HotKeyController.swift \
  TakeAShot/CaptureController.swift \
  TakeAShotTests/HotKeyControllerTests.swift \
  TakeAShot.xcodeproj/project.pbxproj
git commit -m "feat: register configurable global shortcut safely"
```

---

### Task 3: Build testable post-capture panel behavior

**Files:**

- Create: `TakeAShot/PostCapturePanel.swift`
- Create: `TakeAShotTests/PostCapturePanelTests.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: `CapturedImage`, `AreaSelection`, `NSScreen`, and async action
  closures.
- Produces: `PostCapturePanelPlacement`, `PostCaptureActions`,
  `PostCaptureActionDispatcher`, and `PostCapturePanelCoordinator`.

- [ ] **Step 1: Add both new files to the Xcode project**

Add file and build records, group children, and Sources phase entries for the
new app and test files.

- [ ] **Step 2: Write failing placement and dispatch tests**

Create `TakeAShotTests/PostCapturePanelTests.swift`. Cover below placement,
above fallback, horizontal and vertical clamping, action success, action
failure, and concurrent duplicate suppression. Use these assertions:

```swift
func testPlacementPrefersBelowAndClampsToVisibleFrame() {
    let frame = PostCapturePanelPlacement.frame(
        captureRect: CGRect(x: 900, y: 700, width: 180, height: 100),
        panelSize: CGSize(width: 260, height: 64),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
        spacing: 8
    )
    XCTAssertEqual(frame.maxX, 1_000)
    XCTAssertEqual(frame.maxY, 692)
}

@MainActor
func testFailedActionKeepsPanelAndAllowsRetry() async {
    var attempts = 0
    let dispatcher = PostCaptureActionDispatcher(
        dismiss: { XCTFail("failure must not dismiss") }
    )
    await dispatcher.perform {
        attempts += 1
        return false
    }
    await dispatcher.perform {
        attempts += 1
        return false
    }
    XCTAssertEqual(attempts, 2)
}

@MainActor
func testSuccessfulActionDismissesExactlyOnce() async {
    var dismissals = 0
    let dispatcher = PostCaptureActionDispatcher {
        dismissals += 1
    }
    await dispatcher.perform { true }
    await dispatcher.perform { true }
    XCTAssertEqual(dismissals, 1)
}
```

- [ ] **Step 3: Run the focused test and confirm RED**

Run the standard xcodebuild command with
`-only-testing:TakeAShotTests/PostCapturePanelTests`. Expected: compilation
fails because the panel types do not exist.

- [ ] **Step 4: Implement placement, action dispatch, and the panel
  coordinator**

Create `TakeAShot/PostCapturePanel.swift` with these public-internal seams:

```swift
enum PostCapturePanelPlacement {
    static func frame(captureRect: CGRect, panelSize: CGSize,
                      visibleFrame: CGRect, spacing: CGFloat = 8) -> CGRect
}

struct PostCaptureActions {
    let copy: @MainActor () async -> Bool
    let save: @MainActor () async -> Bool
    let edit: @MainActor () async -> Bool
}

@MainActor
final class PostCaptureActionDispatcher {
    private var isPerforming = false
    private var didComplete = false
    private let dismiss: () -> Void

    init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }

    func perform(_ action: @escaping @MainActor () async -> Bool) async {
        guard !isPerforming, !didComplete else { return }
        isPerforming = true
        let succeeded = await action()
        isPerforming = false
        guard succeeded else { return }
        didComplete = true
        dismiss()
    }
}

@MainActor
final class PostCapturePanelCoordinator {
    func present(capture: CapturedImage, selection: AreaSelection,
                 actions: PostCaptureActions)
    func dismiss()
}
```

Calculate placement by centering on the capture, preferring the space below in
AppKit coordinates, falling back above, and clamping both axes to
`visibleFrame`.

The coordinator creates a borderless, non-activating floating `NSPanel` with
`.canJoinAllSpaces` and `.fullScreenAuxiliary`, hosts a SwiftUI thumbnail and
**Copy**, **Save**, and **Editor** buttons, selects the screen by
`selection.displayID`, and removes Escape and outside-click event monitors in
`dismiss()`. Presenting another capture calls `dismiss()` first. The buttons
invoke `PostCaptureActionDispatcher` so failures leave the panel available and
success dismisses exactly once.

- [ ] **Step 5: Run the focused panel tests and confirm GREEN**

Run the command from Step 3. Expected: all placement and dispatcher tests pass.

- [ ] **Step 6: Commit the post-capture panel**

```bash
git add TakeAShot/PostCapturePanel.swift \
  TakeAShotTests/PostCapturePanelTests.swift \
  TakeAShot.xcodeproj/project.pbxproj
git commit -m "feat: add post-capture action panel"
```

---

### Task 4: Publish area context after capture installation

**Files:**

- Modify: `TakeAShot/CaptureController.swift:316-403,768-800,931-952`
- Modify: `TakeAShot/Models.swift:218-225,328-411,587-613,917-945`
- Modify: `TakeAShotTests/ScreenCaptureTests.swift`
- Modify: `TakeAShotTests/AnnotationModelTests.swift`
- Modify: `TakeAShotTests/TestSupport.swift:193-205`

**Interfaces:**

- Consumes: capture persistence, `AreaSelection`, `AppState`, and exporter
  protocols.
- Produces: `CapturePublication`, `receiveCapture(_:afterInstall:)`,
  `copyActiveCaptureForPostCapture()`, and
  `saveActiveCaptureForPostCapture(format:)`.

- [ ] **Step 1: Write failing capture-publication tests**

Extend `ScreenCaptureTests` so an area capture records a publication and
asserts:

```swift
XCTAssertEqual(publisher.publications.count, 1)
XCTAssertEqual(publisher.publications[0].capture.id, captured.id)
XCTAssertEqual(publisher.publications[0].areaSelection, selection)
```

Add a display-capture assertion that `areaSelection` is `nil`, and preserve the
existing test that persistence failure yields no publication.

- [ ] **Step 2: Write failing AppState post-install and export-result tests**

Extend `AnnotationModelTests` with one immediate install and one gated switch
test. In both, call:

```swift
state.receiveCapture(nextCapture) {
    acceptedID = state.activeCapture?.id
}
```

Assert the callback observes `nextCapture.id`, fires once, and does not fire
when annotation flushing fails. Add exporter-stub tests asserting the new copy
and PNG-save functions return `true` on success, `false` on error, and publish
the existing user-facing error on failure.

- [ ] **Step 3: Run the focused tests and confirm RED**

Run the standard xcodebuild command with the specific new
`ScreenCaptureTests` and `AnnotationModelTests` methods. Expected: compilation
fails because `CapturePublication` and the new AppState APIs do not exist.

- [ ] **Step 4: Carry capture context through persistence and publication**

Add:

```swift
struct CapturePublication: @unchecked Sendable {
    let capture: CapturedImage
    let areaSelection: AreaSelection?
}

@MainActor
protocol CapturePublishing: AnyObject {
    func publish(_ publication: CapturePublication)
}
```

Change `CapturePipeline.captureArea` to accept `AreaSelection`, pass its `rect`
and display to the existing capturer, and call `persistAndPublish` with the
selection. Give `persistAndPublish` an `areaSelection: AreaSelection? = nil`
parameter and publish `CapturePublication` only after persistence succeeds.
Display, window, and scrolling paths keep the default `nil` context.

Change `AppCapturePublisher.onCapture` and all test publishers to accept
`CapturePublication`.

- [ ] **Step 5: Invoke presentation only after AppState accepts the capture**

Change AppState APIs to:

```swift
func receiveCapture(
    _ capture: CapturedImage,
    afterInstall: @escaping @MainActor () -> Void = {}
)

private func switchToCapture(
    _ capture: CapturedImage,
    document: AnnotationDocument,
    afterInstall: @escaping @MainActor () -> Void
)
```

Call `afterInstall()` immediately after `install` in both initial and switched
capture paths, never in an error path. Add an
`onAreaCaptureAccepted: @MainActor (CapturedImage, AreaSelection) -> Void`
parameter to `AppState.live`. Its publisher callback calls `receiveCapture`
and invokes the area callback inside `afterInstall` only when the publication
contains an area selection.

Refactor the existing fire-and-forget export methods through:

```swift
@discardableResult
func copyActiveCaptureForPostCapture() async -> Bool

@discardableResult
func saveActiveCaptureForPostCapture(
    format: ExportFormat = .png
) async -> Bool
```

Snapshot the active capture and document, await the existing exporter, and
return `true`. On error, call the existing `present` error path and return
`false`. Keep `copyActiveCapture()` and `saveActiveCapture(format:)` as Task
wrappers around these functions so current UI behavior stays source-compatible.

- [ ] **Step 6: Run focused and existing capture-model tests**

Run `ScreenCaptureTests` and `AnnotationModelTests`. Expected: all tests pass,
including persistence-before-publication and annotation-flush gating tests.

- [ ] **Step 7: Commit capture publication integration**

```bash
git add TakeAShot/CaptureController.swift TakeAShot/Models.swift \
  TakeAShotTests/ScreenCaptureTests.swift \
  TakeAShotTests/AnnotationModelTests.swift TakeAShotTests/TestSupport.swift
git commit -m "feat: publish post-capture context after installation"
```

---

### Task 5: Compose the menu-bar app, settings, and editor window

**Files:**

- Create: `TakeAShot/AppRuntime.swift`
- Create: `TakeAShot/MenuBarViews.swift`
- Create: `TakeAShot/ShortcutSettingsView.swift`
- Create: `TakeAShotTests/AppRuntimeTests.swift`
- Modify: `TakeAShot/TakeAShotApp.swift:38-62`
- Modify: `TakeAShot/RecordingUsage.plist`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: `AppState.live(onAreaCaptureAccepted:)`, `HotKeyController`,
  `PostCapturePanelCoordinator`, and SwiftUI scene actions.
- Produces: `AppRuntime`, `AppSceneActions`, menu-bar content, editor/settings
  scenes, and shortcut recorder UI.

- [ ] **Step 1: Add all app and test files to the Xcode project**

Add four file references, four build-file references, group entries, and the
correct app or test Sources phase entries.

- [ ] **Step 2: Write failing runtime and configuration tests**

Create `TakeAShotTests/AppRuntimeTests.swift`. Inject spy panel, hot-key, scene,
and AppState-facing closures into the runtime. Assert:

```swift
@MainActor
func testBeginningCaptureDismissesPanelBeforeAreaCapture() {
    runtime.beginAreaCapture()
    XCTAssertEqual(events, [.dismissPanel, .captureArea])
}

@MainActor
func testEditorActionActivatesAfterCaptureIsInstalled() async {
    runtime.presentPostCapture(capture: capture, selection: selection)
    let actions = try! XCTUnwrap(panel.presentedActions)
    XCTAssertTrue(await actions.edit())
    XCTAssertEqual(events, [.presentPanel, .activateApp, .openEditor])
}
```

Add a plist test that loads `TakeAShot/RecordingUsage.plist` and asserts
`LSUIElement == true`. Add a source-level scene assertion only if the runtime
behavior cannot be expressed through injected scene actions.

- [ ] **Step 3: Run runtime tests and confirm RED**

Run the standard xcodebuild command with
`-only-testing:TakeAShotTests/AppRuntimeTests`. Expected: compilation fails
because the runtime types do not exist and the plist lacks `LSUIElement`.

- [ ] **Step 4: Implement the runtime composition**

Create an `@MainActor AppSceneActions` reference type with installed closures:

```swift
@MainActor
final class AppSceneActions {
    var openEditor: () -> Void = {}
    var openSettings: () -> Void = {}
}
```

Create `AppRuntime` as the single owner of `AppState`, hot-key controller,
panel coordinator, shortcut store, and scene actions. Its shared capture method
must preserve this order:

```swift
func beginAreaCapture() {
    postCapturePanel.dismiss()
    appState.capture(mode: .area, options: CaptureOptions())
}
```

Define
`func presentPostCapture(capture: CapturedImage, selection: AreaSelection)` to
build the actions below and pass them to `postCapturePanel.present`. Supply this
method as `AppState.live(onAreaCaptureAccepted:)`'s callback.

Build `AppState.live(onAreaCaptureAccepted:)` so the callback presents the
panel with closures that call:

```swift
PostCaptureActions(
    copy: { await appState.copyActiveCaptureForPostCapture() },
    save: { await appState.saveActiveCaptureForPostCapture(format: .png) },
    edit: {
        NSApp.activate(ignoringOtherApps: true)
        sceneActions.openEditor()
        return true
    }
)
```

Both the menu command and hot-key action call `beginAreaCapture()`. Start the
hot-key controller once from the runtime, not from `AppDelegate`.

- [ ] **Step 5: Implement native menu-bar, editor, and settings scenes**

Replace the implicit `WindowGroup` in `TakeAShotApp.body` with:

```swift
MenuBarExtra("Take a Shot", systemImage: "camera.viewfinder") {
    MenuBarContent(runtime: runtime)
}

Window("Take a Shot", id: "editor") {
    MacContentView(appState: runtime.appState)
        .environmentObject(runtime.appState)
}

Settings {
    ShortcutSettingsView(controller: runtime.hotKeyController)
}
```

`MenuBarContent` captures `openWindow` and `openSettings` environment actions,
installs them into `AppSceneActions`, and exposes **Capture Area**,
**Open Editor**, `SettingsLink`, and **Quit**. **Quit** calls
`NSApp.terminate(nil)` so `AppDelegate.applicationShouldTerminate` continues to
coordinate pending work.

Implement `ShortcutSettingsView` with an `NSViewRepresentable` recorder that
becomes first responder while recording, converts `NSEvent` key code and flags
to Carbon values, rejects modifier-free input, calls `replace(with:)`, and
announces current, rejected, and accepted shortcuts through visible text and
accessibility labels.

Add `<key>LSUIElement</key><true/>` to `RecordingUsage.plist`. Set
`NSApp.setActivationPolicy(.accessory)` in
`applicationDidFinishLaunching` as deterministic runtime reinforcement. Do not
use `defaultLaunchBehavior(.suppressed)` because it requires macOS 15.

- [ ] **Step 6: Run focused runtime and shortcut tests**

Run `AppRuntimeTests`, `ShortcutPreferenceTests`, `HotKeyControllerTests`, and
`PostCapturePanelTests`. Expected: all pass.

- [ ] **Step 7: Commit app lifecycle and settings**

```bash
git add TakeAShot/AppRuntime.swift TakeAShot/MenuBarViews.swift \
  TakeAShot/ShortcutSettingsView.swift TakeAShot/TakeAShotApp.swift \
  TakeAShot/RecordingUsage.plist TakeAShotTests/AppRuntimeTests.swift \
  TakeAShot.xcodeproj/project.pbxproj
git commit -m "feat: run capture workflow from the menu bar"
```

---

### Task 6: Verify the complete macOS workflow

**Files:**

- Modify only files required by failures that reproduce the approved behavior.
- Verify: `TakeAShot.xcodeproj/project.pbxproj`
- Verify: built `TakeAShot.app/Contents/Info.plist`

**Interfaces:**

- Consumes: every deliverable from Tasks 1 through 5.
- Produces: a clean full test run, release-equivalent build evidence, and a
  recorded manual smoke result.

- [ ] **Step 1: Check project consistency and the complete diff**

Run:

```bash
git diff --check
git status --short
xcodebuild -project TakeAShot.xcodeproj -scheme TakeAShot \
  -showBuildSettings >/tmp/take-a-shot-build-settings.txt
```

Expected: no whitespace errors, only intentional feature files are changed,
and Xcode loads the project without missing file references.

- [ ] **Step 2: Run the complete automated test suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project TakeAShot.xcodeproj -scheme TakeAShot -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/take-a-shot-menu-bar-derived \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `** TEST SUCCEEDED **` with no failing TakeAShot tests.

- [ ] **Step 3: Build the application and verify accessory metadata**

```bash
./script/build_and_run.sh --verify
plutil -extract LSUIElement raw \
  /tmp/take-a-shot-menu-bar-derived/Build/Products/Debug/TakeAShot.app/\
Contents/Info.plist
```

If the helper uses a different Derived Data directory, run a Debug build with
the Task 2 xcodebuild flags before `plutil`. Expected plist output: `true`.

- [ ] **Step 4: Perform the macOS smoke flow**

Launch the built app and verify, in order:

1. The menu-bar icon appears without a Dock or application-switcher icon.
2. **Shift-Command-1** opens area selection.
3. Completing selection shows the compact panel beside the selected area.
4. **Copy** writes the image and dismisses the panel.
5. **Save** opens the PNG save destination and dismisses after success.
6. **Editor** opens the editor with the selected capture.
7. Closing the editor leaves the menu-bar item running.
8. Changing the shortcut in **Settings** takes effect immediately and survives
   relaunch.
9. A conflicting shortcut leaves the previous shortcut active and shows an
   inline error.
10. Cancelling selection and denying permission do not open the panel or
    editor.

- [ ] **Step 5: Run final regression checks after any smoke fix**

If Step 4 exposes a defect, add a focused failing test, observe RED, implement
the minimum correction, rerun the focused test, then rerun Steps 1 through 4.
Expected: all automated and manual checks pass.

- [ ] **Step 6: Commit verification fixes only when needed**

```bash
git add -u TakeAShot TakeAShotTests TakeAShot.xcodeproj/project.pbxproj
git commit -m "fix: complete menu bar capture workflow"
```

If no fix is needed, do not create an empty commit.
