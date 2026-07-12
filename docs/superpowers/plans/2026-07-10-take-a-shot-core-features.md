# Take a Shot Core Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a functional local-first macOS screenshot and recording application with modern capture, scrolling capture, annotations, optimized export, OCR history, MP4 recording, and GIF recording while postponing cloud upload.

**Architecture:** Preserve the macOS 14 deployment target and replace the synchronous capture singleton with focused native services. Immutable capture artifacts flow through non-destructive editing, background rendering/export, OCR, and an actor-isolated library; SwiftUI observes only coordinator state.

**Tech Stack:** Swift 5, SwiftUI, AppKit, ScreenCaptureKit, Core Graphics, Core Image, Image I/O, Vision, AVFoundation, XCTest, macOS 14+

## Global Constraints

- Minimum deployment target remains macOS 14.0.
- Use Apple frameworks only; add no third-party dependencies.
- Cloud upload, accounts, public links, and synchronization remain excluded.
- Preserve the current macOS visual direction while replacing placeholder actions with real behavior or disabled “Coming later” controls.
- Original captures are immutable; annotations and crop state remain non-destructive.
- Capture, stitching, rendering, encoding, OCR, thumbnail generation, and persistence must not block `MainActor`.
- Scrolling capture is vertical only and is limited to 100 frames, 30,000 output pixels, and 60 seconds.
- GIF capture is limited to 10 frames per second, a 1280-pixel longest edge, and 60 seconds.
- Every task ends with a buildable, independently testable checkpoint.

## File Map

**Existing files to modify**

- `TakeAShot/Models.swift` — UI-facing `AppState`, capture modes, tool selection, errors, and coordinator bindings.
- `TakeAShot/CaptureController.swift` — hotkey, overlays, thumbnail panel, and capture-mode orchestration only.
- `TakeAShot/MacContentView.swift` — functional capture rail, editor, inspector, library, and recording controls.
- `TakeAShot/CanvasViews.swift` — cached/compound dotted background and reusable canvas geometry.
- `TakeAShot/TakeAShotApp.swift` — app bootstrap and permission-safe service injection.
- `TakeAShot.xcodeproj/project.pbxproj` — source membership, test target, framework links, and privacy usage strings.
- `README.md` — supported workflows, permissions, limitations, and verification commands.
- `.gitignore` — ignore local Codex environment state and generated media.

**New production files**

- `TakeAShot/CaptureModels.swift` — capture records, pixel geometry, annotation models, and recording requests/states.
- `TakeAShot/CaptureGeometry.swift` — pure display/selection coordinate conversion.
- `TakeAShot/ImagePipeline.swift` — annotation renderer, Image I/O export, thumbnails, clipboard-ready rendering.
- `TakeAShot/CaptureLibrary.swift` — actor-isolated file/index persistence and Vision OCR.
- `TakeAShot/ScreenCaptureEngine.swift` — ScreenCaptureKit screenshot and source discovery.
- `TakeAShot/AnnotationEditor.swift` — editor gestures, handles, undo/redo, and preview composition.
- `TakeAShot/ScrollingCapture.swift` — overlap matcher, incremental stitcher, accessibility scrolling, and limits.
- `TakeAShot/RecordingEngine.swift` — SCStream capture, MP4 writing, microphone muxing, and GIF writing.

**New test files**

- `TakeAShotTests/CaptureGeometryTests.swift`
- `TakeAShotTests/TestSupport.swift`
- `TakeAShotTests/AnnotationModelTests.swift`
- `TakeAShotTests/ImagePipelineTests.swift`
- `TakeAShotTests/CaptureLibraryTests.swift`
- `TakeAShotTests/ScrollingCaptureTests.swift`
- `TakeAShotTests/RecordingStateTests.swift`

---

### Task 1: Establish the Prototype Baseline and XCTest Harness

**Files:**
- Modify: `.gitignore`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`
- Create: `TakeAShotTests/CaptureGeometryTests.swift`
- Create: `TakeAShotTests/TestSupport.swift`
- Commit existing prototype files without `.codex/environments/environment.toml`

**Interfaces:**
- Consumes: Existing app target `TakeAShot`.
- Produces: Host-based unit-test target `TakeAShotTests` and a clean source baseline for later diffs.

- [ ] **Step 1: Commit the untouched prototype baseline**

Add `.codex/environments/` to `.gitignore`, then stage only `.gitignore`, `Makefile`, `README.md`, `TakeAShot.xcodeproj`, `TakeAShot`, `design-reference`, `docs/assets`, and `script`.

```bash
git add .gitignore Makefile README.md TakeAShot.xcodeproj TakeAShot design-reference docs/assets script
git diff --cached --check
git commit -m "chore: establish app prototype baseline"
```

Expected: commit succeeds and `git status --short` is clean because `.codex/environments/` is ignored.

- [ ] **Step 2: Add the test target, smoke test, and image helpers**

Create a macOS unit-test bundle target named `TakeAShotTests`, add it to the shared `TakeAShot` scheme, set `TEST_HOST` to `$(BUILT_PRODUCTS_DIR)/TakeAShot.app/Contents/MacOS/TakeAShot`, and create:

```swift
import XCTest
@testable import TakeAShot

final class CaptureGeometryTests: XCTestCase {
    func testHarnessLoadsApplicationModule() {
        XCTAssertEqual(CaptureMode.area.rawValue, "Area")
    }
}

enum TestImage {
    static func solid(width: Int, height: Int, color: NSColor) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestImageError.contextCreation }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestImageError.imageCreation }
        return image
    }
}

enum TestImageError: Error { case contextCreation, imageCreation }

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

extension Optional {
    func unwrapped(file: StaticString = #filePath, line: UInt = #line) throws -> Wrapped {
        try XCTUnwrap(self, file: file, line: line)
    }
}
```

- [ ] **Step 3: Run the smoke test**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project TakeAShot.xcodeproj -scheme TakeAShot \
  -destination 'platform=macOS' -derivedDataPath /tmp/take-a-shot-derived \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `** TEST SUCCEEDED **` with one test.

- [ ] **Step 4: Commit the test harness**

```bash
git add TakeAShot.xcodeproj TakeAShotTests
git commit -m "test: add macOS unit test target"
```

### Task 2: Introduce Capture Models and Coordinate Conversion

**Files:**
- Create: `TakeAShot/CaptureModels.swift`
- Create: `TakeAShot/CaptureGeometry.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`
- Modify: `TakeAShotTests/CaptureGeometryTests.swift`

**Interfaces:**
- Consumes: Core Graphics rectangles and display scale values.
- Produces: `CaptureKind`, `PixelSize`, `DisplayGeometry`, `CaptureOptions`, `CapturedImage`, `CaptureGeometry.sourceRect(selection:display:)`, and `CaptureGeometry.pixelSize(rect:scale:)`.

- [ ] **Step 1: Write failing conversion tests**

```swift
func testSourceRectConvertsAppKitBottomLeftToScreenCaptureTopLeft() {
    let display = DisplayGeometry(
        id: 7,
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        scale: 2
    )
    let selection = CGRect(x: 1540, y: 680, width: 300, height: 200)
    XCTAssertEqual(
        CaptureGeometry.sourceRect(selection: selection, display: display),
        CGRect(x: 100, y: 200, width: 300, height: 200)
    )
}

func testPixelSizeUsesCapturedDisplayScale() {
    XCTAssertEqual(
        CaptureGeometry.pixelSize(rect: CGRect(x: 0, y: 0, width: 300, height: 200), scale: 2),
        PixelSize(width: 600, height: 400)
    )
}
```

- [ ] **Step 2: Verify the tests fail**

Run the Task 1 test command with `-only-testing:TakeAShotTests/CaptureGeometryTests`.

Expected: compilation fails because `DisplayGeometry` and `CaptureGeometry` do not exist.

- [ ] **Step 3: Add the minimal models and conversion**

```swift
enum CaptureKind: String, Codable, Sendable {
    case area, window, display, scrolling, video, gif
}

enum ExportFormat: String, CaseIterable, Sendable { case png, jpeg }

struct PixelSize: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
}

struct DisplayGeometry: Equatable, Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
}

struct CaptureOptions: Equatable, Sendable {
    var showsCursor = true
    var excludesDesktopWindows = false
    var delay: Duration = .zero
}

struct CapturedImage: @unchecked Sendable {
    let id: UUID
    let kind: CaptureKind
    let title: String
    let createdAt: Date
    let image: CGImage
    let pixelSize: PixelSize
}

enum CaptureGeometry {
    static func sourceRect(selection: CGRect, display: DisplayGeometry) -> CGRect {
        CGRect(
            x: selection.minX - display.frame.minX,
            y: display.frame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        ).integral
    }

    static func pixelSize(rect: CGRect, scale: CGFloat) -> PixelSize {
        PixelSize(width: Int((rect.width * scale).rounded()), height: Int((rect.height * scale).rounded()))
    }
}
```

- [ ] **Step 4: Run tests and commit**

Expected: `CaptureGeometryTests` passes.

```bash
git add TakeAShot/CaptureModels.swift TakeAShot/CaptureGeometry.swift TakeAShotTests/CaptureGeometryTests.swift TakeAShot.xcodeproj
git commit -m "feat: add capture models and display geometry"
```

### Task 3: Add Non-Destructive Annotation State and History

**Files:**
- Modify: `TakeAShot/CaptureModels.swift`
- Create: `TakeAShotTests/AnnotationModelTests.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CapturedImage.id` and normalized image geometry.
- Produces: `NormalizedPoint`, `NormalizedRect`, `AnnotationItem`, `AnnotationDocument`, and `AnnotationHistory`.

- [ ] **Step 1: Write failing annotation-history tests**

```swift
func testUndoAndRedoRestoreWholeDocument() {
    let initial = AnnotationDocument(captureID: UUID())
    var history = AnnotationHistory(initial: initial, limit: 50)
    let arrow = AnnotationItem.arrow(.init(
        id: UUID(), start: .init(x: 0.1, y: 0.2), end: .init(x: 0.8, y: 0.7),
        color: .red, strokeWidth: 4
    ))
    history.commit { $0.items.append(arrow) }
    XCTAssertEqual(history.document.items, [arrow])
    history.undo()
    XCTAssertTrue(history.document.items.isEmpty)
    history.redo()
    XCTAssertEqual(history.document.items, [arrow])
}
```

- [ ] **Step 2: Verify failure, then implement the value types**

Use clamped `Double` normalized coordinates, Codable RGBA colors, and enum cases carrying identifiable structs:

```swift
struct NormalizedPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }
}

struct NormalizedRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
        self.width = min(1 - self.x, max(0, width))
        self.height = min(1 - self.y, max(0, height))
    }
}

struct RGBAColor: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    static let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
}

struct ArrowAnnotation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var start: NormalizedPoint
    var end: NormalizedPoint
    var color: RGBAColor
    var strokeWidth: Double
}

struct TextAnnotation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var bounds: NormalizedRect
    var text: String
    var fontSize: Double
    var color: RGBAColor
}

struct RectAnnotation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var rect: NormalizedRect
    var color: RGBAColor
    var amount: Double
}

enum AnnotationItem: Codable, Equatable, Identifiable, Sendable {
    case arrow(ArrowAnnotation)
    case text(TextAnnotation)
    case highlight(RectAnnotation)
    case blur(RectAnnotation)

    var id: UUID {
        switch self {
        case .arrow(let value): value.id
        case .text(let value): value.id
        case .highlight(let value): value.id
        case .blur(let value): value.id
        }
    }
}

struct AnnotationDocument: Codable, Equatable, Sendable {
    let captureID: UUID
    var items: [AnnotationItem] = []
    var cropRect: NormalizedRect? = nil
}

struct AnnotationHistory: Sendable {
    private(set) var document: AnnotationDocument
    private var undoStack: [AnnotationDocument] = []
    private var redoStack: [AnnotationDocument] = []
    let limit: Int

    mutating func commit(_ mutation: (inout AnnotationDocument) -> Void) {
        undoStack.append(document)
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
        mutation(&document)
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
    }
}
```

- [ ] **Step 3: Run model tests and commit**

Expected: all annotation history, Codable round-trip, and coordinate-clamping tests pass.

```bash
git add TakeAShot/CaptureModels.swift TakeAShotTests/AnnotationModelTests.swift TakeAShot.xcodeproj
git commit -m "feat: add non-destructive annotation model"
```

### Task 4: Replace TIFF Export with a Background Image Pipeline

**Files:**
- Create: `TakeAShot/ImagePipeline.swift`
- Create: `TakeAShotTests/ImagePipelineTests.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CGImage` and `AnnotationDocument`.
- Produces: `AnnotationRenderer.render(source:document:)`, `ImageExporter.pngData(for:)`, `jpegData(for:quality:)`, `write(_:to:)`, and `thumbnail(for:maxPixelSize:)`.

- [ ] **Step 1: Write failing exporter and renderer tests**

```swift
func testPNGEncodingPreservesPixelDimensions() throws {
    let source = try TestImage.solid(width: 40, height: 30, color: .white)
    let data = try ImageExporter.pngData(for: source)
    let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
    XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 40)
    XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 30)
}

func testCropChangesRenderedDimensions() throws {
    let source = try TestImage.solid(width: 100, height: 80, color: .white)
    let document = AnnotationDocument(captureID: UUID(), cropRect: .init(x: 0.1, y: 0.25, width: 0.5, height: 0.5))
    let rendered = try AnnotationRenderer().render(source: source, document: document)
    XCTAssertEqual(rendered.width, 50)
    XCTAssertEqual(rendered.height, 40)
}
```

- [ ] **Step 2: Verify failure and implement direct Image I/O encoding**

```swift
enum ImageExporter {
    static func pngData(for image: CGImage) throws -> Data {
        try encode(image, type: UTType.png.identifier as CFString, properties: [:])
    }

    static func jpegData(for image: CGImage, quality: Double) throws -> Data {
        try encode(image, type: UTType.jpeg.identifier as CFString, properties: [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))
        ])
    }

    private static func encode(_ image: CGImage, type: CFString, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw ImagePipelineError.destinationCreation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImagePipelineError.finalization }
        return data as Data
    }
}

enum ImagePipelineError: Error, Equatable {
    case contextCreation
    case destinationCreation
    case finalization
    case cropOutsideImage
}
```

Implement arrow/text/highlight drawing in Core Graphics, region-limited `CIGaussianBlur`, and crop-last rendering. File writes use `Data.write(options: .atomic)` inside `Task.detached` callers.

- [ ] **Step 3: Run image tests and commit**

Expected: PNG, JPEG quality bounds, arrow sample-pixel, blur-region, crop, and thumbnail tests pass.

```bash
git add TakeAShot/ImagePipeline.swift TakeAShotTests/ImagePipelineTests.swift TakeAShot.xcodeproj
git commit -m "feat: add optimized annotation image pipeline"
```

### Task 5: Persist Captures and Add OCR Search

**Files:**
- Create: `TakeAShot/CaptureLibrary.swift`
- Modify: `TakeAShot/CaptureModels.swift`
- Create: `TakeAShotTests/CaptureLibraryTests.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CapturedImage`, `ImageExporter`, and optional `AnnotationDocument`.
- Produces: `CaptureRecord`, `OCRRecognizing`, `VisionOCRService`, and actor `CaptureLibraryStore` with `load()`, `persist(image:)`, `search(_:)`, `updateTags(id:tags:)`, and `delete(id:)`.

- [ ] **Step 1: Write failing persistence and search tests**

```swift
func testPersistReloadSearchAndDelete() async throws {
    let root = temporaryDirectory()
    let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "Quarterly revenue"))
    let image = try TestImage.captured(width: 32, height: 24, kind: .area)
    let record = try await store.persist(image: image)
    XCTAssertEqual(await store.search("revenue").map(\.id), [record.id])

    let reloaded = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))
    XCTAssertEqual(try await reloaded.load().map(\.id), [record.id])
    try await reloaded.delete(id: record.id)
    XCTAssertTrue(try await reloaded.load().isEmpty)
}

private struct StubOCR: OCRRecognizing {
    let text: String
    func recognizeText(in image: CGImage) async throws -> String { text }
}

private extension TestImage {
    static func captured(width: Int, height: Int, kind: CaptureKind) throws -> CapturedImage {
        let image = try solid(width: width, height: height, color: .white)
        return CapturedImage(
            id: UUID(), kind: kind, title: "Test capture", createdAt: .now,
            image: image, pixelSize: .init(width: width, height: height)
        )
    }
}
```

- [ ] **Step 2: Verify failure and implement atomic storage**

```swift
protocol OCRRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> String
}

struct VisionOCRService: OCRRecognizing {
    func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { return continuation.resume(throwing: error) }
                let text = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n") ?? ""
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            DispatchQueue.global(qos: .utility).async {
                do { try VNImageRequestHandler(cgImage: image).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

actor CaptureLibraryStore {
    init(rootURL: URL, ocr: any OCRRecognizing)
    func load() throws -> [CaptureRecord]
    func persist(image: CapturedImage, annotations: AnnotationDocument? = nil) async throws -> CaptureRecord
    func search(_ query: String) -> [CaptureRecord]
    func updateTags(id: UUID, tags: [String]) throws
    func delete(id: UUID) throws
}

struct CaptureRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: CaptureKind
    let title: String
    let createdAt: Date
    var lastEditedAt: Date
    let pixelSize: PixelSize
    var duration: TimeInterval?
    let originalFilename: String
    var editedFilename: String?
    let thumbnailFilename: String
    var annotationFilename: String?
    var ocrText: String
    var tags: [String]
}
```

Create `originals`, `exports`, `thumbnails`, `annotations`, and `temporary` lazily. Write `index.json.tmp`, replace `index.json` atomically, store only relative filenames, and tolerate missing owned files by excluding only the corrupt record. `VisionOCRService` uses `VNRecognizeTextRequest` with `.accurate` recognition.

- [ ] **Step 3: Run library tests and commit**

Expected: persistence, atomic reload, OCR search, tag search, deletion, and corrupt-record recovery tests pass.

```bash
git add TakeAShot/CaptureLibrary.swift TakeAShot/CaptureModels.swift TakeAShotTests/CaptureLibraryTests.swift TakeAShot.xcodeproj
git commit -m "feat: add local OCR capture library"
```

### Task 6: Migrate Screenshot Capture to ScreenCaptureKit

**Files:**
- Create: `TakeAShot/ScreenCaptureEngine.swift`
- Modify: `TakeAShot/CaptureController.swift`
- Modify: `TakeAShot/Models.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CaptureOptions`, `DisplayGeometry`, area selection, `SCDisplay`, and `SCWindow` identifiers.
- Produces: `CaptureSource`, `ScreenshotCapturing`, `ScreenCaptureEngine.sources()`, `captureArea`, `captureDisplay`, and `captureWindow`.

- [ ] **Step 1: Add failing intent-dispatch tests**

Add a pure intent mapper so the controller cannot silently collapse modes:

```swift
func testEveryCaptureModeHasADistinctIntent() {
    XCTAssertEqual(CaptureIntent(mode: .area), .areaSelection)
    XCTAssertEqual(CaptureIntent(mode: .window), .windowPicker)
    XCTAssertEqual(CaptureIntent(mode: .fullScreen), .display)
    XCTAssertEqual(CaptureIntent(mode: .scrolling), .scrollingWindowPicker)
    XCTAssertEqual(CaptureIntent(mode: .record), .recordingPicker)
}
```

The test must fail because `CaptureIntent` does not exist and the current switch routes multiple modes to selection capture.

- [ ] **Step 2: Implement ScreenCaptureKit source discovery and screenshots**

```swift
protocol ScreenshotCapturing: Sendable {
    func sources() async throws -> CaptureSources
    func captureArea(_ rect: CGRect, display: DisplayGeometry, options: CaptureOptions) async throws -> CapturedImage
    func captureDisplay(_ displayID: CGDirectDisplayID, options: CaptureOptions) async throws -> CapturedImage
    func captureWindow(_ windowID: CGWindowID, options: CaptureOptions) async throws -> CapturedImage
}

struct CaptureSource: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case display(DisplayGeometry), window(CGWindowID, CGRect) }
    let id: String
    let title: String
    let kind: Kind
}

struct CaptureSources: Equatable, Sendable {
    let displays: [CaptureSource]
    let windows: [CaptureSource]
}

enum CaptureError: LocalizedError, Equatable {
    case permissionDenied
    case sourceUnavailable
    case invalidSelection
    case captureFailed(String)
}

final class ScreenCaptureEngine: ScreenshotCapturing, @unchecked Sendable {
    func captureWindow(_ windowID: CGWindowID, options: CaptureOptions) async throws -> CapturedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(options.excludesDesktopWindows, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.sourceUnavailable }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = options.showsCursor
        configuration.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        configuration.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CapturedImage(id: UUID(), kind: .window, title: window.title ?? "Window capture", createdAt: .now, image: image, pixelSize: .init(width: image.width, height: image.height))
    }
}

enum CaptureIntent: Equatable {
    case areaSelection, windowPicker, display, scrollingWindowPicker, recordingPicker

    init(mode: CaptureMode) {
        switch mode {
        case .area: self = .areaSelection
        case .window: self = .windowPicker
        case .fullScreen: self = .display
        case .scrolling: self = .scrollingWindowPicker
        case .record: self = .recordingPicker
        }
    }
}
```

Area and display methods select the matching `SCDisplay`, set `sourceRect`, calculate width and height from the captured display scale, and never call `CGMainDisplayID()`.

- [ ] **Step 3: Refactor overlays and coordinator**

Create an overlay per `NSScreen`, return a global selection plus display ID, cancel sibling overlays when one completes, make delay cancellable with `Task.sleep(for:)`, and publish success only after library persistence succeeds.

- [ ] **Step 4: Run tests, build, and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project TakeAShot.xcodeproj -scheme TakeAShot -destination 'platform=macOS' -derivedDataPath /tmp/take-a-shot-derived CODE_SIGNING_ALLOWED=NO
git add TakeAShot/ScreenCaptureEngine.swift TakeAShot/CaptureController.swift TakeAShot/Models.swift TakeAShot.xcodeproj TakeAShotTests
git commit -m "feat: migrate screenshots to ScreenCaptureKit"
```

### Task 7: Build the Functional Annotation Editor

**Files:**
- Create: `TakeAShot/AnnotationEditor.swift`
- Modify: `TakeAShot/MacContentView.swift`
- Modify: `TakeAShot/CanvasViews.swift`
- Modify: `TakeAShot/Models.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `AnnotationDocument`, `AnnotationHistory`, `AnnotationRenderer`, active `CapturedImage`, and `AnnotationTool`.
- Produces: `AnnotationEditor`, `CanvasTransform`, functional undo/redo, tool styling, selection, move/resize, and export bindings.

- [ ] **Step 1: Add failing canvas-transform tests**

```swift
func testAspectFitTransformMapsLetterboxedPointIntoImageSpace() {
    let transform = CanvasTransform(canvasSize: .init(width: 1000, height: 800), imageSize: .init(width: 1000, height: 500), zoom: 1)
    XCTAssertEqual(transform.normalizedPoint(from: CGPoint(x: 500, y: 400)), .init(x: 0.5, y: 0.5))
    XCTAssertNil(transform.normalizedPoint(from: CGPoint(x: 500, y: 50)))
}

struct CanvasTransform {
    let imageRect: CGRect

    init(canvasSize: CGSize, imageSize: CGSize, zoom: CGFloat) {
        let scale = min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height) * zoom
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        imageRect = CGRect(
            x: (canvasSize.width - size.width) / 2,
            y: (canvasSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func normalizedPoint(from point: CGPoint) -> NormalizedPoint? {
        guard imageRect.contains(point) else { return nil }
        return NormalizedPoint(
            x: Double((point.x - imageRect.minX) / imageRect.width),
            y: Double((point.y - imageRect.minY) / imageRect.height)
        )
    }
}
```

- [ ] **Step 2: Implement gesture-to-document editing**

`AnnotationEditor` uses one drag gesture and switches by tool:

```swift
switch selectedTool {
case .arrow: history.commit { $0.items.append(.arrow(makeArrow(from: start, to: end))) }
case .highlight: history.commit { $0.items.append(.highlight(makeHighlight(from: start, to: end))) }
case .blur: history.commit { $0.items.append(.blur(makeBlur(from: start, to: end))) }
case .crop: history.commit { $0.cropRect = NormalizedRect(containing: start, end) }
case .text: pendingTextAnchor = start
}
```

Render editable SwiftUI overlays from normalized coordinates, provide inline `TextField` placement, selection handles, delete, keyboard undo/redo, and a zoom range of 25–400 percent.

- [ ] **Step 3: Optimize the dotted background**

Build one `Path` containing every ellipse inside the `Canvas` closure, then call `context.fill(path, with:)` once. Do not allocate and fill one path per dot.

- [ ] **Step 4: Run tests, build, and commit**

Expected: annotation model/image tests pass and the editor compiles with functional toolbar bindings.

```bash
git add TakeAShot/AnnotationEditor.swift TakeAShot/MacContentView.swift TakeAShot/CanvasViews.swift TakeAShot/Models.swift TakeAShot.xcodeproj TakeAShotTests
git commit -m "feat: add non-destructive annotation editor"
```

### Task 8: Implement Frame Overlap and Scrolling Capture

**Files:**
- Create: `TakeAShot/ScrollingCapture.swift`
- Create: `TakeAShotTests/ScrollingCaptureTests.swift`
- Modify: `TakeAShot/CaptureController.swift`
- Modify: `TakeAShot/Models.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: selected window source, `ScreenshotCapturing`, Accessibility trust, and captured frames.
- Produces: `FrameStitcher.match(previous:next:)`, `IncrementalImageStitcher.append`, `WindowScrolling`, and `ScrollingCaptureEngine.capture(windowID:progress:)`.

- [ ] **Step 1: Write failing synthetic overlap tests**

```swift
func testFindsOverlapAndAppendsOnlyNovelRows() throws {
    let document = try TestImage.verticalBands(rowCount: 900, width: 80)
    let first = try document.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 500)).unwrapped()
    let second = try document.cropping(to: CGRect(x: 0, y: 300, width: 80, height: 500)).unwrapped()
    let match = try FrameStitcher().match(previous: first, next: second)
    XCTAssertEqual(match.overlapRows, 200, accuracy: 2)
    XCTAssertGreaterThan(match.confidence, 0.9)
}

func testRepeatedFrameStopsWithoutAddingRows() throws {
    let frame = try TestImage.verticalBands(rowCount: 500, width: 80)
    XCTAssertEqual(try FrameStitcher().match(previous: frame, next: frame).novelRows, 0)
}

private extension TestImage {
    static func verticalBands(rowCount: Int, width: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: rowCount, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestImageError.contextCreation }
        for row in 0..<rowCount {
            let value = CGFloat(row % 251) / 250
            context.setFillColor(NSColor(calibratedRed: value, green: 1 - value, blue: CGFloat((row * 17) % 251) / 250, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }
        guard let image = context.makeImage() else { throw TestImageError.imageCreation }
        return image
    }
}

struct OverlapMatch: Equatable, Sendable {
    let overlapRows: Int
    let novelRows: Int
    let confidence: Double
}

enum ScrollingCaptureError: LocalizedError, Equatable {
    case accessibilityDenied
    case eventCreation
    case lowConfidence
    case pixelLimit
    case frameLimit
    case durationLimit
    case cancelled
}
```

- [ ] **Step 2: Implement downsampled luminance matching**

Compare row signatures across candidate overlaps, discard stable top/bottom chrome, return the largest candidate above `0.92` confidence, and throw `ScrollingCaptureError.lowConfidence` otherwise. `IncrementalImageStitcher` writes accepted novel strips into a bitmap context bounded by the global pixel limit.

- [ ] **Step 3: Implement controlled window scrolling**

```swift
protocol WindowScrolling: Sendable {
    func isTrusted(prompt: Bool) -> Bool
    func scroll(windowFrame: CGRect, deltaY: Int) throws
}

struct AccessibilityWindowScroller: WindowScrolling {
    func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
    }

    func scroll(windowFrame: CGRect, deltaY: Int) throws {
        let point = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(deltaY), wheel2: 0, wheel3: 0) else { throw ScrollingCaptureError.eventCreation }
        event.location = point
        event.post(tap: .cghidEventTap)
    }
}
```

Stop on repeated content, user cancellation, 100 frames, 30,000 pixels, or 60 seconds. Return an explicit partial-result state; never silently save it.

- [ ] **Step 4: Run scrolling tests, build, and commit**

```bash
git add TakeAShot/ScrollingCapture.swift TakeAShotTests/ScrollingCaptureTests.swift TakeAShot/CaptureController.swift TakeAShot/Models.swift TakeAShot.xcodeproj
git commit -m "feat: add automatic scrolling capture"
```

### Task 9: Implement MP4 Recording and Its State Machine

**Files:**
- Create: `TakeAShot/RecordingEngine.swift`
- Create: `TakeAShotTests/RecordingStateTests.swift`
- Modify: `TakeAShot/CaptureModels.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `SCDisplay` or `SCWindow`, `SCStream` sample buffers, system-audio and microphone choices.
- Produces: `RecordingRequest`, `RecordingState`, `RecordingSession`, and `RecordingEngine.start(request:)`, `stop()`, and `cancel()`.

- [ ] **Step 1: Write failing state-transition tests**

```swift
func testSuccessfulRecordingTransitionsAndPublishesOutput() async throws {
    let session = RecordingSessionSpy()
    let engine = RecordingEngine(sessionFactory: { _ in session })
    try await engine.start(request: .testMP4)
    guard case .recording = await engine.state else { return XCTFail("expected recording state") }
    let output = try await engine.stop()
    XCTAssertEqual(output, await session.outputURL)
    XCTAssertEqual(await engine.state, .completed(output))
}

func testCancellationRemovesTemporaryOutput() async throws {
    let session = RecordingSessionSpy()
    let engine = RecordingEngine(sessionFactory: { _ in session })
    try await engine.start(request: .testMP4)
    await engine.cancel()
    XCTAssertTrue(await session.removedTemporaryOutput)
    XCTAssertEqual(await engine.state, .idle)
}

private extension RecordingRequest {
    static let testMP4 = RecordingRequest(
        target: .display(1), format: .mp4, includesSystemAudio: false,
        includesMicrophone: false, framesPerSecond: 30
    )
}

private actor RecordingSessionSpy: RecordingSession {
    let outputURL = URL(fileURLWithPath: "/tmp/test-recording.mp4")
    private(set) var removedTemporaryOutput = false
    func start() async throws {}
    func stop() async throws -> URL { outputURL }
    func cancel() async { removedTemporaryOutput = true }
}
```

- [ ] **Step 2: Implement the actor-isolated state machine and writer**

```swift
enum RecordingState: Equatable, Sendable {
    case idle, preparing, recording(startedAt: Date), stopping, completed(URL), failed(String)
}

enum RecordingFormat: Equatable, Sendable { case mp4, gif }
enum RecordingTarget: Equatable, Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

struct RecordingRequest: Equatable, Sendable {
    let target: RecordingTarget
    let format: RecordingFormat
    let includesSystemAudio: Bool
    let includesMicrophone: Bool
    let framesPerSecond: Int
}

protocol RecordingSession: Sendable {
    var outputURL: URL { get async }
    func start() async throws
    func stop() async throws -> URL
    func cancel() async
}

actor RecordingEngine {
    private(set) var state: RecordingState = .idle
    init(sessionFactory: @escaping @Sendable (RecordingRequest) throws -> any RecordingSession)
    func start(request: RecordingRequest) async throws
    func stop() async throws -> URL
    func cancel() async
}
```

The SCStream delegate forwards screen and system-audio buffers to a serial media queue. `AVAssetWriter` uses H.264 at up to 30 fps and AAC audio. Optional microphone capture uses `AVCaptureSession`; samples are retimed to the common host clock before appending. Temporary output is moved atomically only after `finishWriting` completes.

- [ ] **Step 3: Add usage strings and run tests**

Set generated Info.plist values for Screen Recording guidance and `NSMicrophoneUsageDescription`. Verify denial produces `.failed` or a user-approved no-microphone fallback.

- [ ] **Step 4: Build, test, and commit**

```bash
git add TakeAShot/RecordingEngine.swift TakeAShot/CaptureModels.swift TakeAShotTests/RecordingStateTests.swift TakeAShot.xcodeproj
git commit -m "feat: add ScreenCaptureKit MP4 recording"
```

### Task 10: Add Incremental GIF Recording

**Files:**
- Modify: `TakeAShot/RecordingEngine.swift`
- Modify: `TakeAShotTests/RecordingStateTests.swift`

**Interfaces:**
- Consumes: screen sample buffers from `RecordingEngine`.
- Produces: `GIFWriter.append(image:presentationTime:)` and `finish()` with enforced FPS, resolution, and duration limits.

- [ ] **Step 1: Write failing GIF metadata and limit tests**

```swift
func testGIFWriterStoresFrameDelayAndLoopCount() throws {
    let url = temporaryDirectory().appendingPathComponent("capture.gif")
    var writer = try GIFWriter(url: url, maxFPS: 10, maxPixelSize: 1280, maxDuration: 60)
    try writer.append(image: TestImage.solid(width: 20, height: 20, color: .red), presentationTime: .zero)
    try writer.append(image: TestImage.solid(width: 20, height: 20, color: .blue), presentationTime: CMTime(seconds: 0.1, preferredTimescale: 600))
    try writer.finish()
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetCount(source), 2)
}

func testGIFWriterDropsFramesAboveMaximumFPS() throws {
    let url = temporaryDirectory().appendingPathComponent("limited.gif")
    var writer = try GIFWriter(url: url, maxFPS: 10, maxPixelSize: 1280, maxDuration: 60)
    let frame = try TestImage.solid(width: 20, height: 20, color: .red)
    try writer.append(image: frame, presentationTime: .zero)
    try writer.append(image: frame, presentationTime: CMTime(seconds: 0.02, preferredTimescale: 600))
    try writer.append(image: frame, presentationTime: CMTime(seconds: 0.10, preferredTimescale: 600))
    try writer.finish()
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    XCTAssertEqual(CGImageSourceGetCount(source), 2)
}
```

- [ ] **Step 2: Implement bounded incremental Image I/O output**

Create `CGImageDestination` once, downsample each accepted frame before appending, set loop count to zero, use `kCGImagePropertyGIFUnclampedDelayTime`, reject frames after 60 seconds, and never retain prior full-resolution frames.

```swift
struct GIFWriter {
    init(url: URL, maxFPS: Int, maxPixelSize: Int, maxDuration: TimeInterval) throws
    mutating func append(image: CGImage, presentationTime: CMTime) throws
    mutating func finish() throws
}
```

- [ ] **Step 3: Run recording tests and commit**

```bash
git add TakeAShot/RecordingEngine.swift TakeAShotTests/RecordingStateTests.swift
git commit -m "feat: add bounded GIF recording"
```

### Task 11: Integrate the Library, Recording, and Capture UI

**Files:**
- Modify: `TakeAShot/Models.swift`
- Modify: `TakeAShot/MacContentView.swift`
- Modify: `TakeAShot/CaptureController.swift`
- Modify: `TakeAShot/TakeAShotApp.swift`
- Delete: `TakeAShot/ContentView.swift`
- Delete: `TakeAShot/EditorViews.swift`
- Modify: `TakeAShot.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: all earlier service APIs.
- Produces: one coherent app flow and no enabled placeholder controls.

- [ ] **Step 1: Replace singleton image state with coordinator state**

`AppState` publishes `activeCapture`, `annotationHistory`, `records`, `searchText`, `recordingState`, `progress`, and `presentedError`. It exposes explicit actions:

```swift
@MainActor
final class AppState: ObservableObject {
    func capture(mode: CaptureMode, options: CaptureOptions)
    func stopRecording()
    func cancelCurrentOperation()
    func copyActiveCapture()
    func saveActiveCapture(format: ExportFormat)
    func openRecord(_ id: UUID)
    func deleteRecord(_ id: UUID)
    func search(_ query: String)
    func undoAnnotation()
    func redoAnnotation()
}

struct PresentedError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let recoveryTitle: String?
}
```

- [ ] **Step 2: Make capture and recording controls truthful**

Area, window, fullscreen, scrolling, record-video, and record-GIF call distinct actions. Present a source picker for windows/recordings, progress/cancel for scrolling, and elapsed time/stop for recording. Disable audio controls during GIF recording.

- [ ] **Step 3: Replace the hardcoded library**

Bind the inspector to `records`, add search and tag fields, and implement reopen, copy, export, reveal in Finder, and confirmed deletion. Thumbnails load from the 512-pixel files; originals load only on action.

- [ ] **Step 4: Postpone cloud upload explicitly**

Remove simulated `uploaded = true` state and fake URLs. Keep one disabled control labeled `Cloud upload — Coming later` with help text; no enabled button may toggle a fake result.

- [ ] **Step 5: Remove macOS-dead mobile UI and build**

Remove `ContentView.swift` and `EditorViews.swift` references and files, remove the non-macOS branch from `TakeAShotApp`, and verify no live control has an empty action closure.

```bash
rg -n "Button \{\s*\}|action: \{\}|shot\.link|uploaded\.toggle" TakeAShot
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project TakeAShot.xcodeproj -scheme TakeAShot -destination 'platform=macOS' -derivedDataPath /tmp/take-a-shot-derived CODE_SIGNING_ALLOWED=NO
```

Expected: search returns no enabled placeholder actions or fake cloud state; tests and build succeed.

- [ ] **Step 6: Commit UI integration**

```bash
git add -A TakeAShot TakeAShot.xcodeproj
git commit -m "feat: integrate capture editing recording and library UI"
```

### Task 12: Documentation, Release Verification, and Performance Checks

**Files:**
- Modify: `README.md`
- Modify: `script/build_and_run.sh`

**Interfaces:**
- Consumes: completed app behavior.
- Produces: reproducible verification and accurate user documentation.

- [ ] **Step 1: Document real workflows and limits**

Update the README with area/window/display/scrolling capture, annotation gestures, MP4/GIF recording, OCR search, export formats, Screen Recording/Accessibility/Microphone permissions, safety limits, and cloud postponement.

- [ ] **Step 2: Make `--verify` run automated checks before launch**

The script’s verify branch must run the same `xcodebuild test` command used above, then launch the app and verify the process. Normal `run` behavior remains unchanged.

- [ ] **Step 3: Run fresh automated verification**

```bash
rm -rf /tmp/take-a-shot-final-derived
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project TakeAShot.xcodeproj -scheme TakeAShot \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/take-a-shot-final-derived CODE_SIGNING_ALLOWED=NO
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet \
  -project TakeAShot.xcodeproj -scheme TakeAShot \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/take-a-shot-final-derived CODE_SIGNING_ALLOWED=NO build analyze
```

Expected: `** TEST SUCCEEDED **`, Release build exit code 0, analyzer exit code 0.

- [ ] **Step 4: Run the manual permission and media matrix**

Verify area/display/window capture on each attached display, Retina dimensions, permission denial/recovery, Safari scrolling capture, one AppKit scrolling capture, MP4 with each audio combination, GIF limits, annotation export, OCR after relaunch, delete cleanup, and cancelled-operation temp-file cleanup. Record actual outcomes in the final handoff; do not claim an unexecuted manual case.

- [ ] **Step 5: Inspect performance**

Use Instruments Time Profiler and Allocations during a full-display capture, a 20-frame scrolling capture, a 30-second MP4, and a 30-second GIF. Acceptance thresholds: no synchronous Image I/O call on the main thread, no unbounded frame retention, and memory returns near its pre-operation baseline after cancellation/finalization.

- [ ] **Step 6: Commit docs and verification script**

```bash
git add README.md script/build_and_run.sh
git commit -m "docs: document capture and recording workflows"
git status --short
```

Expected: worktree is clean except intentionally ignored local environment state.
