import XCTest
@testable import TakeAShot

final class ScreenCaptureTests: XCTestCase {
    func testEveryCaptureModeHasADistinctIntent() {
        XCTAssertEqual(CaptureIntent(mode: .area), .areaSelection)
        XCTAssertEqual(CaptureIntent(mode: .window), .windowPicker)
        XCTAssertEqual(CaptureIntent(mode: .fullScreen), .display)
        XCTAssertEqual(CaptureIntent(mode: .scrolling), .scrollingWindowPicker)
        XCTAssertEqual(CaptureIntent(mode: .record), .recordingPicker)
    }

    func testImplementedScreenshotAndScrollingIntentsAreAvailable() {
        XCTAssertTrue(CaptureIntent.areaSelection.isAvailable)
        XCTAssertTrue(CaptureIntent.windowPicker.isAvailable)
        XCTAssertTrue(CaptureIntent.display.isAvailable)
        XCTAssertTrue(CaptureIntent.scrollingWindowPicker.isAvailable)
        XCTAssertFalse(CaptureIntent.recordingPicker.isAvailable)
    }

    func testIntegratedControlsHaveExplicitAccessibilityAndNoInteractiveMockAction() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ui = try String(contentsOf: projectRoot.appendingPathComponent("TakeAShot/MacContentView.swift"))
        let controller = try String(contentsOf: projectRoot.appendingPathComponent("TakeAShot/CaptureController.swift"))
        let canvas = try String(contentsOf: projectRoot.appendingPathComponent("TakeAShot/CanvasViews.swift"))

        for label in [
            "Undo annotation",
            "Redo annotation",
            "Annotation color",
            "Export capture",
            "Choose a recording source",
            "Choose a window to capture",
            "Choose a scrolling capture window",
        ] {
            XCTAssertTrue(ui.contains(label) || controller.contains(label), "Missing accessibility label: \(label)")
        }
        XCTAssertFalse(canvas.contains("Button(\"Update plan\")"))
        XCTAssertFalse(ui.contains("[.preparing, .recording, .stopping]"))
        XCTAssertTrue(ui.contains("appState.canStartRecording"))
    }

    func testScrollingAndDeferredRecordingExposeTruthfulButtonLabels() {
        XCTAssertEqual(
            CaptureIntent.scrollingWindowPicker.captureButtonTitle,
            "Capture Scrolling Window"
        )
        XCTAssertEqual(
            CaptureIntent.recordingPicker.captureButtonTitle,
            "Choose Recording Source"
        )
    }

    func testSourceSelectionUsesRequestedDisplayAndWindowIdentifiers() throws {
        let requestedDisplay = CaptureSource(
            id: "display:22",
            title: "Second display",
            kind: .display(DisplayGeometry(id: 22, frame: CGRect(x: 100, y: 0, width: 80, height: 60), scale: 2))
        )
        let requestedWindow = CaptureSource(
            id: "window:44",
            title: "Browser",
            kind: .window(44, CGRect(x: 110, y: 10, width: 40, height: 30))
        )
        let sources = CaptureSources(
            displays: [
                CaptureSource(
                    id: "display:11",
                    title: "First display",
                    kind: .display(DisplayGeometry(id: 11, frame: CGRect(x: 0, y: 0, width: 100, height: 80), scale: 1))
                ),
                requestedDisplay,
            ],
            windows: [
                CaptureSource(id: "window:33", title: "Terminal", kind: .window(33, .zero)),
                requestedWindow,
            ]
        )

        XCTAssertEqual(try CaptureSourceSelector.display(22, in: sources), requestedDisplay)
        XCTAssertEqual(try CaptureSourceSelector.window(44, in: sources), requestedWindow)
    }

    func testSourceSelectionThrowsWhenRequestedSourceIsMissing() {
        let sources = CaptureSources(displays: [], windows: [])

        XCTAssertThrowsError(try CaptureSourceSelector.display(99, in: sources)) { error in
            XCTAssertEqual(error as? CaptureError, .sourceUnavailable)
        }
        XCTAssertThrowsError(try CaptureSourceSelector.window(77, in: sources)) { error in
            XCTAssertEqual(error as? CaptureError, .sourceUnavailable)
        }
    }

    func testWindowDiscoveryExcludesCurrentApplication() {
        XCTAssertFalse(
            WindowSourceFilter.shouldInclude(
                ownerBundleIdentifier: "com.bruno.takeashot",
                ownBundleIdentifier: "com.bruno.takeashot"
            )
        )
        XCTAssertTrue(
            WindowSourceFilter.shouldInclude(
                ownerBundleIdentifier: "com.apple.Safari",
                ownBundleIdentifier: "com.bruno.takeashot"
            )
        )
    }

    func testHideDesktopIconsUsesExclusionPlanAndPreservesBackgroundDockAndApps() {
        let windows = [
            DisplayCaptureFilterWindow(
                id: 10,
                ownerBundleIdentifier: "com.apple.finder",
                windowLevel: Int(CGWindowLevelForKey(.desktopIconWindow))
            ),
            DisplayCaptureFilterWindow(
                id: 11,
                ownerBundleIdentifier: nil,
                windowLevel: Int(CGWindowLevelForKey(.desktopWindow))
            ),
            DisplayCaptureFilterWindow(
                id: 12,
                ownerBundleIdentifier: "com.apple.dock",
                windowLevel: Int(CGWindowLevelForKey(.dockWindow))
            ),
            DisplayCaptureFilterWindow(
                id: 13,
                ownerBundleIdentifier: "com.bruno.takeashot",
                windowLevel: Int(CGWindowLevelForKey(.normalWindow))
            ),
            DisplayCaptureFilterWindow(
                id: 14,
                ownerBundleIdentifier: "com.apple.Safari",
                windowLevel: Int(CGWindowLevelForKey(.normalWindow))
            ),
        ]

        let plan = DisplayCaptureFilterPlanner.plan(
            windows: windows,
            hidesDesktopIcons: true,
            ownBundleIdentifier: "com.bruno.takeashot"
        )

        XCTAssertEqual(plan, .excludingWindows([10, 13]))
    }

    func testVisibleDesktopIconsStillUseExclusionPlanForOwnWindowsOnly() {
        let windows = [
            DisplayCaptureFilterWindow(
                id: 20,
                ownerBundleIdentifier: "com.apple.finder",
                windowLevel: Int(CGWindowLevelForKey(.desktopIconWindow))
            ),
            DisplayCaptureFilterWindow(
                id: 21,
                ownerBundleIdentifier: "com.bruno.takeashot",
                windowLevel: Int(CGWindowLevelForKey(.normalWindow))
            ),
        ]

        let plan = DisplayCaptureFilterPlanner.plan(
            windows: windows,
            hidesDesktopIcons: false,
            ownBundleIdentifier: "com.bruno.takeashot"
        )

        XCTAssertEqual(plan, .excludingWindows([21]))
    }

    func testCaptureAreaUsesOwningDisplayGeometryAndRequestedOptions() async throws {
        let display = DisplayGeometry(
            id: 22,
            frame: CGRect(x: 100, y: 0, width: 80, height: 60),
            scale: 2
        )
        let provider = StubScreenCaptureKitProvider(
            snapshot: ScreenCaptureSourceSnapshot(displays: [display], windows: []),
            image: try TestImage.solid(width: 40, height: 40, color: .red)
        )
        let engine = ScreenCaptureEngine(
            provider: provider,
            ownBundleIdentifier: "com.bruno.takeashot"
        )
        let options = CaptureOptions(
            showsCursor: false,
            excludesDesktopWindows: true,
            delay: .seconds(3)
        )

        let captured = try await engine.captureArea(
            CGRect(x: 110, y: 10, width: 20, height: 20),
            display: display,
            options: options
        )

        let request = try await provider.displayRequests.last.unwrapped()
        XCTAssertEqual(request.displayID, 22)
        XCTAssertEqual(request.sourceRect, CGRect(x: 10, y: 30, width: 20, height: 20))
        XCTAssertEqual(request.pixelSize, PixelSize(width: 40, height: 40))
        XCTAssertEqual(request.options, options)
        XCTAssertEqual(captured.kind, .area)
        XCTAssertEqual(captured.pixelSize, PixelSize(width: 40, height: 40))
    }

    func testCaptureDisplayUsesRequestedDisplayInsteadOfMainDisplay() async throws {
        let first = DisplayGeometry(id: 11, frame: CGRect(x: 0, y: 0, width: 100, height: 80), scale: 1)
        let requested = DisplayGeometry(id: 22, frame: CGRect(x: 100, y: 0, width: 80, height: 60), scale: 2)
        let provider = StubScreenCaptureKitProvider(
            snapshot: ScreenCaptureSourceSnapshot(displays: [first, requested], windows: []),
            image: try TestImage.solid(width: 160, height: 120, color: .blue)
        )
        let engine = ScreenCaptureEngine(provider: provider, ownBundleIdentifier: nil)

        let captured = try await engine.captureDisplay(22, options: CaptureOptions())

        let request = try await provider.displayRequests.last.unwrapped()
        XCTAssertEqual(request.displayID, 22)
        XCTAssertEqual(request.sourceRect, CGRect(origin: .zero, size: requested.frame.size))
        XCTAssertEqual(request.pixelSize, PixelSize(width: 160, height: 120))
        XCTAssertEqual(captured.kind, .display)
    }

    func testCaptureWindowUsesRequestedWindowAndExcludesOwnWindowsFromSources() async throws {
        let ownWindow = ScreenCaptureWindowSnapshot(
            id: 55,
            frame: CGRect(x: 0, y: 0, width: 10, height: 10),
            title: "Take a Shot",
            ownerBundleIdentifier: "com.bruno.takeashot"
        )
        let browserWindow = ScreenCaptureWindowSnapshot(
            id: 77,
            frame: CGRect(x: 20, y: 10, width: 100, height: 80),
            title: "Browser",
            ownerBundleIdentifier: "com.apple.Safari"
        )
        let provider = StubScreenCaptureKitProvider(
            snapshot: ScreenCaptureSourceSnapshot(displays: [], windows: [ownWindow, browserWindow]),
            image: try TestImage.solid(width: 200, height: 160, color: .green)
        )
        let engine = ScreenCaptureEngine(
            provider: provider,
            ownBundleIdentifier: "com.bruno.takeashot"
        )

        let sources = try await engine.sources()
        let captured = try await engine.captureWindow(77, options: CaptureOptions())
        let windowRequest = await provider.windowRequests.last

        XCTAssertEqual(sources.windows.map(\.id), ["window:77"])
        XCTAssertEqual(windowRequest?.windowID, 77)
        XCTAssertEqual(captured.kind, .window)
        XCTAssertEqual(captured.title, "Browser")
    }

    func testCaptureWindowPreservesProviderCancellation() async throws {
        let window = ScreenCaptureWindowSnapshot(
            id: 77,
            frame: CGRect(x: 20, y: 10, width: 100, height: 80),
            title: "Browser",
            ownerBundleIdentifier: "com.apple.Safari"
        )
        let provider = CancellingScreenCaptureKitProvider(
            snapshot: ScreenCaptureSourceSnapshot(displays: [], windows: [window])
        )
        let engine = ScreenCaptureEngine(provider: provider, ownBundleIdentifier: nil)

        do {
            _ = try await engine.captureWindow(77, options: CaptureOptions())
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCaptureAreaRejectsSelectionOutsideOwningDisplay() async throws {
        let display = DisplayGeometry(id: 22, frame: CGRect(x: 100, y: 0, width: 80, height: 60), scale: 2)
        let provider = StubScreenCaptureKitProvider(
            snapshot: ScreenCaptureSourceSnapshot(displays: [display], windows: []),
            image: try TestImage.solid(width: 1, height: 1, color: .black)
        )
        let engine = ScreenCaptureEngine(provider: provider, ownBundleIdentifier: nil)

        do {
            _ = try await engine.captureArea(
                CGRect(x: 90, y: 10, width: 20, height: 20),
                display: display,
                options: CaptureOptions()
            )
            XCTFail("Expected invalid selection")
        } catch {
            XCTAssertEqual(error as? CaptureError, .invalidSelection)
        }

        let displayRequests = await provider.displayRequests
        XCTAssertTrue(displayRequests.isEmpty)
    }

    @MainActor
    func testCoordinatorDispatchesEveryIntentToDistinctHandlerMethod() {
        let handler = RecordingCaptureIntentHandler()

        for intent in [
            CaptureIntent.areaSelection,
            .windowPicker,
            .display,
            .scrollingWindowPicker,
            .recordingPicker,
        ] {
            CaptureCoordinator.dispatch(intent, options: CaptureOptions(), to: handler)
        }

        XCTAssertEqual(
            handler.intents,
            [.areaSelection, .windowPicker, .display, .scrollingWindowPicker, .recordingPicker]
        )
    }

    @MainActor
    func testSchedulingNewCaptureCancelsPendingDelay() async {
        let handler = RecordingCaptureIntentHandler()
        let scheduler = CaptureIntentScheduler(handler: handler)
        let dispatched = expectation(description: "replacement capture dispatched")
        handler.onIntent = { intent in
            if intent == .display { dispatched.fulfill() }
        }
        var delayedOptions = CaptureOptions()
        delayedOptions.delay = .seconds(60)

        scheduler.schedule(.areaSelection, options: delayedOptions)
        await Task.yield()
        scheduler.schedule(.display, options: CaptureOptions())

        await fulfillment(of: [dispatched], timeout: 1)
        XCTAssertEqual(handler.intents, [.display])
    }

    @MainActor
    func testCapturePipelinePersistsBeforePublishingSuccess() async throws {
        let image = try TestImage.solid(width: 8, height: 6, color: .purple)
        let capture = CapturedImage(
            id: UUID(),
            kind: .display,
            title: "Display",
            createdAt: .now,
            image: image,
            pixelSize: PixelSize(width: 8, height: 6)
        )
        let recorder = CaptureEventRecorder()
        let publisher = StubCapturePublisher(recorder: recorder)
        let pipeline = CapturePipeline(
            capturer: StubScreenshotCapturer(capturedImage: capture),
            persistence: StubCapturePersistence(recorder: recorder),
            publisher: publisher
        )

        try await pipeline.captureDisplay(22, options: CaptureOptions())

        XCTAssertEqual(recorder.events, ["persist", "publish"])
        XCTAssertEqual(publisher.images.map(\.id), [capture.id])
    }

    @MainActor
    func testCapturePipelineDoesNotPublishWhenPersistenceFails() async throws {
        let image = try TestImage.solid(width: 8, height: 6, color: .purple)
        let capture = CapturedImage(
            id: UUID(),
            kind: .display,
            title: "Display",
            createdAt: .now,
            image: image,
            pixelSize: PixelSize(width: 8, height: 6)
        )
        let recorder = CaptureEventRecorder()
        let publisher = StubCapturePublisher(recorder: recorder)
        let pipeline = CapturePipeline(
            capturer: StubScreenshotCapturer(capturedImage: capture),
            persistence: StubCapturePersistence(recorder: recorder, error: TestCaptureError.persistence),
            publisher: publisher
        )

        do {
            try await pipeline.captureDisplay(22, options: CaptureOptions())
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual(error as? TestCaptureError, .persistence)
        }

        XCTAssertEqual(recorder.events, ["persist"])
        XCTAssertTrue(publisher.images.isEmpty)
    }

    func testAreaSelectionConvertsLocalRectToGlobalRectAndKeepsOwningDisplay() {
        let display = DisplayGeometry(
            id: 88,
            frame: CGRect(x: -1440, y: 120, width: 1440, height: 900),
            scale: 2
        )

        let selection = AreaSelection(
            localRect: CGRect(x: 20, y: 30, width: 400, height: 240),
            display: display
        )

        XCTAssertEqual(selection.rect, CGRect(x: -1420, y: 150, width: 400, height: 240))
        XCTAssertEqual(selection.displayID, 88)
        XCTAssertEqual(selection.display, display)
    }

    @MainActor
    func testCapturePipelineUsesPersistenceGateForAreaAndWindow() async throws {
        let image = try TestImage.solid(width: 8, height: 6, color: .orange)
        let capture = CapturedImage(
            id: UUID(),
            kind: .area,
            title: "Capture",
            createdAt: .now,
            image: image,
            pixelSize: PixelSize(width: 8, height: 6)
        )
        let recorder = CaptureEventRecorder()
        let publisher = StubCapturePublisher(recorder: recorder)
        let pipeline = CapturePipeline(
            capturer: StubScreenshotCapturer(capturedImage: capture),
            persistence: StubCapturePersistence(recorder: recorder),
            publisher: publisher
        )
        let display = DisplayGeometry(
            id: 22,
            frame: CGRect(x: 0, y: 0, width: 100, height: 80),
            scale: 1
        )

        try await pipeline.captureArea(
            CGRect(x: 10, y: 10, width: 20, height: 20),
            display: display,
            options: CaptureOptions()
        )
        try await pipeline.captureWindow(77, options: CaptureOptions())

        XCTAssertEqual(recorder.events, ["persist", "publish", "persist", "publish"])
        XCTAssertEqual(publisher.images.count, 2)
    }
}

private actor CancellingScreenCaptureKitProvider: ScreenCaptureKitProviding {
    let snapshot: ScreenCaptureSourceSnapshot

    init(snapshot: ScreenCaptureSourceSnapshot) {
        self.snapshot = snapshot
    }

    func sourceSnapshot() async throws -> ScreenCaptureSourceSnapshot {
        snapshot
    }

    func captureDisplay(_ request: ScreenCaptureDisplayRequest) async throws -> CGImage {
        throw CancellationError()
    }

    func captureWindow(_ request: ScreenCaptureWindowRequest) async throws -> CGImage {
        throw CancellationError()
    }
}
