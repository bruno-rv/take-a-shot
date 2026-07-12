# Smart Pins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add durable, accessible, floating image references that reuse the
local capture library, survive relaunch when requested, and remain isolated
from new captures and recordings.

**Architecture:** `PinCoordinator` owns pin identity and application actions,
`PinWindowCoordinator` owns one `NSPanel` per active pin, and actor-isolated
stores and caches own metadata and bounded rendering resources. Pins reference
library UUIDs and never own media. Capture and recording operations acquire a
reference-counted visibility lease before they can expose a pin in output.

**Tech Stack:** Swift 6 language-compatible Swift, SwiftUI, AppKit `NSPanel`,
ScreenCaptureKit, Core Graphics/Core Image, Carbon hot keys, XCTest, and the
existing actor-isolated JSON/file persistence patterns.

## Global Constraints

- Target macOS 14 or later and use only native Apple frameworks.
- Keep `CaptureLibraryStore` as the only owner of media, annotations, OCR, and
  thumbnails.
- Support image capture kinds only; do not pin MP4 or GIF media in v1.
- Enforce one live pin per capture UUID.
- Render pin surfaces off the main actor with a 4,096-pixel longest-edge cap.
- Keep decoded pin surfaces within a 256 MiB least-recently-used budget.
- Persist layout changes after a 250-millisecond debounce and publish metadata
  atomically.
- Never enable click-through unless a global recovery path is registered.
- Do not implement boards, notes, live refresh, visual comparison, or cloud
  synchronization.
- Follow strict red-green-refactor TDD and review each task before continuing.

---

## File structure

New production files:

- `TakeAShot/PinModels.swift`: persisted data, typed errors, and pure geometry.
- `TakeAShot/PinStore.swift`: versioned codec, atomic metadata, and debounce.
- `TakeAShot/PinWindowCoordinator.swift`: panels, displays, and window lifecycle.
- `TakeAShot/PinShortcutController.swift`: injectable global recovery shortcut.
- `TakeAShot/PinSurfaceCache.swift`: bounded LRU decoded-image cache.
- `TakeAShot/PinViewModel.swift`: rendering, OCR actions, and panel state.
- `TakeAShot/PinCoordinator.swift`: pin identity, restoration, deletion, and app
  actions.
- `TakeAShot/CaptureVisibilityLease.swift`: nested visibility state machine.
- `TakeAShot/PinViews.swift`: pin content, controls, placeholder, and edge tab.

New test files:

- `TakeAShotTests/PinStoreTests.swift`
- `TakeAShotTests/PinWindowCoordinatorTests.swift`
- `TakeAShotTests/PinRenderingTests.swift`
- `TakeAShotTests/PinCoordinatorTests.swift`
- `TakeAShotTests/CaptureVisibilityLeaseTests.swift`

Existing integration files:

- `TakeAShot/Models.swift`
- `TakeAShot/MacContentView.swift`
- `TakeAShot/TakeAShotApp.swift`
- `TakeAShot/CaptureController.swift`
- `TakeAShot/ScreenCaptureEngine.swift`
- `TakeAShot/RecordingEngine.swift`
- `TakeAShot/CaptureLibrary.swift`
- `TakeAShot.xcodeproj/project.pbxproj`
- `README.md`

---

### Task 1: Persist versioned pin metadata atomically

**Files:**

- Create: `TakeAShot/PinModels.swift`
- Create: `TakeAShot/PinStore.swift`
- Create: `TakeAShotTests/PinStoreTests.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: `NormalizedPoint` from `TakeAShot/CaptureModels.swift`.
- Produces: `PinnedReference`, `PersistedPinFrame`, `PinEdge`,
  `PinStoreDocument`, `PinStoreError`, and `actor PinStore`.

- [ ] **Step 1: Add the model and codec tests to the test target**

Add the new source and test file references to the Xcode project, then write:

```swift
import XCTest
@testable import TakeAShot

final class PinStoreTests: XCTestCase {
    func testRoundTripPreservesEveryPersistedField() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PinStore(rootURL: root)
        let pin = PinnedReference.fixture(
            captureID: UUID(),
            frame: .init(
                displayID: "display-a",
                panelFrame: CGRect(x: 20, y: 30, width: 400, height: 240),
                previousVisibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)
            ),
            zoom: 2,
            pan: .init(x: 0.25, y: 0.75),
            opacity: 0.65,
            isClickThrough: true,
            collapsedEdge: .right,
            restoresAfterRelaunch: true
        )

        try await store.replaceAll([pin])

        let reloaded = try await PinStore(rootURL: root).load()
        XCTAssertEqual(reloaded, [pin])
    }

    func testMalformedRecordDoesNotHideValidRecords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = PinnedReference.fixture(captureID: UUID())
        let validData = try JSONEncoder().encode(valid)
        let validJSON = try XCTUnwrap(String(data: validData, encoding: .utf8))
        let source = """
        {"schemaVersion":1,"pins":[{"broken":],\(validJSON)]}
        """
        try Data(source.utf8).write(to: root.appendingPathComponent("pins.json"))

        let store = PinStore(rootURL: root)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, [valid])
        XCTAssertEqual(await store.loadIssues().count, 1)
    }

    func testDuplicateCaptureKeepsNewestValidRecord() async throws {
        let root = temporaryDirectory()
        let captureID = UUID()
        let older = PinnedReference.fixture(
            captureID: captureID,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = PinnedReference.fixture(
            captureID: captureID,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let store = PinStore(rootURL: root)

        try await store.replaceAll([older, newer])

        XCTAssertEqual(try await store.load(), [newer])
    }
}
```

Put the reusable `PinnedReference.fixture` factory in `PinStoreTests.swift` so
production code does not contain test helpers.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project TakeAShot.xcodeproj -scheme TakeAShot \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/take-a-shot-pin-store-red \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:TakeAShotTests/PinStoreTests
```

Expected: compilation fails because `PinStore` and `PinnedReference` do not
exist.

- [ ] **Step 3: Implement the persisted model**

Create `PinModels.swift` with these exact public-to-module types:

```swift
import CoreGraphics
import Foundation

enum PinEdge: String, Codable, CaseIterable, Sendable {
    case top, right, bottom, left
}

struct PersistedPinFrame: Codable, Equatable, Sendable {
    var displayID: String
    var panelFrame: CGRect
    var previousVisibleFrame: CGRect
}

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

    mutating func normalize() {
        zoom = min(max(zoom, 0.25), 8)
        opacity = min(max(opacity, 0.2), 1)
        normalizedPan = NormalizedPoint(
            x: min(max(normalizedPan.x, 0), 1),
            y: min(max(normalizedPan.y, 0), 1)
        )
    }
}

struct PinStoreDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    var pins: [PinnedReference]
}

struct PinLoadIssue: Equatable, Sendable {
    let recordIndex: Int
    let reason: String
}

enum PinStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case malformedDocument
    case atomicPublishFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Pin metadata uses unsupported schema version \(version)."
        case .malformedDocument:
            return "Pin metadata could not be read."
        case let .atomicPublishFailed(message):
            return "Pin metadata could not be saved: \(message)"
        }
    }
}
```

- [ ] **Step 4: Implement atomic storage and malformed-record isolation**

Create `PinStore.swift` with:

```swift
import Foundation

protocol PinFileOperating: Sendable {
    func createDirectory(at url: URL) throws
    func data(at url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func replaceItem(at destination: URL, with source: URL) throws
    func removeItem(at url: URL) throws
    func fileExists(at url: URL) -> Bool
}

actor PinStore {
    private let rootURL: URL
    private let documentURL: URL
    private let fileOperations: any PinFileOperating
    private var pins: [PinnedReference] = []
    private var issues: [PinLoadIssue] = []
    private var pendingWrite: Task<Void, Error>?

    init(
        rootURL: URL,
        fileOperations: any PinFileOperating = LivePinFileOperations()
    ) {
        self.rootURL = rootURL
        documentURL = rootURL.appendingPathComponent("pins.json")
        self.fileOperations = fileOperations
    }

    func load() throws -> [PinnedReference] {
        guard fileOperations.fileExists(at: documentURL) else {
            pins = []
            issues = []
            return []
        }
        let result = try PinDocumentCodec.decode(fileOperations.data(at: documentURL))
        pins = Self.deduplicate(result.pins)
        issues = result.issues
        return pins
    }

    func loadIssues() -> [PinLoadIssue] { issues }

    func replaceAll(_ newPins: [PinnedReference]) throws {
        pins = Self.deduplicate(newPins)
        try publishNow()
    }

    func scheduleUpsert(_ pin: PinnedReference) {
        pins.removeAll { $0.id == pin.id || $0.captureID == pin.captureID }
        pins.append(pin)
        pendingWrite?.cancel()
        pendingWrite = Task {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            try self.publishNow()
        }
    }

    func remove(id: UUID) throws {
        pins.removeAll { $0.id == id }
        try publishNow()
    }

    func flush() async throws {
        try await pendingWrite?.value
        pendingWrite = nil
    }
}
```

`PinDocumentCodec.decode` must validate `schemaVersion`, recover balanced JSON
object candidates inside the `pins` array, decode each candidate independently,
normalize valid records, and return one `PinLoadIssue` per rejected candidate.
`publishNow` must write a deterministic document to `pins.json.tmp`, replace
`pins.json` atomically, and remove the temporary file on every failure path.

- [ ] **Step 5: Add debounce and atomic rollback tests**

Add tests with an injected file operator and controlled clock:

```swift
func testDebouncedUpdatesPublishOnlyFinalLayout() async throws {
    let files = RecordingPinFileOperations()
    let store = PinStore(rootURL: temporaryDirectory(), fileOperations: files)
    var pin = PinnedReference.fixture(captureID: UUID())

    pin.opacity = 0.4
    await store.scheduleUpsert(pin)
    pin.opacity = 0.6
    await store.scheduleUpsert(pin)
    pin.opacity = 0.8
    await store.scheduleUpsert(pin)
    try await store.flush()

    XCTAssertEqual(files.atomicReplacementCount, 1)
    XCTAssertEqual(try await store.load().first?.opacity, 0.8)
}

func testPublishFailurePreservesPriorDocumentAndRemovesTemporaryFile() async throws {
    let files = FailingReplacementPinFileOperations()
    let root = temporaryDirectory()
    let store = PinStore(rootURL: root, fileOperations: files)
    let original = PinnedReference.fixture(captureID: UUID())
    try await store.replaceAll([original])
    files.failNextReplacement = true

    await XCTAssertThrowsErrorAsync {
        try await store.replaceAll([.fixture(captureID: UUID())])
    }

    XCTAssertEqual(try await PinStore(rootURL: root).load(), [original])
    XCTAssertFalse(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("pins.json.tmp").path
    ))
}
```

- [ ] **Step 6: Run GREEN and commit**

Run the focused command from Step 2. Expected: all `PinStoreTests` pass.

```bash
git add TakeAShot/PinModels.swift TakeAShot/PinStore.swift \
  TakeAShotTests/PinStoreTests.swift TakeAShot.xcodeproj/project.pbxproj
git commit -m "feat: persist smart pin metadata"
```

---

### Task 2: Build panel lifecycle, display restoration, and recovery shortcut

**Files:**

- Create: `TakeAShot/PinWindowCoordinator.swift`
- Create: `TakeAShot/PinShortcutController.swift`
- Create: `TakeAShotTests/PinWindowCoordinatorTests.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: `PinnedReference`, `PersistedPinFrame`, and `PinEdge` from Task 1.
- Produces: `PinPanelControlling`, `PinWindowCoordinator`,
  `PinDisplayGeometry`, `PinShortcutRegistering`, and `PinRecoveryShortcut`.

- [ ] **Step 1: Write panel and geometry RED tests**

```swift
@MainActor
final class PinWindowCoordinatorTests: XCTestCase {
    func testRestorationClampsRecoveryControlsOntoNearestDisplay() {
        let displays = [
            PinDisplayGeometry(
                id: "main",
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                backingScale: 2
            )
        ]
        let offscreen = PersistedPinFrame(
            displayID: "removed",
            panelFrame: CGRect(x: 2000, y: 1200, width: 400, height: 300),
            previousVisibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )

        let restored = PinFrameRestorer.restore(offscreen, displays: displays)

        XCTAssertTrue(displays[0].visibleFrame.contains(restored.origin))
        XCTAssertGreaterThanOrEqual(
            restored.intersection(displays[0].visibleFrame).width,
            PinFrameRestorer.minimumRecoverableWidth
        )
    }

    func testDuplicateOpenFocusesExistingPanel() async throws {
        let panels = RecordingPinPanelFactory()
        let coordinator = PinWindowCoordinator(panelFactory: panels)
        let pin = PinnedReference.fixture(captureID: UUID())

        try await coordinator.open(pin)
        try await coordinator.open(pin)

        XCTAssertEqual(panels.created.count, 1)
        XCTAssertEqual(panels.created[0].focusCount, 1)
    }

    func testClickThroughRequiresRegisteredRecoveryShortcut() async throws {
        let shortcut = StubPinShortcutRegistrar(result: .failure(.alreadyInUse))
        let coordinator = PinWindowCoordinator(shortcutRegistrar: shortcut)
        let pin = PinnedReference.fixture(captureID: UUID())
        try await coordinator.open(pin)

        await XCTAssertThrowsErrorAsync {
            try await coordinator.setClickThrough(true, pinID: pin.id)
        }

        XCTAssertFalse(coordinator.panel(for: pin.id)?.ignoresMouseEvents ?? true)
    }
}
```

- [ ] **Step 2: Run RED**

Run `PinWindowCoordinatorTests` through `xcodebuild` with derived data at
`/tmp/take-a-shot-pin-window-red`. Expected: missing panel types.

- [ ] **Step 3: Implement pure display restoration**

Add:

```swift
struct PinDisplayGeometry: Equatable, Sendable {
    let id: String
    let visibleFrame: CGRect
    let backingScale: CGFloat
}

enum PinFrameRestorer {
    static let minimumRecoverableWidth: CGFloat = 64
    static let minimumRecoverableHeight: CGFloat = 36

    static func restore(
        _ persisted: PersistedPinFrame,
        displays: [PinDisplayGeometry]
    ) -> CGRect
}
```

Restoration must prefer the stored display ID, otherwise select the display
whose visible frame is nearest the stored panel center. Map relative position
from `previousVisibleFrame`, preserve panel size up to the destination visible
frame, and clamp at least 64 by 36 points into view.

- [ ] **Step 4: Implement panel and coordinator boundaries**

Use these interfaces:

```swift
@MainActor
protocol PinPanelControlling: AnyObject {
    var pinID: UUID { get }
    var windowNumber: CGWindowID { get }
    var frame: CGRect { get set }
    var ignoresMouseEvents: Bool { get set }
    var isVisible: Bool { get }
    func show()
    func hide() async
    func focus()
    func close() async
    func collapse(to edge: PinEdge)
    func restoreFromCollapse()
}

@MainActor
final class PinWindowCoordinator {
    func open(_ pin: PinnedReference) async throws
    func close(pinID: UUID) async
    func setVisible(_ visible: Bool, pinID: UUID) async throws
    func setClickThrough(_ enabled: Bool, pinID: UUID) async throws
    func activeWindowIDs() -> Set<CGWindowID>
    func snapshotFrames() -> [UUID: PersistedPinFrame]
}
```

The live panel must be an `NSPanel` with `.borderless` and `.nonactivatingPanel`
style masks, `.floating` level, no shadow-dependent hit target, and an
`NSHostingController` root. Panel close and hide acknowledgements must be
exact-once so capture leases can await them safely.

- [ ] **Step 5: Implement injectable recovery shortcut registration**

```swift
struct PinRecoveryShortcut: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let defaultShortcut = PinRecoveryShortcut(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )
}

protocol PinShortcutRegistering: Sendable {
    func register(
        _ shortcut: PinRecoveryShortcut,
        handler: @escaping @Sendable () -> Void
    ) throws
    func unregister()
}
```

The live implementation must use a Carbon signature and hot-key ID distinct
from the existing capture shortcut. Registration errors map to typed
`PinShortcutError` values. `PinWindowCoordinator` registers on the first
click-through request and unregisters when no click-through pins remain.

- [ ] **Step 6: Run GREEN and commit**

Run focused window tests. Expected: all pass, including rapid close/reopen,
display replacement, edge collapse, and shortcut failure.

```bash
git add TakeAShot/PinWindowCoordinator.swift \
  TakeAShot/PinShortcutController.swift \
  TakeAShotTests/PinWindowCoordinatorTests.swift \
  TakeAShot.xcodeproj/project.pbxproj
git commit -m "feat: add smart pin windows"
```

---

### Task 3: Render composited pins with a bounded surface cache

**Files:**

- Create: `TakeAShot/PinSurfaceCache.swift`
- Create: `TakeAShot/PinViewModel.swift`
- Create: `TakeAShotTests/PinRenderingTests.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: `AppLibraryServing`, `AnnotationRenderServicing`, `CapturedImage`,
  and `AnnotationDocument`.
- Produces: `PinSurfaceCache`, `PinRendering`, `PinViewModel`, and
  `PinLibraryServing`.

- [ ] **Step 1: Write rendering and cache RED tests**

```swift
final class PinRenderingTests: XCTestCase {
    func testRendererAppliesPersistedCropAndAnnotationsOffMainActor() async throws {
        let library = StubPinLibrary(
            capture: .fixture(width: 1200, height: 800),
            annotations: .fixtureWithCropAndText()
        )
        let renderer = InspectingPinRenderer()
        let viewModel = await PinViewModel(
            pin: .fixture(captureID: library.capture.id),
            library: library,
            renderer: renderer,
            cache: PinSurfaceCache(byteLimit: 256 * 1_024 * 1_024)
        )

        try await viewModel.loadSurface(
            panelSize: CGSize(width: 400, height: 300),
            backingScale: 2
        )

        let request = try XCTUnwrap(await renderer.lastRequest)
        XCTAssertTrue(request.appliesCrop)
        XCTAssertFalse(request.executedOnMainThread)
        XCTAssertLessThanOrEqual(max(request.pixelSize.width, request.pixelSize.height), 4096)
    }

    func testCacheEvictsHiddenAndCollapsedBeforeVisibleSurfaces() async throws {
        let cache = PinSurfaceCache(byteLimit: 100)
        await cache.insert(.fixture(bytes: 60), for: UUID(), priority: .visible)
        let hiddenID = UUID()
        await cache.insert(.fixture(bytes: 40), for: hiddenID, priority: .hidden)
        await cache.insert(.fixture(bytes: 40), for: UUID(), priority: .visible)

        XCTAssertNil(await cache.surface(for: hiddenID))
        XCTAssertLessThanOrEqual(await cache.totalBytes, 100)
    }

    func testRapidResizeSerializesRenderingAndPublishesLatestSurface() async throws {
        let renderer = GatedPinRenderer()
        let viewModel = makeViewModel(renderer: renderer)

        async let first: Void = viewModel.loadSurface(
            panelSize: CGSize(width: 300, height: 200), backingScale: 2
        )
        async let second: Void = viewModel.loadSurface(
            panelSize: CGSize(width: 600, height: 400), backingScale: 2
        )
        await renderer.releaseAll()
        _ = try await (first, second)

        XCTAssertEqual(renderer.maximumConcurrentCount, 1)
        XCTAssertEqual(await viewModel.surface?.logicalSize, CGSize(width: 600, height: 400))
    }
}
```

- [ ] **Step 2: Run RED**

Run focused `PinRenderingTests`. Expected: missing rendering and cache types.

- [ ] **Step 3: Implement the bounded actor cache**

```swift
enum PinSurfacePriority: Int, Sendable {
    case collapsed = 0
    case hidden = 1
    case visible = 2
}

struct PinSurface: @unchecked Sendable {
    let image: CGImage
    let logicalSize: CGSize
    let byteCost: Int
}

actor PinSurfaceCache {
    let byteLimit: Int
    private(set) var totalBytes = 0

    init(byteLimit: Int = 256 * 1_024 * 1_024)
    func surface(for pinID: UUID) -> PinSurface?
    func insert(_ surface: PinSurface, for pinID: UUID, priority: PinSurfacePriority)
    func updatePriority(_ priority: PinSurfacePriority, for pinID: UUID)
    func remove(pinID: UUID)
    func handleMemoryPressure()
}
```

Evict the least-recently-used entry from the lowest priority first. A surface
larger than the entire budget is returned to its caller but not cached.

- [ ] **Step 4: Implement serialized, crop-aware rendering**

```swift
struct PinRenderRequest: Sendable {
    let capture: CapturedImage
    let document: AnnotationDocument
    let pixelSize: CGSize
    let appliesCrop: Bool
}

protocol PinRendering: Sendable {
    func render(_ request: PinRenderRequest) async throws -> PinSurface
}

protocol PinLibraryServing: Sendable {
    func record(id: UUID) async throws -> CaptureRecord?
    func loadCapture(id: UUID) async throws -> CapturedImage
    func loadAnnotations(id: UUID) async throws -> AnnotationDocument
    func originalURL(id: UUID) async throws -> URL
}
```

`PinViewModel` must serialize and coalesce render requests like the existing
`AnnotationPreviewService`, always set `appliesCrop` to true, and calculate
pixel size from panel points times backing scale with a 4,096-pixel cap. It
must invalidate on persisted image or annotation changes, but not tag or OCR
changes.

- [ ] **Step 5: Add copy, OCR, and link action tests**

Verify that **Copy Image** uses the composited full-resolution snapshot through
the existing export coordinator, **Copy OCR Text** uses stored OCR without a
new recognition request, and detected `http` or `https` links require an
explicit user action before `NSWorkspace` opens them.

- [ ] **Step 6: Run GREEN and commit**

```bash
git add TakeAShot/PinSurfaceCache.swift TakeAShot/PinViewModel.swift \
  TakeAShotTests/PinRenderingTests.swift TakeAShot.xcodeproj/project.pbxproj
git commit -m "feat: render bounded smart pin surfaces"
```

---

### Task 4: Coordinate pin identity, restoration, and window state

**Files:**

- Create: `TakeAShot/PinCoordinator.swift`
- Create: `TakeAShotTests/PinCoordinatorTests.swift`
- Modify: `TakeAShot/PinStore.swift`
- Modify: `TakeAShot/PinWindowCoordinator.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: Tasks 1 through 3.
- Produces: `@MainActor PinCoordinator`, `PinVisibilitySnapshot`,
  `PinDeletionReservation`, and a pin-change stream.

- [ ] **Step 1: Write lifecycle and restoration RED tests**

```swift
@MainActor
final class PinCoordinatorTests: XCTestCase {
    func testPinningSameCaptureFocusesExistingPin() async throws {
        let windows = RecordingPinWindowCoordinator()
        let coordinator = makeCoordinator(windows: windows)
        let captureID = UUID()

        let first = try await coordinator.pin(captureID: captureID)
        let second = try await coordinator.pin(captureID: captureID)

        XCTAssertEqual(first, second)
        XCTAssertEqual(windows.opened.count, 1)
        XCTAssertEqual(windows.focused, [first])
    }

    func testRestoreOpensOnlyPersistentImagePins() async throws {
        let persistent = PinnedReference.fixture(
            captureID: UUID(), restoresAfterRelaunch: true
        )
        let transient = PinnedReference.fixture(
            captureID: UUID(), restoresAfterRelaunch: false
        )
        let store = StubPinStore(pins: [persistent, transient])
        let library = StubPinLibrary(records: [
            .image(id: persistent.captureID),
            .image(id: transient.captureID)
        ])
        let coordinator = makeCoordinator(store: store, library: library)

        try await coordinator.restorePersistentPins()

        XCTAssertEqual(coordinator.activePinIDs, [persistent.id])
    }

    func testMissingCaptureProducesPlaceholderWithoutClosingPin() async throws {
        let pin = PinnedReference.fixture(
            captureID: UUID(), restoresAfterRelaunch: true
        )
        let coordinator = makeCoordinator(
            store: StubPinStore(pins: [pin]),
            library: StubPinLibrary(records: [])
        )

        try await coordinator.restorePersistentPins()

        XCTAssertEqual(coordinator.state(for: pin.id), .missingSource(pin.captureID))
    }

    func testHideAndShowAllRestoresOnlyPreviouslyVisiblePins() async throws {
        let coordinator = makeCoordinatorWithThreePins()
        let hiddenBeforeAction = coordinator.pins[1].id
        try await coordinator.setVisible(false, pinID: hiddenBeforeAction)

        let snapshot = try await coordinator.hideAll()
        try await coordinator.close(pinID: coordinator.pins[2].id)
        try await coordinator.showAll(from: snapshot)

        XCTAssertEqual(coordinator.visiblePinIDs, [coordinator.pins[0].id])
    }
}
```

- [ ] **Step 2: Run RED**

Run focused `PinCoordinatorTests`. Expected: `PinCoordinator` is undefined.

- [ ] **Step 3: Implement the coordinator**

```swift
@MainActor
final class PinCoordinator: ObservableObject {
    @Published private(set) var pins: [PinnedReference] = []
    @Published private(set) var presentedError: PresentedError?

    var activePinIDs: Set<UUID> { Set(pins.map(\.id)) }

    func pin(captureID: UUID) async throws -> UUID
    func focus(pinID: UUID)
    func close(pinID: UUID) async throws
    func setPersistent(_ persistent: Bool, pinID: UUID) async throws
    func updateLayout(_ update: PinLayoutUpdate, pinID: UUID)
    func restorePersistentPins() async throws
    func flush() async throws
    func activeWindowIDs() -> Set<CGWindowID>
}
```

`pin(captureID:)` must reject video and GIF records, flush active annotations
through an injected closure before pinning the active capture, and focus the
existing panel for duplicate captures. It persists the record only after panel
creation succeeds. Closing removes transient metadata immediately; closing a
persistent pin updates its restoration state before closing the panel.

- [ ] **Step 4: Add change invalidation and memory-pressure tests**

Introduce a typed library change stream:

```swift
enum CaptureLibraryChange: Equatable, Sendable {
    case imageOrAnnotationsChanged(UUID)
    case metadataChanged(UUID)
    case deleted(UUID)
}
```

Extend `AppLibraryServing` and `CaptureLibraryStore` with an
`AsyncStream<CaptureLibraryChange>`. Persist/save-annotation/delete operations
emit only after their transaction publishes. Assert that image changes
invalidate a pin render, metadata changes update OCR actions without a render,
and deletion transitions the panel to `.missingSource` until coordinated
deletion closes it.

- [ ] **Step 5: Run GREEN and commit**

```bash
git add TakeAShot/PinCoordinator.swift TakeAShot/PinStore.swift \
  TakeAShot/PinWindowCoordinator.swift TakeAShot/CaptureLibrary.swift \
  TakeAShot/Models.swift TakeAShotTests/PinCoordinatorTests.swift \
  TakeAShot.xcodeproj/project.pbxproj
git commit -m "feat: coordinate smart pin lifecycle"
```

---

### Task 5: Isolate pins from capture and recording

**Files:**

- Create: `TakeAShot/CaptureVisibilityLease.swift`
- Create: `TakeAShotTests/CaptureVisibilityLeaseTests.swift`
- Modify: `TakeAShot/CaptureController.swift`
- Modify: `TakeAShot/ScreenCaptureEngine.swift`
- Modify: `TakeAShot/RecordingEngine.swift`
- Modify: `TakeAShot/Models.swift`
- Modify: `TakeAShotTests/ScreenCaptureTests.swift`
- Modify: `TakeAShotTests/RecordingStateTests.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: `PinCoordinator.activeWindowIDs()` and exact pin visibility state.
- Produces: `CaptureVisibilityLeasing`, `CaptureVisibilityLease`, explicit
  excluded-window request fields, and recording lease ownership.

- [ ] **Step 1: Write nested lease RED tests**

```swift
@MainActor
final class CaptureVisibilityLeaseTests: XCTestCase {
    func testNestedLeasesRestoreExactOriginalVisibleSet() async throws {
        let pins = RecordingPinVisibilityController(
            visible: [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!]
        )
        let coordinator = CaptureVisibilityLeaseCoordinator(pins: pins)

        let first = try await coordinator.acquire()
        let second = try await coordinator.acquire()
        await first.release()
        XCTAssertTrue(pins.currentlyHidden)
        await second.release()

        XCTAssertEqual(pins.restoredSets, [pins.initialVisibleSet])
    }

    func testClosingPinWhileHiddenPreventsRestoration() async throws {
        let pins = RecordingPinVisibilityController.withTwoVisiblePins()
        let coordinator = CaptureVisibilityLeaseCoordinator(pins: pins)
        let lease = try await coordinator.acquire()
        let closed = pins.initialVisibleSet.first!
        pins.close(pinID: closed)

        await lease.release()

        XCTAssertFalse(pins.lastRestoredSet.contains(closed))
    }

    func testHideFailurePreventsLeaseAndCapture() async throws {
        let pins = RecordingPinVisibilityController(failingHideAtIndex: 1)
        let coordinator = CaptureVisibilityLeaseCoordinator(pins: pins)

        await XCTAssertThrowsErrorAsync { try await coordinator.acquire() }

        XCTAssertEqual(pins.captureStartCount, 0)
    }
}
```

- [ ] **Step 2: Run RED**

Run focused lease tests. Expected: missing lease types.

- [ ] **Step 3: Implement exact, reference-counted leases**

```swift
protocol CaptureVisibilityLeasing: Sendable {
    func acquire() async throws -> CaptureVisibilityLease
}

struct CaptureVisibilityLease: Sendable {
    let id: UUID
    private let releaseAction: @Sendable (UUID) async -> Void

    func release() async { await releaseAction(id) }
}

actor CaptureVisibilityLeaseCoordinator: CaptureVisibilityLeasing {
    func acquire() async throws -> CaptureVisibilityLease
    private func release(id: UUID) async
}
```

The first acquire snapshots the exact visible set and awaits every panel hide
acknowledgement. Later acquires increment ownership without replacing the
snapshot. Final release intersects the original set with currently active pins
before restoring. Release must be idempotent by lease UUID.

- [ ] **Step 4: Add explicit pin window exclusions to still capture**

Extend capture requests:

```swift
struct ScreenCaptureDisplayRequest: Sendable {
    let displayID: CGDirectDisplayID
    let ownBundleID: String
    let excludedWindowIDs: Set<CGWindowID>
    let includeDesktopWindows: Bool
    let includeCursor: Bool
}
```

Update `DisplayCaptureFilterPlan` and ScreenCaptureKit provider tests to prove
every active pin window ID is excluded. Area overlay and scrolling paths must
acquire a visibility lease before showing their picker/overlay and retain it
through persistence or cleanup. A failed lease stops capture visibly.

- [ ] **Step 5: Hold a lease through recording cleanup**

In `AppState.startRecording`, acquire the lease after target selection but
before `recording.start`. Store it with the operation generation. Release it
only after stop/cancel/asynchronous failure has passed
`recording.waitForCleanup()`. Add excluded pin window IDs to each
`SCContentFilter` in MP4 and GIF session setup.

Extend the existing request without changing format-specific audio rules:

```swift
struct RecordingRequest: Equatable, Sendable {
    let target: RecordingTarget
    let format: RecordingFormat
    let includesSystemAudio: Bool
    let includesMicrophone: Bool
    let framesPerSecond: Int
    let excludedWindowIDs: Set<CGWindowID>
}
```

Write tests that gate `waitForCleanup`, press Stop, and assert pins remain
hidden until the gate releases. Add cancel, start failure, writer failure, and
microphone-fallback cases.

- [ ] **Step 6: Run focused and cross-feature GREEN tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project TakeAShot.xcodeproj -scheme TakeAShot \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/take-a-shot-pin-isolation-green \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:TakeAShotTests/CaptureVisibilityLeaseTests \
  -only-testing:TakeAShotTests/ScreenCaptureTests \
  -only-testing:TakeAShotTests/RecordingStateTests
```

Expected: all three suites pass with no leaked panels or leases.

- [ ] **Step 7: Commit**

```bash
git add TakeAShot/CaptureVisibilityLease.swift \
  TakeAShot/CaptureController.swift TakeAShot/ScreenCaptureEngine.swift \
  TakeAShot/RecordingEngine.swift TakeAShot/Models.swift \
  TakeAShotTests/CaptureVisibilityLeaseTests.swift \
  TakeAShotTests/ScreenCaptureTests.swift \
  TakeAShotTests/RecordingStateTests.swift \
  TakeAShot.xcodeproj/project.pbxproj
git commit -m "feat: isolate smart pins from capture"
```

---

### Task 6: Coordinate deletion and termination durability

**Files:**

- Modify: `TakeAShot/PinCoordinator.swift`
- Modify: `TakeAShot/PinStore.swift`
- Modify: `TakeAShot/CaptureLibrary.swift`
- Modify: `TakeAShot/Models.swift`
- Modify: `TakeAShot/TakeAShotApp.swift`
- Modify: `TakeAShotTests/PinCoordinatorTests.swift`
- Modify: `TakeAShotTests/AnnotationModelTests.swift`

**Interfaces:**

- Consumes: existing AppState termination and library deletion transactions.
- Produces: `PinDeletionReservation`, coordinated delete choices, and durable
  termination flush.

- [ ] **Step 1: Write coordinated deletion RED tests**

```swift
func testDeletePinnedCaptureRemovesPinMetadataBeforeLibraryAssets() async throws {
    let events = EventRecorder<String>()
    let coordinator = makeCoordinator(events: events)
    let captureID = try await coordinator.pinFixtureCapture()

    try await coordinator.deleteCapture(
        captureID,
        decision: .closePinsAndDelete
    )

    XCTAssertEqual(await events.values, [
        "pin-metadata-published-without-capture",
        "library-delete-started",
        "library-delete-finished",
        "pin-panels-closed"
    ])
}

func testLibraryDeleteFailureRestoresPinMetadata() async throws {
    let store = RecordingPinStore()
    let library = FailingPinLibraryDelete()
    let coordinator = makeCoordinator(store: store, library: library)
    let pin = try await coordinator.pinFixtureCapture()

    await XCTAssertThrowsErrorAsync {
        try await coordinator.deleteCapture(pin.captureID, decision: .closePinsAndDelete)
    }

    XCTAssertEqual(try await store.load(), [pin])
    XCTAssertTrue(coordinator.activePinIDs.contains(pin.id))
}
```

- [ ] **Step 2: Run RED**

Expected: no coordinated deletion API exists.

- [ ] **Step 3: Implement reversible pin deletion reservation**

```swift
enum PinnedCaptureDeleteDecision: Equatable, Sendable {
    case closePinsAndDelete
    case keepCapture
    case exportCopyFirst(ExportFormat, URL)
}

struct PinDeletionReservation: Sendable {
    let captureID: UUID
    let removedPins: [PinnedReference]
}

extension PinCoordinator {
    func deleteCapture(
        _ captureID: UUID,
        decision: PinnedCaptureDeleteDecision
    ) async throws
}
```

For **Close Pins and Delete**, publish pin metadata without associated pins,
then call the library's existing transactional delete. If library deletion
fails, restore and publish the prior pin metadata before rethrowing. If restore
also fails, throw a typed error containing both causes and keep panels open.
Close panels only after library deletion commits.

For **Export Copy First**, render and export the full composited image, then
return to the decision flow without deleting automatically.

- [ ] **Step 4: Write termination ordering and veto RED tests**

```swift
func testTerminationFlushesPinsAfterOperationsAnnotationsAndTags() async throws {
    let events = EventRecorder<String>()
    let state = makeAppStateForTermination(events: events)

    try await state.prepareForTermination()

    XCTAssertEqual(await events.values, [
        "capture-cleanup",
        "recording-cleanup",
        "annotation-flush",
        "tag-flush",
        "pin-frame-snapshot",
        "pin-store-flush"
    ])
}

func testPinPersistenceFailureVetoesTermination() async throws {
    let state = makeAppStateWithFailingPinFlush()

    await XCTAssertThrowsErrorAsync { try await state.prepareForTermination() }

    XCTAssertEqual(state.presentedError?.title, "Could Not Quit Safely")
}
```

- [ ] **Step 5: Extend the single termination gate**

Inject `PinCoordinator` into `AppState`. After capture/recording cleanup and
annotation/tag flush, call `pinCoordinator.snapshotWindowState()` and
`pinCoordinator.flush()`. Do not add another app delegate termination gate.
Failure must propagate through `ApplicationTerminationCoordinator` so AppKit
receives `reply(false)`.

The final termination snapshot must contain only records whose
`restoresAfterRelaunch` value is true. Publish that filtered snapshot before
returning so transient pins cannot reappear after a normal relaunch.

- [ ] **Step 6: Run GREEN and commit**

Run `PinCoordinatorTests` and `AnnotationModelTests`, then:

```bash
git add TakeAShot/PinCoordinator.swift TakeAShot/PinStore.swift \
  TakeAShot/CaptureLibrary.swift TakeAShot/Models.swift \
  TakeAShot/TakeAShotApp.swift TakeAShotTests/PinCoordinatorTests.swift \
  TakeAShotTests/AnnotationModelTests.swift
git commit -m "feat: make smart pin deletion durable"
```

---

### Task 7: Add pin controls, panels, commands, and accessibility

**Files:**

- Create: `TakeAShot/PinViews.swift`
- Modify: `TakeAShot/MacContentView.swift`
- Modify: `TakeAShot/TakeAShotApp.swift`
- Modify: `TakeAShot/Models.swift`
- Modify: `TakeAShotTests/PinWindowCoordinatorTests.swift`
- Modify: `TakeAShotTests/AnnotationModelTests.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: all earlier pin services.
- Produces: visible pin panels, editor/library pin actions, menu commands,
  placeholder UI, and keyboard/VoiceOver behavior.

- [ ] **Step 1: Write static and state-driven UI RED tests**

```swift
func testSmartPinUIExposesTruthfulActionsAndAccessibility() throws {
    let root = repositoryRoot()
    let pinViews = try String(
        contentsOf: root.appendingPathComponent("TakeAShot/PinViews.swift")
    )
    let content = try String(
        contentsOf: root.appendingPathComponent("TakeAShot/MacContentView.swift")
    )

    XCTAssertTrue(content.contains("Pin active capture"))
    XCTAssertTrue(content.contains("Pin library capture"))
    XCTAssertTrue(pinViews.contains("Make All Pins Interactive"))
    XCTAssertTrue(pinViews.contains("Copy recognized text"))
    XCTAssertTrue(pinViews.contains("Missing capture"))
    XCTAssertFalse(pinViews.contains("Button(\"Pin\") {}"))
}
```

Add state tests proving video/GIF records do not expose **Pin**, duplicate pin
actions focus the existing panel, and the deletion dialog offers exactly the
three approved choices.

- [ ] **Step 2: Run RED**

Run `AnnotationModelTests` and `PinWindowCoordinatorTests`. Expected: missing
views and actions.

- [ ] **Step 3: Implement panel content and edge tab**

Create:

```swift
struct PinContentView: View {
    @ObservedObject var viewModel: PinViewModel
    let actions: PinActions

    var body: some View
}

struct PinEdgeTabView: View {
    let thumbnail: CGImage?
    let edge: PinEdge
    let restore: () -> Void
}

struct MissingPinSourceView: View {
    let captureID: UUID
    let locate: () -> Void
    let close: () -> Void
    let removePermanently: () -> Void
}
```

Controls appear on hover or keyboard focus. Add explicit accessibility labels,
values, and help. Respect `accessibilityReduceMotion` and
`accessibilityDifferentiateWithoutColor`. Show opacity as a percentage.

- [ ] **Step 4: Add editor, library, and menu commands**

Add **Pin** beside editor Copy/Export and an image-only **Pin** library action.
Add SwiftUI commands or menu-bar commands for:

- **Pin Active Capture** — Command-Shift-P.
- **Hide All Pins**.
- **Show All Pins**.
- **Close All Pins** with confirmation for persistent pins.
- **Make All Pins Interactive**.

Add a `MenuBarExtra` that displays the active and click-through pin counts and
exposes the same global actions. It must not create a second `PinCoordinator`.

The global recovery shortcut remains Carbon-backed because SwiftUI commands do
not receive keys when another application is active.

While click-through is active, observe the global modifier flags and make only
the pin under the pointer temporarily interactive while **Control-Option** is
held. Releasing either modifier restores click-through. This temporary override
must not change persisted `isClickThrough` state.

- [ ] **Step 5: Add keyboard and VoiceOver tests**

Assert zoom, opacity, collapse, close, and recovery have keyboard actions;
click-through retains menu/global recovery; focus order exposes image, main
controls, then secondary menu; reduced motion removes collapse animation; and
larger accessibility text keeps edge-tab recovery visible. Add a modifier test
that holds **Control-Option**, interacts with one pin, releases the modifiers,
and verifies that only that pin returns to click-through without a metadata
write.

- [ ] **Step 6: Run GREEN and commit**

```bash
git add TakeAShot/PinViews.swift TakeAShot/MacContentView.swift \
  TakeAShot/TakeAShotApp.swift TakeAShot/Models.swift \
  TakeAShotTests/PinWindowCoordinatorTests.swift \
  TakeAShotTests/AnnotationModelTests.swift \
  TakeAShot.xcodeproj/project.pbxproj
git commit -m "feat: add smart pin controls"
```

---

### Task 8: Document and verify Smart Pins end to end

**Files:**

- Modify: `README.md`
- Modify: `TakeAShotTests/AnnotationModelTests.swift`
- Modify: `TakeAShotTests/ScreenCaptureTests.swift`
- Modify: `TakeAShotTests/RecordingStateTests.swift`
- Modify: `TakeAShotTests/PinCoordinatorTests.swift`

**Interfaces:**

- Consumes: the complete feature.
- Produces: user documentation and release evidence.

- [ ] **Step 1: Add end-to-end state tests**

Add a test that uses real `PinStore`, fake panels, real library metadata, and
the live AppState composition seams:

```swift
func testPersistentPinSurvivesRelaunchAndCaptureIsolation() async throws {
    let fixture = try SmartPinIntegrationFixture()
    let capture = try await fixture.persistImageCapture()
    let pinID = try await fixture.firstApp.pin(captureID: capture.id)
    try await fixture.firstApp.setPinPersistent(true, pinID: pinID)
    try await fixture.firstApp.prepareForTermination()

    try await fixture.secondApp.restorePersistentPins()
    let lease = try await fixture.secondApp.acquireCaptureVisibilityLease()

    XCTAssertEqual(fixture.secondPanels.activePinCount, 1)
    XCTAssertTrue(fixture.secondPanels.areAllHidden)
    await lease.release()
    XCTAssertEqual(fixture.secondPanels.visiblePinCount, 1)
}
```

Add end-to-end deletion rollback, missing source, nested capture/recording lease,
click-through recovery, and memory-budget cases.

- [ ] **Step 2: Run focused feature suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project TakeAShot.xcodeproj -scheme TakeAShot \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/take-a-shot-smart-pins-focused \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:TakeAShotTests/PinStoreTests \
  -only-testing:TakeAShotTests/PinWindowCoordinatorTests \
  -only-testing:TakeAShotTests/PinRenderingTests \
  -only-testing:TakeAShotTests/PinCoordinatorTests \
  -only-testing:TakeAShotTests/CaptureVisibilityLeaseTests \
  -only-testing:TakeAShotTests/AnnotationModelTests \
  -only-testing:TakeAShotTests/ScreenCaptureTests \
  -only-testing:TakeAShotTests/RecordingStateTests
```

Expected: every focused suite passes with zero failures and skips.

- [ ] **Step 3: Update README with exact user behavior**

Document creating, manipulating, collapsing, restoring, hiding, and closing
pins; default shortcuts; click-through recovery; persistent restoration;
capture/recording exclusion; memory limits; deletion choices; and v1 limits.
State explicitly that boards, live refresh, videos/GIFs, and cloud sync are not
included.

- [ ] **Step 4: Run full automated verification**

```bash
rm -rf /tmp/take-a-shot-smart-pins-final
VERIFY_DERIVED_DATA=/tmp/take-a-shot-smart-pins-final \
  script/build_and_run.sh --verify

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TakeAShot.xcodeproj -scheme TakeAShot \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/take-a-shot-smart-pins-release \
  CODE_SIGNING_ALLOWED=NO ARCHS='x86_64 arm64' ONLY_ACTIVE_ARCH=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild analyze \
  -project TakeAShot.xcodeproj -scheme TakeAShot \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/take-a-shot-smart-pins-analyze \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `** TEST SUCCEEDED **`, `** BUILD SUCCEEDED **`,
`** ANALYZE SUCCEEDED **`, and `lipo -archs` reports `x86_64 arm64`.

- [ ] **Step 5: Run the manual matrix without overclaiming**

Record actual outcomes for:

- Multiple pins on one display and across two attached displays.
- Display disconnect/reconnect and resolution changes.
- Click-through recovery from another foreground application.
- VoiceOver, keyboard-only use, reduced motion, increased contrast, and larger
  accessibility text.
- Area, display, window, scrolling, MP4, and GIF operations with pins visible.
- Nested capture cancellation and recording failure cleanup.
- Persistent relaunch, corrupted metadata, missing media, and deletion rollback.
- Memory pressure with enough large pins to cross the cache budget.

Mark every unexecuted case as not run. Do not infer a manual outcome from an
automated test.

- [ ] **Step 6: Commit documentation and final test additions**

```bash
git add README.md TakeAShotTests
git commit -m "docs: document smart pins"
git status --short
```

Expected: the worktree is clean except ignored local build artifacts.

---

## Final review gate

After Task 8:

1. Request a whole-feature code review from the Smart Pins base commit through
   the final documentation commit.
2. Fix every Critical and Important finding with a failing regression test.
3. Repeat review until no Critical or Important findings remain.
4. Run fresh full tests, universal Release, analyzer, script syntax, diff, and
   placeholder checks.
5. Use `superpowers:finishing-a-development-branch` to offer merge, PR, keep,
   or discard options. Do not merge or publish without the user's choice.
