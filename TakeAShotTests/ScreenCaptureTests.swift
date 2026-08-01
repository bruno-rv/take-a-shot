import AppKit
import XCTest
@testable import TakeAShot

final class ScreenCaptureTests: XCTestCase {
    func testEveryCaptureModeHasADistinctIntent() {
        XCTAssertEqual(CaptureIntent(mode: .area), .areaSelection)
        XCTAssertEqual(CaptureIntent(mode: .window), .windowPicker)
        XCTAssertEqual(CaptureIntent(mode: .fullScreen), .display)
        XCTAssertEqual(CaptureIntent(mode: .scrolling), .scrollingWindowPicker)
        XCTAssertEqual(CaptureIntent(mode: .scrollingManual), .scrollingAreaSelection)
        XCTAssertEqual(CaptureIntent(mode: .record), .recordingPicker)
    }

    func testImplementedScreenshotAndScrollingIntentsAreAvailable() {
        XCTAssertTrue(CaptureIntent.areaSelection.isAvailable)
        XCTAssertTrue(CaptureIntent.windowPicker.isAvailable)
        XCTAssertTrue(CaptureIntent.display.isAvailable)
        XCTAssertTrue(CaptureIntent.scrollingWindowPicker.isAvailable)
        XCTAssertTrue(CaptureIntent.scrollingAreaSelection.isAvailable)
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

    func testSupportsWindowExclusionDefaultsToTrueAndForwardsProviderOverride() async throws {
        let display = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 1)
        let realProvider = StubScreenCaptureKitProvider(
            snapshot: ScreenCaptureSourceSnapshot(displays: [display], windows: []),
            image: try TestImage.solid(width: 4, height: 4, color: .red)
        )
        XCTAssertTrue(ScreenCaptureEngine(provider: realProvider, ownBundleIdentifier: nil).supportsWindowExclusion())

        let unsupportedProvider = ExclusionProbeStubProvider(
            snapshot: ScreenCaptureSourceSnapshot(displays: [display], windows: []),
            image: try TestImage.solid(width: 4, height: 4, color: .red),
            supportsWindowExclusion: false
        )
        XCTAssertFalse(
            ScreenCaptureEngine(provider: unsupportedProvider, ownBundleIdentifier: nil).supportsWindowExclusion()
        )
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
            .scrollingAreaSelection,
            .recordingPicker,
        ] {
            CaptureCoordinator.dispatch(intent, options: CaptureOptions(), to: handler)
        }

        XCTAssertEqual(
            handler.intents,
            [.areaSelection, .windowPicker, .display, .scrollingWindowPicker, .scrollingAreaSelection, .recordingPicker]
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
    func testControllerCancellationCompletesDelayedCaptureExactlyOnce() async throws {
        let capture = try TestImage.capturedForOperationTest()
        let recorder = CaptureEventRecorder()
        let controller = ScreenCaptureController(
            capturer: StubScreenshotCapturer(capturedImage: capture),
            persistence: StubCapturePersistence(recorder: recorder),
            publisher: StubCapturePublisher(recorder: recorder)
        )
        var options = CaptureOptions()
        options.delay = .seconds(60)
        var completionCount = 0

        controller.scheduleCapture(
            mode: .area,
            options: options,
            completion: AppCaptureCompletion { completionCount += 1 }
        )
        await Task.yield()
        try await controller.cancelCurrentOperation()
        try await controller.cancelCurrentOperation()

        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    @MainActor
    func testNewFullScreenIntentInvalidatesGatedWindowDiscoveryBeforePresentation() async throws {
        let scope = CaptureOperationScope()
        let gate = AsyncCaptureGate()
        let presented = CapturePresentationRecorder()
        let windowToken = try XCTUnwrap(scope.begin(.windowDiscovery))
        let discovery = Task {
            await gate.wait()
            guard scope.isCurrent(windowToken) else { return }
            presented.presentWindowPicker()
        }
        scope.retain(discovery, for: windowToken)
        await fulfillment(of: [gate.started], timeout: 1)

        let displayToken = try XCTUnwrap(scope.begin(.displayCapture))
        await gate.open()
        await discovery.value

        XCTAssertTrue(scope.isCurrent(displayToken))
        XCTAssertEqual(presented.windowPickerCount, 0)
    }

    @MainActor
    func testRepeatedScrollingDiscoveryDoesNotStartConcurrently() async throws {
        let scope = CaptureOperationScope()
        let first = try XCTUnwrap(scope.begin(.scrollingDiscovery))

        XCTAssertNil(scope.begin(.scrollingDiscovery))
        XCTAssertTrue(scope.isCurrent(first))
    }

    @MainActor
    func testAreaOverlayCancellationCompletesExactCallbackOnce() throws {
        var completionCount = 0
        let completion = CaptureOperationCompletion(
            AppCaptureCompletion { completionCount += 1 }
        )
        let scope = CaptureOperationScope()
        let token = try XCTUnwrap(scope.begin(.areaSelection, completion: completion))

        scope.cancel()
        scope.finish(token)

        XCTAssertEqual(completionCount, 1)
    }

    @MainActor
    func testCancellationWaitsForPersistingOperationBeforeCompletingCallback() async throws {
        var completionCount = 0
        let completion = CaptureOperationCompletion(
            AppCaptureCompletion { completionCount += 1 }
        )
        let scope = CaptureOperationScope()
        let token = try XCTUnwrap(scope.begin(.windowDiscovery, completion: completion))
        let gate = AsyncCaptureGate()
        let persistence = Task {
            defer { scope.finish(token) }
            await gate.wait()
        }
        scope.retain(persistence, for: token)
        await fulfillment(of: [gate.started], timeout: 1)

        let cancellation = Task { try await scope.cancelAndWait() }
        await Task.yield()
        XCTAssertEqual(completionCount, 0)
        await gate.open()
        _ = try await cancellation.value

        XCTAssertEqual(completionCount, 1)
    }

    @MainActor
    func testCancelAndWaitPropagatesInvalidatedCleanupFailure() async throws {
        let scope = CaptureOperationScope()
        let token = try XCTUnwrap(scope.begin(.windowDiscovery))
        let gate = AsyncCaptureGate()
        scope.registerCleanupRetry(CaptureCleanupRetryOperation(run: {
            throw CaptureLibraryError.rollbackFailed(primary: "cancelled", rollback: "denied")
        }), for: token)
        let operation = Task<Void, Error> {
            defer { scope.finish(token) }
            await gate.wait()
            throw CaptureLibraryError.rollbackFailed(primary: "cancelled", rollback: "denied")
        }
        scope.retain(operation, for: token)
        await fulfillment(of: [gate.started], timeout: 1)
        let cancellation = Task { try await scope.cancelAndWait() }
        await gate.open()

        guard case .failure(let error) = await cancellation.result,
              let libraryError = error as? CaptureLibraryError,
              case .rollbackFailed = libraryError else {
            return XCTFail("Expected invalidated cleanup failure")
        }
    }

    @MainActor
    func testStaleNonCleanupErrorCompletesWithoutLatchingCancellation() async throws {
        var completionCount = 0
        let completion = CaptureOperationCompletion(
            AppCaptureCompletion { completionCount += 1 }
        )
        let scope = CaptureOperationScope()
        let token = try XCTUnwrap(scope.begin(.windowDiscovery, completion: completion))
        let gate = AsyncCaptureGate()
        let operation = Task<Void, Error> {
            defer { scope.finish(token) }
            await gate.wait()
            throw CaptureError.sourceUnavailable
        }
        scope.retain(operation, for: token)
        await fulfillment(of: [gate.started], timeout: 1)
        let cancellation = Task { try await scope.cancelAndWait() }
        await gate.open()

        try await cancellation.value
        XCTAssertEqual(completionCount, 1)
        try await scope.cancelAndWait()
        XCTAssertNotNil(scope.begin(.displayCapture))
    }

    @MainActor
    func testSourcePickerDismissalCompletesExactCallbackOnce() async throws {
        var completionCount = 0
        let completion = CaptureOperationCompletion(
            AppCaptureCompletion { completionCount += 1 }
        )
        let scope = CaptureOperationScope()
        let token = try XCTUnwrap(scope.begin(.windowDiscovery, completion: completion))
        let gate = AsyncCaptureGate()
        let picker = Task {
            defer { scope.finish(token) }
            await gate.wait()
        }
        scope.retain(picker, for: token)
        await fulfillment(of: [gate.started], timeout: 1)

        await gate.open()
        await picker.value
        scope.finish(token)

        XCTAssertEqual(completionCount, 1)
    }

    @MainActor
    func testStaleOperationCompletionCannotCompleteNewerCallback() async throws {
        var oldCompletionCount = 0
        var newCompletionCount = 0
        let oldCompletion = CaptureOperationCompletion(
            AppCaptureCompletion { oldCompletionCount += 1 }
        )
        let newCompletion = CaptureOperationCompletion(
            AppCaptureCompletion { newCompletionCount += 1 }
        )
        let scope = CaptureOperationScope()
        let oldToken = try XCTUnwrap(scope.begin(.windowDiscovery, completion: oldCompletion))
        let gate = AsyncCaptureGate()
        let oldOperation = Task {
            defer { scope.finish(oldToken) }
            await gate.wait()
        }
        scope.retain(oldOperation, for: oldToken)
        await fulfillment(of: [gate.started], timeout: 1)

        let newToken = try XCTUnwrap(scope.begin(.displayCapture, completion: newCompletion))
        scope.finish(newToken)
        XCTAssertEqual(newCompletionCount, 1)
        await gate.open()
        await oldOperation.value

        XCTAssertEqual(oldCompletionCount, 1)
        XCTAssertEqual(newCompletionCount, 1)
    }

    @MainActor
    func testNewerFullScreenIntentPreventsGatedWindowCaptureFromPersistingOrPublishing() async throws {
        let image = try TestImage.capturedForOperationTest()
        let capturer = GatedWindowCapturer(image: image)
        let recorder = CaptureEventRecorder()
        let publisher = StubCapturePublisher(recorder: recorder)
        let pipeline = CapturePipeline(
            capturer: capturer,
            persistence: StubCapturePersistence(recorder: recorder),
            publisher: publisher
        )
        let scope = CaptureOperationScope()
        let windowToken = try XCTUnwrap(scope.begin(.windowDiscovery))
        let capture = Task {
            try? await pipeline.captureWindow(
                77,
                options: CaptureOptions(),
                isCurrent: { scope.isCurrent(windowToken) }
            )
        }
        scope.retain(capture, for: windowToken)
        await fulfillment(of: [capturer.started], timeout: 1)

        _ = scope.begin(.displayCapture)
        await capturer.resume()
        await capture.value

        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertTrue(publisher.publications.isEmpty)
    }

    @MainActor
    func testStaleCommittedOutcomeRollsBackBeforeReturningCancellation() async throws {
        let capture = try TestImage.capturedForOperationTest()
        let persistence = GatedCommittedCapturePersistence()
        let recorder = CaptureEventRecorder()
        let publisher = StubCapturePublisher(recorder: recorder)
        let pipeline = CapturePipeline(
            capturer: StubScreenshotCapturer(capturedImage: capture),
            persistence: persistence,
            publisher: publisher
        )
        let scope = CaptureOperationScope()
        let token = try XCTUnwrap(scope.begin(.windowDiscovery))
        let operation = Task<Void, Error> {
            defer { scope.finish(token) }
            try await pipeline.persistAndPublish(
                capture,
                isCurrent: { scope.isCurrent(token) }
            )
        }
        scope.retain(operation, for: token)
        await fulfillment(of: [persistence.committed], timeout: 1)

        scope.cancel()
        await persistence.returnCommittedOutcome()

        guard case .failure(let error) = await operation.result else {
            return XCTFail("Expected stale committed capture cancellation")
        }
        XCTAssertTrue(error is CancellationError)
        let rolledBackRecordIDs = await persistence.rolledBackRecordIDs
        XCTAssertEqual(rolledBackRecordIDs, [capture.id])
        XCTAssertTrue(publisher.publications.isEmpty)
    }

    @MainActor
    func testStaleCommittedOutcomePropagatesRollbackFailure() async throws {
        let capture = try TestImage.capturedForOperationTest()
        let failure = CaptureLibraryError.rollbackFailed(
            primary: "cancelled",
            rollback: "cleanup denied"
        )
        let persistence = GatedCommittedCapturePersistence(rollbackError: failure)
        let recorder = CaptureEventRecorder()
        let pipeline = CapturePipeline(
            capturer: StubScreenshotCapturer(capturedImage: capture),
            persistence: persistence,
            publisher: StubCapturePublisher(recorder: recorder)
        )
        let scope = CaptureOperationScope()
        let token = try XCTUnwrap(scope.begin(.windowDiscovery))
        let operation = Task<Void, Error> {
            defer { scope.finish(token) }
            try await pipeline.persistAndPublish(
                capture,
                isCurrent: { scope.isCurrent(token) }
            )
        }
        scope.retain(operation, for: token)
        await fulfillment(of: [persistence.committed], timeout: 1)

        scope.cancel()
        await persistence.returnCommittedOutcome()

        guard case .failure(let error) = await operation.result,
              let libraryError = error as? CaptureLibraryError,
              case .rollbackFailed = libraryError else {
            return XCTFail("Expected committed outcome rollback failure")
        }
        XCTAssertTrue(recorder.events.isEmpty)
    }

    @MainActor
    func testCleanupFailureRemainsLatchedUntilExactRetrySucceeds() async throws {
        let capture = try TestImage.capturedForOperationTest()
        var completionCount = 0
        let completion = CaptureOperationCompletion(
            AppCaptureCompletion { completionCount += 1 }
        )
        let persistence = RetryableCommittedCapturePersistence()
        let recorder = CaptureEventRecorder()
        let pipeline = CapturePipeline(
            capturer: StubScreenshotCapturer(capturedImage: capture),
            persistence: persistence,
            publisher: StubCapturePublisher(recorder: recorder)
        )
        let scope = CaptureOperationScope()
        let token = try XCTUnwrap(scope.begin(.windowDiscovery, completion: completion))
        let operation = Task<Void, Error> {
            defer { scope.finish(token) }
            try await pipeline.persistAndPublish(
                capture,
                isCurrent: { scope.isCurrent(token) },
                registerCleanupRetry: { retry in
                    scope.registerCleanupRetry(retry, for: token)
                }
            )
        }
        scope.retain(operation, for: token)
        await fulfillment(of: [persistence.committed], timeout: 1)
        let firstCancellation = Task { try await scope.cancelAndWait() }
        await persistence.returnCommittedOutcome()

        guard case .failure(let firstError) = await firstCancellation.result else {
            return XCTFail("Expected first cleanup failure")
        }
        XCTAssertNotNil(firstError as? CaptureLibraryError)
        XCTAssertEqual(completionCount, 0)
        XCTAssertNil(scope.begin(.displayCapture))
        do {
            try await scope.cancelAndWait()
            XCTFail("Expected second cleanup failure")
        } catch {
            XCTAssertNotNil(error as? CaptureLibraryError)
        }
        let committedAfterSecondFailure = await persistence.hasCommittedCapture
        XCTAssertTrue(committedAfterSecondFailure)
        XCTAssertEqual(completionCount, 0)

        await persistence.allowCleanup()
        try await scope.cancelAndWait()

        let committedAfterRetry = await persistence.hasCommittedCapture
        let rollbackAttempts = await persistence.rollbackAttempts
        XCTAssertFalse(committedAfterRetry)
        XCTAssertEqual(rollbackAttempts, 3)
        XCTAssertEqual(completionCount, 1)
        XCTAssertNotNil(scope.begin(.displayCapture))
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testExactCleanupRetryRemovesAssetsAfterIndexRollbackAlreadySucceeded() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try TestImage.capturedForOperationTest()
        let cleanup = FailingCaptureCleanup()
        let fileOperations = CaptureLibraryFileOperations(
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try cleanup.remove($0) }
        )
        let store = CaptureLibraryStore(
            rootURL: root,
            ocr: EmptyCaptureOCR(),
            fileOperations: fileOperations
        )
        _ = try await store.persist(image: capture)
        let outcome = CapturePersistenceOutcome(recordID: capture.id)

        for _ in 0..<2 {
            do {
                try await store.rollbackPersistedCapture(outcome)
                XCTFail("Expected cleanup failure")
            } catch {
                XCTAssertNotNil(error as? CaptureLibraryError)
            }
        }

        cleanup.allowRemoval()
        try await store.rollbackPersistedCapture(outcome)

        let reloadedStore = CaptureLibraryStore(rootURL: root, ocr: EmptyCaptureOCR())
        let reloadedRecords = try await reloadedStore.load()
        XCTAssertTrue(reloadedRecords.isEmpty)
        let identifier = capture.id.uuidString
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("originals/\(identifier).png").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("thumbnails/\(identifier).png").path
        ))
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
        XCTAssertEqual(publisher.publications.map(\.capture.id), [capture.id])
        XCTAssertNil(publisher.publications[0].areaSelection)
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
        XCTAssertTrue(publisher.publications.isEmpty)
    }

    @MainActor
    func testSuccessfulPersistenceCompletesExactCallbackAfterPublishing() async throws {
        let capture = try TestImage.capturedForOperationTest()
        let recorder = CaptureEventRecorder()
        let pipeline = CapturePipeline(
            capturer: StubScreenshotCapturer(capturedImage: capture),
            persistence: StubCapturePersistence(recorder: recorder),
            publisher: StubCapturePublisher(recorder: recorder)
        )
        let completion = CaptureOperationCompletion(
            AppCaptureCompletion { recorder.append("complete") }
        )
        let scope = CaptureOperationScope()
        let token = try XCTUnwrap(scope.begin(.displayCapture, completion: completion))
        let operation = Task {
            defer { scope.finish(token) }
            try? await pipeline.captureDisplay(22, options: CaptureOptions())
        }
        scope.retain(operation, for: token)

        await operation.value
        scope.finish(token)

        XCTAssertEqual(recorder.events, ["persist", "publish", "complete"])
    }

    @MainActor
    func testPersistenceErrorCompletesExactCallbackAfterFailure() async throws {
        let capture = try TestImage.capturedForOperationTest()
        let recorder = CaptureEventRecorder()
        let pipeline = CapturePipeline(
            capturer: StubScreenshotCapturer(capturedImage: capture),
            persistence: StubCapturePersistence(
                recorder: recorder,
                error: TestCaptureError.persistence
            ),
            publisher: StubCapturePublisher(recorder: recorder)
        )
        let completion = CaptureOperationCompletion(
            AppCaptureCompletion { recorder.append("complete") }
        )
        let scope = CaptureOperationScope()
        let token = try XCTUnwrap(scope.begin(.displayCapture, completion: completion))
        let operation = Task {
            defer { scope.finish(token) }
            try? await pipeline.captureDisplay(22, options: CaptureOptions())
        }
        scope.retain(operation, for: token)

        await operation.value
        scope.finish(token)

        XCTAssertEqual(recorder.events, ["persist", "complete"])
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
        let selection = AreaSelection(
            localRect: CGRect(x: 10, y: 10, width: 20, height: 20),
            display: display
        )

        try await pipeline.captureArea(
            selection,
            options: CaptureOptions()
        )
        try await pipeline.captureWindow(77, options: CaptureOptions())

        XCTAssertEqual(recorder.events, ["persist", "publish", "persist", "publish"])
        XCTAssertEqual(publisher.publications.count, 2)
        XCTAssertEqual(publisher.publications[0].capture.id, capture.id)
        XCTAssertEqual(publisher.publications[0].areaSelection, selection)
        XCTAssertNil(publisher.publications[1].areaSelection)
    }

    /// PLAN.md §9's confirm-flow ordering: a non-empty payload is Baked into a fresh document
    /// (against the post-capture `CapturedImage.id`) before persistence, and both the document
    /// and the Baked render are threaded through to persistence and the publication.
    @MainActor
    func testCaptureAreaWithNonEmptyPayloadBakesDocumentBeforePersistingAndPublishing() async throws {
        let image = try TestImage.solid(width: 8, height: 6, color: .orange)
        let renderedImage = try TestImage.solid(width: 8, height: 6, color: .purple)
        let capture = CapturedImage(
            id: UUID(),
            kind: .area,
            title: "Capture",
            createdAt: .now,
            image: image,
            pixelSize: PixelSize(width: 8, height: 6)
        )
        let persistence = RecordingAnnotationPersistence()
        let recorder = CaptureEventRecorder()
        let publisher = StubCapturePublisher(recorder: recorder)
        let pipeline = CapturePipeline(
            capturer: StubScreenshotCapturer(capturedImage: capture),
            persistence: persistence,
            publisher: publisher,
            renderService: StubAnnotationRenderService(renderedImage: renderedImage)
        )
        let display = DisplayGeometry(id: 22, frame: CGRect(x: 0, y: 0, width: 100, height: 80), scale: 1)
        let selection = AreaSelection(localRect: CGRect(x: 10, y: 10, width: 20, height: 20), display: display)
        let payload = PendingAnnotationPayload(
            items: [.step(StepAnnotation(id: UUID(), center: NormalizedPoint(x: 0.5, y: 0.5), number: 1))]
        )

        try await pipeline.captureArea(selection, options: CaptureOptions(), payload: payload)

        let calls = await persistence.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].imageID, capture.id)
        XCTAssertEqual(calls[0].annotations?.captureID, capture.id)
        XCTAssertEqual(calls[0].annotations?.items, payload.items)
        XCTAssertTrue(calls[0].renderedImage === renderedImage)
        XCTAssertEqual(publisher.publications.count, 1)
        XCTAssertEqual(publisher.publications[0].document?.items, payload.items)
        XCTAssertTrue(publisher.publications[0].renderedImage === renderedImage)
    }

    /// "Freeze the image": when a pre-capture snapshot is supplied, `captureArea` crops it instead
    /// of calling the live capturer at all — proves the WYSIWYG crop path is wired into the same
    /// downstream (persist + publish) as a live capture, and that the live capturer's stub image is
    /// never used when a snapshot is available.
    @MainActor
    func testCaptureAreaCropsFrozenSnapshotInsteadOfCapturingLiveWhenSnapshotProvided() async throws {
        let display = DisplayGeometry(id: 22, frame: CGRect(x: 0, y: 0, width: 100, height: 80), scale: 2)
        let frozenSnapshot = try TestImage.verticalSplit(
            width: 200, height: 160, leftColor: .red, rightColor: .blue
        )
        let liveCapture = CapturedImage(
            id: UUID(),
            kind: .area,
            title: "Live",
            createdAt: .now,
            image: try TestImage.solid(width: 8, height: 6, color: .green),
            pixelSize: PixelSize(width: 8, height: 6)
        )
        let recorder = CaptureEventRecorder()
        let publisher = StubCapturePublisher(recorder: recorder)
        let pipeline = CapturePipeline(
            capturer: StubScreenshotCapturer(capturedImage: liveCapture),
            persistence: StubCapturePersistence(recorder: recorder),
            publisher: publisher
        )
        // Right half of the display, in local (view) coordinates: global rect x60..100.
        let selection = AreaSelection(localRect: CGRect(x: 60, y: 0, width: 40, height: 80), display: display)

        try await pipeline.captureArea(selection, options: CaptureOptions(), frozenImage: frozenSnapshot)

        let published = try publisher.publications.first.unwrapped()
        XCTAssertEqual(published.capture.kind, .area)
        XCTAssertEqual(published.capture.pixelSize, PixelSize(width: 80, height: 160))
        XCTAssertNotEqual(published.capture.id, liveCapture.id)
        let color = try TestImage.pixelColor(in: published.capture.image, x: 5, y: 5)
        XCTAssertEqual(color, NSColor.blue.usingColorSpace(.sRGB))
        XCTAssertEqual(recorder.events, ["persist", "publish"])
    }

    /// A missing/failed snapshot (permission denied, etc.) falls back to today's live capture —
    /// no data-loss path.
    @MainActor
    func testCaptureAreaFallsBackToLiveCaptureWhenNoSnapshotProvided() async throws {
        let display = DisplayGeometry(id: 22, frame: CGRect(x: 0, y: 0, width: 100, height: 80), scale: 1)
        let liveCapture = CapturedImage(
            id: UUID(),
            kind: .area,
            title: "Live",
            createdAt: .now,
            image: try TestImage.solid(width: 8, height: 6, color: .green),
            pixelSize: PixelSize(width: 8, height: 6)
        )
        let recorder = CaptureEventRecorder()
        let publisher = StubCapturePublisher(recorder: recorder)
        let pipeline = CapturePipeline(
            capturer: StubScreenshotCapturer(capturedImage: liveCapture),
            persistence: StubCapturePersistence(recorder: recorder),
            publisher: publisher
        )
        let selection = AreaSelection(localRect: CGRect(x: 10, y: 10, width: 20, height: 20), display: display)

        try await pipeline.captureArea(selection, options: CaptureOptions(), frozenImage: nil)

        let published = try publisher.publications.first.unwrapped()
        XCTAssertEqual(published.capture.id, liveCapture.id)
    }

    /// The empty-payload path must stay byte-identical: no Baking, `nil` document/renderedImage
    /// threaded through, same as before Quick Annotation existed.
    @MainActor
    func testCaptureAreaWithEmptyPayloadNeverBakesAndPublishesNilDocument() async throws {
        let image = try TestImage.solid(width: 8, height: 6, color: .orange)
        let capture = CapturedImage(
            id: UUID(),
            kind: .area,
            title: "Capture",
            createdAt: .now,
            image: image,
            pixelSize: PixelSize(width: 8, height: 6)
        )
        let persistence = RecordingAnnotationPersistence()
        let recorder = CaptureEventRecorder()
        let publisher = StubCapturePublisher(recorder: recorder)
        let pipeline = CapturePipeline(
            capturer: StubScreenshotCapturer(capturedImage: capture),
            persistence: persistence,
            publisher: publisher,
            renderService: StubAnnotationRenderService(renderedImage: image)
        )
        let display = DisplayGeometry(id: 22, frame: CGRect(x: 0, y: 0, width: 100, height: 80), scale: 1)
        let selection = AreaSelection(localRect: CGRect(x: 10, y: 10, width: 20, height: 20), display: display)

        try await pipeline.captureArea(
            selection,
            options: CaptureOptions(),
            payload: PendingAnnotationPayload(items: [])
        )
        try await pipeline.captureArea(selection, options: CaptureOptions(), payload: nil)

        let calls = await persistence.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertNil(calls[0].annotations)
        XCTAssertNil(calls[0].renderedImage)
        XCTAssertNil(calls[1].annotations)
        XCTAssertNil(calls[1].renderedImage)
        XCTAssertEqual(publisher.publications.count, 2)
        XCTAssertNil(publisher.publications[0].document)
        XCTAssertNil(publisher.publications[0].renderedImage)
    }
}

private actor AsyncCaptureGate {
    nonisolated let started = XCTestExpectation(description: "capture operation reached gate")
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started.fulfill()
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class CapturePresentationRecorder {
    private(set) var windowPickerCount = 0

    func presentWindowPicker() {
        windowPickerCount += 1
    }
}

private actor GatedWindowCapturer: ScreenshotCapturing {
    nonisolated let started = XCTestExpectation(description: "window capture started")
    private let image: CapturedImage
    private var continuation: CheckedContinuation<CapturedImage, Never>?

    init(image: CapturedImage) {
        self.image = image
    }

    func sources() async throws -> CaptureSources {
        CaptureSources(displays: [], windows: [])
    }

    func captureArea(
        _ rect: CGRect,
        display: DisplayGeometry,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        image
    }

    func captureDisplay(
        _ displayID: CGDirectDisplayID,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        image
    }

    func captureWindow(
        _ windowID: CGWindowID,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        started.fulfill()
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume(returning: image)
        continuation = nil
    }
}

private actor GatedCommittedCapturePersistence: CapturePersisting {
    nonisolated let committed = XCTestExpectation(description: "capture committed")
    private let rollbackError: Error?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var rolledBackRecordIDs: [UUID] = []

    init(rollbackError: Error? = nil) {
        self.rollbackError = rollbackError
    }

    func persistCapture(_ image: CapturedImage) async throws {
        committed.fulfill()
        await withCheckedContinuation { continuation = $0 }
    }

    func rollbackPersistedCapture(_ outcome: CapturePersistenceOutcome) async throws {
        rolledBackRecordIDs.append(outcome.recordID)
        if let rollbackError { throw rollbackError }
    }

    func returnCommittedOutcome() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RetryableCommittedCapturePersistence: CapturePersisting {
    nonisolated let committed = XCTestExpectation(description: "retryable capture committed")
    private var continuation: CheckedContinuation<Void, Never>?
    private var cleanupIsAllowed = false
    private(set) var hasCommittedCapture = false
    private(set) var rollbackAttempts = 0

    func persistCapture(_ image: CapturedImage) async throws {
        hasCommittedCapture = true
        committed.fulfill()
        await withCheckedContinuation { continuation = $0 }
    }

    func rollbackPersistedCapture(_ outcome: CapturePersistenceOutcome) async throws {
        rollbackAttempts += 1
        guard cleanupIsAllowed else {
            throw CaptureLibraryError.rollbackFailed(
                primary: "cancelled",
                rollback: "cleanup denied"
            )
        }
        hasCommittedCapture = false
    }

    func returnCommittedOutcome() {
        continuation?.resume()
        continuation = nil
    }

    func allowCleanup() {
        cleanupIsAllowed = true
    }
}

private struct EmptyCaptureOCR: OCRRecognizing {
    func recognizeText(in image: CGImage) async throws -> String { "" }
}

private final class FailingCaptureCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var removalIsAllowed = false

    func remove(_ url: URL) throws {
        lock.lock()
        let removalIsAllowed = removalIsAllowed
        lock.unlock()
        guard removalIsAllowed else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: url)
    }

    func allowRemoval() {
        lock.lock()
        removalIsAllowed = true
        lock.unlock()
    }
}

private extension TestImage {
    static func capturedForOperationTest() throws -> CapturedImage {
        let image = try solid(width: 8, height: 6, color: .purple)
        return CapturedImage(
            id: UUID(),
            kind: .window,
            title: "Window",
            createdAt: .now,
            image: image,
            pixelSize: PixelSize(width: 8, height: 6)
        )
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
