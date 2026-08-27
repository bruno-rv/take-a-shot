import AppKit
import XCTest
@testable import TakeAShot

final class ManualScrollSessionTests: XCTestCase {
    // MARK: - AppKit ↔ Quartz coordinate conversion (PLAN.md §3.1)

    func testQuartzPointFlipsAboutPrimaryScreenHeight() {
        let point = ManualScrollCoordinateConversion.quartzPoint(
            fromAppKitPoint: CGPoint(x: 100, y: 50),
            primaryScreenHeight: 900
        )
        XCTAssertEqual(point, CGPoint(x: 100, y: 850))
    }

    func testQuartzRectFlipsTopEdgeToOrigin() {
        let rect = ManualScrollCoordinateConversion.quartzRect(
            fromAppKitRect: CGRect(x: 10, y: 100, width: 200, height: 50),
            primaryScreenHeight: 900
        )
        // AppKit rect spans y in [100, 150); its top (maxY = 150) becomes the Quartz origin.
        XCTAssertEqual(rect, CGRect(x: 10, y: 750, width: 200, height: 50))
    }

    // MARK: - Engine: unchanged / in-place / matched-shift / dropped-unmatched

    func testTickSkipsAPixelIdenticalFrameAsUnchanged() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let frames = ScriptedFrames([seed])
        let engine = try ManualScrollCaptureEngine(seed: seed, frameProvider: frames.next)

        let result = await engine.tick()

        XCTAssertEqual(result.outcome, .unchanged)
        XCTAssertEqual(result.stitchedHeight, 300)
    }

    func testTickMatchesDownwardScrollAndGrowsExtent() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let scrolled = try Self.crop(document, y: 50, height: 300)
        let frames = ScriptedFrames([scrolled])
        let engine = try ManualScrollCaptureEngine(seed: seed, frameProvider: frames.next)

        let result = await engine.tick()

        XCTAssertEqual(result.outcome, .matched(shift: 50))
        XCTAssertEqual(result.stitchedHeight, 350)
    }

    func testTickMatchesUpwardScrollAndGrowsExtentAbove() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 200, height: 300)
        let scrolled = try Self.crop(document, y: 150, height: 300)
        let frames = ScriptedFrames([scrolled])
        let engine = try ManualScrollCaptureEngine(seed: seed, frameProvider: frames.next)

        let result = await engine.tick()

        XCTAssertEqual(result.outcome, .matched(shift: -50))
        XCTAssertEqual(result.stitchedHeight, 350)
    }

    func testTickReportsInPlaceForAnUnscrolledContentChangeAndDoesNotGrowExtent() async throws {
        let document = try Self.verticalBands(rowCount: 300, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let patched = try Self.withCornerPatch(seed, color: .red)
        let frames = ScriptedFrames([patched])
        let engine = try ManualScrollCaptureEngine(seed: seed, frameProvider: frames.next)

        let result = await engine.tick()

        XCTAssertEqual(result.outcome, .inPlace)
        XCTAssertEqual(result.stitchedHeight, 300)
    }

    func testTickDropsAnUnmatchableChangedFrameWithoutGrowingExtent() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let unrelated = try Self.verticalBands(rowCount: 300, width: 40, seed: 0xDEAD_BEEF)
        let frames = ScriptedFrames([unrelated])
        let engine = try ManualScrollCaptureEngine(seed: seed, frameProvider: frames.next)

        let result = await engine.tick()

        XCTAssertEqual(result.outcome, .droppedUnmatched)
        XCTAssertEqual(result.stitchedHeight, 300)
        XCTAssertFalse(result.isDegraded)
    }

    func testTwentyConsecutiveUnmatchedFramesMarkTheSessionDegraded() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let unrelated = try Self.verticalBands(rowCount: 300, width: 40, seed: 0xDEAD_BEEF)
        let frames = ScriptedFrames(Array(repeating: unrelated, count: 20))
        let engine = try ManualScrollCaptureEngine(seed: seed, frameProvider: frames.next)

        var lastResult: ManualScrollTickResult!
        for _ in 0..<20 {
            lastResult = await engine.tick()
        }

        XCTAssertEqual(lastResult.outcome, .droppedUnmatched)
        XCTAssertTrue(lastResult.isDegraded)
    }

    // MARK: - Duration / budget caps auto-finish the session

    func testTickReportsDurationExceededOnceThePerSessionCapIsPassed() async throws {
        let document = try Self.verticalBands(rowCount: 300, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let clock = ClockBox(value: 1_000)
        let engine = try ManualScrollCaptureEngine(
            seed: seed,
            frameProvider: { seed },
            elapsed: { clock.value }
        )
        clock.value = 1_000 + ManualScrollCaptureEngine.maximumDuration + 1

        let result = await engine.tick()

        XCTAssertEqual(result.outcome, .durationExceeded)
    }

    func testTickReportsBudgetExceededWhenAShiftWouldPassThePixelHeightCap() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let scrolled = try Self.crop(document, y: 50, height: 300)
        let frames = ScriptedFrames([scrolled])
        let tightBudget = ManualScrollBudget(maximumPixelHeight: 320)
        let engine = try ManualScrollCaptureEngine(
            seed: seed,
            frameProvider: frames.next,
            budget: tightBudget
        )

        let result = await engine.tick()

        XCTAssertEqual(result.outcome, .budgetExceeded(.pixelLimit))
    }

    // MARK: - Mid-session target monitoring (pause / resume)

    func testMidSessionMonitoringPausesOnInvalidationAndResumeReresolvesTheTarget() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let resolver = FakeManualScrollTargetResolver(
            existsResults: [false],
            topmostResult: ManualScrollTarget(
                windowID: 99, ownerProcessIdentifier: 1, ownerBundleIdentifier: nil, frame: .zero
            )
        )
        let frames = ScriptedFrames(Array(repeating: seed, count: 10))
        let engine = try ManualScrollCaptureEngine(
            seed: seed,
            frameProvider: frames.next,
            targetResolver: resolver,
            monitoringWindowID: 42,
            quartzCaptureRect: .zero
        )

        var lastResult: ManualScrollTickResult!
        for _ in 1...7 {
            lastResult = await engine.tick()
        }
        XCTAssertEqual(lastResult.outcome, .invalidated)

        let stillPaused = await engine.tick()
        XCTAssertEqual(stillPaused.outcome, .paused)

        let resumed = await engine.resume(reresolvingAt: .zero)
        XCTAssertTrue(resumed)

        let afterResume = await engine.tick()
        XCTAssertNotEqual(afterResume.outcome, .paused)
        XCTAssertNotEqual(afterResume.outcome, .invalidated)
    }

    func testResumeSkipsOurOwnWindowsWhenReresolvingTheTarget() async throws {
        // The session's border window sits at `.screenSaver` level over the whole capture rect, so
        // it is genuinely the frontmost window under the capture center during a pause. Resume must
        // apply the same own-bundle exclusion Confirm-time resolution uses, or monitoring latches
        // onto our own window and never trips again.
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let ownBundle = "com.bruno.takeashot"
        let resolver = FakeManualScrollTargetResolver(
            existsResults: [false],
            windows: [
                ManualScrollTarget(
                    windowID: 500,
                    ownerProcessIdentifier: 2,
                    ownerBundleIdentifier: ownBundle,
                    frame: .zero
                ),
                ManualScrollTarget(
                    windowID: 7,
                    ownerProcessIdentifier: 3,
                    ownerBundleIdentifier: "com.example.browser",
                    frame: .zero
                )
            ]
        )
        let frames = ScriptedFrames(Array(repeating: seed, count: 10))
        let engine = try ManualScrollCaptureEngine(
            seed: seed,
            frameProvider: frames.next,
            targetResolver: resolver,
            monitoringWindowID: 42,
            quartzCaptureRect: .zero,
            ownBundleIdentifier: ownBundle
        )
        for _ in 1...7 { _ = await engine.tick() }

        let resumed = await engine.resume(reresolvingAt: .zero)

        XCTAssertTrue(resumed)
        let monitored = await engine.monitoringWindowID
        XCTAssertEqual(monitored, 7)
    }

    func testResumeFailsAndStaysPausedWhenNoTargetReresolves() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let resolver = FakeManualScrollTargetResolver(existsResults: [false], topmostResult: nil)
        let frames = ScriptedFrames(Array(repeating: seed, count: 10))
        let engine = try ManualScrollCaptureEngine(
            seed: seed,
            frameProvider: frames.next,
            targetResolver: resolver,
            monitoringWindowID: 42,
            quartzCaptureRect: .zero
        )
        for _ in 1...7 { _ = await engine.tick() }

        let resumed = await engine.resume(reresolvingAt: .zero)

        XCTAssertFalse(resumed)
        let stillPaused = await engine.tick()
        XCTAssertEqual(stillPaused.outcome, .paused)
    }

    func testMonitoringIsDisabledWhenNoTargetWasResolvableAtConfirm() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        // No `targetResolver` supplied at all — mirrors the fallback path where Confirm found no
        // window under the selection center (PLAN.md §4: "monitor disabled").
        let frames = ScriptedFrames(Array(repeating: seed, count: 8))
        let engine = try ManualScrollCaptureEngine(seed: seed, frameProvider: frames.next)

        var results: [ManualScrollTickOutcome] = []
        for _ in 1...8 { results.append(await engine.tick().outcome) }

        XCTAssertFalse(results.contains(.invalidated))
        XCTAssertFalse(results.contains(.paused))
    }

    // MARK: - Frame-capture failure policy

    func testIsolatedCaptureFailuresReportFailureWithoutDegradingTheSession() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        // One short of the limit, then a good frame — the counter resets, so a second run of
        // failures the same length still never reaches the limit.
        let belowLimit = ManualScrollCaptureEngine.captureFailureLimit - 1
        let outcomes: [CGImage?] = Array(repeating: nil, count: belowLimit)
            + [seed]
            + Array(repeating: nil, count: belowLimit)
        let frames = FlakyFrames(outcomes)
        let engine = try ManualScrollCaptureEngine(seed: seed, frameProvider: frames.next)

        var results: [ManualScrollTickResult] = []
        for _ in 1...outcomes.count { results.append(await engine.tick()) }

        XCTAssertFalse(results.contains { $0.outcome == .captureFailureLimitReached })
        XCTAssertFalse(results.contains { $0.isDegraded })
        XCTAssertEqual(results.filter { $0.outcome == .captureFailed }.count, belowLimit * 2)
    }

    func testSustainedCaptureFailureReachesTheLimitAndDegradesTheSession() async throws {
        // Permission revoked mid-session: every frame fails from here on. The session must stop
        // reporting a clean run so `finish()` takes the partial path instead of `.completed`.
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let frames = FlakyFrames([])
        let engine = try ManualScrollCaptureEngine(seed: seed, frameProvider: frames.next)

        var results: [ManualScrollTickResult] = []
        for _ in 1...ManualScrollCaptureEngine.captureFailureLimit {
            results.append(await engine.tick())
        }

        XCTAssertEqual(results.last?.outcome, .captureFailureLimitReached)
        XCTAssertEqual(results.last?.isDegraded, true)
        // Degradation is sticky, exactly like the worker's unmatched-frame degradation.
        let afterwards = await engine.tick()
        XCTAssertTrue(afterwards.isDegraded)
    }

    // MARK: - HUD notice

    func testCaptureFailureNoticeClearsOnceFramesFlowAgain() {
        let afterFailure = ManualScrollHUDState.notice(after: .captureFailed, current: nil)
        XCTAssertEqual(afterFailure, ManualScrollHUDState.captureFailureNotice)

        // A transient failure must not pin "Not receiving frames" on the HUD for the rest of the
        // session — the next frame that lands takes it back down.
        XCTAssertNil(ManualScrollHUDState.notice(after: .matched(shift: 12), current: afterFailure))
        XCTAssertNil(ManualScrollHUDState.notice(after: .unchanged, current: afterFailure))
        XCTAssertNil(ManualScrollHUDState.notice(after: .inPlace, current: afterFailure))
        XCTAssertNil(ManualScrollHUDState.notice(after: .droppedUnmatched, current: afterFailure))
    }

    func testTicksLeaveNoticesSetOutsideTheTickLoopAlone() {
        let focusNotice = "Target changed — click the content to focus"
        let shortcutNotice = "Shortcut unavailable — use the HUD buttons"

        XCTAssertEqual(ManualScrollHUDState.notice(after: .matched(shift: 8), current: focusNotice), focusNotice)
        XCTAssertEqual(ManualScrollHUDState.notice(after: .unchanged, current: focusNotice), focusNotice)
        XCTAssertEqual(ManualScrollHUDState.notice(after: .paused, current: focusNotice), focusNotice)
        XCTAssertEqual(ManualScrollHUDState.notice(after: .captureFailed, current: focusNotice), focusNotice)
        XCTAssertEqual(ManualScrollHUDState.notice(after: .captureFailed, current: shortcutNotice), shortcutNotice)
    }

    func testTransientCaptureFailureCannotEraseAnExistingActionableNotice() {
        let focusNotice = "Target changed — click the content to focus"

        // A transient failure must not replace the focus notice.
        XCTAssertEqual(
            ManualScrollHUDState.notice(after: .captureFailed, current: focusNotice),
            focusNotice
        )
        // The next successful tick must still show the unresolved focus notice.
        XCTAssertEqual(
            ManualScrollHUDState.notice(after: .matched(shift: 12), current: focusNotice),
            focusNotice
        )
    }

    func testPausedTicksKeepTheInvalidationNoticeOnScreen() {
        let invalidated = ManualScrollHUDState.notice(after: .invalidated, current: nil)
        XCTAssertEqual(invalidated, ManualScrollHUDState.contentChangedNotice)
        // Invalidation pauses the engine, so every tick until Resume comes back `.paused`.
        XCTAssertEqual(ManualScrollHUDState.notice(after: .paused, current: invalidated), invalidated)
    }

    // MARK: - Compose

    func testComposeWithOnlySeedFrameReturnsASingleFrameSizedImage() async throws {
        let document = try Self.verticalBands(rowCount: 300, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let engine = try ManualScrollCaptureEngine(seed: seed, frameProvider: { seed })

        let composed = try await engine.compose()

        XCTAssertEqual(composed.width, 40)
        XCTAssertEqual(composed.height, 300)
    }

    func testComposeAfterAnAwaitedMatchedTickIncludesThatTicksStrip() async throws {
        // Mirrors the session controller's real drain sequencing (PLAN.md §7): `compose()` is only
        // ever called after the in-flight `tick()` call has fully returned, never concurrently with
        // it — so awaiting `tick()` to completion before calling `compose()` is the whole guarantee.
        let document = try Self.verticalBands(rowCount: 900, width: 40)
        let seed = try Self.crop(document, y: 0, height: 300)
        let scrolled = try Self.crop(document, y: 50, height: 300)
        let engine = try ManualScrollCaptureEngine(seed: seed, frameProvider: { scrolled })

        let tickResult = await engine.tick()
        XCTAssertEqual(tickResult.outcome, .matched(shift: 50))
        let composed = try await engine.compose()

        XCTAssertEqual(composed.height, 350)
    }

    // MARK: - Wiring

    @MainActor
    func testRecordingIntentHandlerRecordsManualScrollIntent() {
        let handler = RecordingCaptureIntentHandler()

        handler.beginManualScrollCapture(options: CaptureOptions())

        XCTAssertEqual(handler.intents, [.scrollingAreaSelection])
    }

    @MainActor
    func testManualScrollOverlayHidesTheQuickAnnotationToolbarButAreaOverlayShowsIt() {
        let display = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1)

        let manualView = SelectionOverlayView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            display: display,
            snapshot: nil,
            allowsQuickAnnotation: false
        )
        Self.commitDrag(on: manualView, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 240, y: 200))
        XCTAssertFalse(manualView.isQuickAnnotationToolbarVisible)

        let areaView = SelectionOverlayView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            display: display,
            snapshot: nil
        )
        Self.commitDrag(on: areaView, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 240, y: 200))
        XCTAssertTrue(areaView.isQuickAnnotationToolbarVisible)
    }

    // MARK: - Test fixtures

    @MainActor
    private static func commitDrag(on view: SelectionOverlayView, from start: CGPoint, to end: CGPoint) {
        view.mouseDown(with: Self.mouseEvent(.leftMouseDown, at: start))
        view.mouseDragged(with: Self.mouseEvent(.leftMouseDragged, at: end))
        view.mouseUp(with: Self.mouseEvent(.leftMouseUp, at: end))
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private static func crop(_ image: CGImage, y: Int, height: Int) throws -> CGImage {
        try image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)).unwrapped()
    }

    private static func verticalBands(rowCount: Int, width: Int, seed: UInt64 = 0x2545_F491_4F6C_DD1D) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: rowCount,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestImageError.contextCreation }

        var state = seed
        for row in 0..<rowCount {
            state ^= UInt64(row) &+ 0x2545_F491_4F6C_DD1D
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            context.setFillColor(
                NSColor(
                    calibratedRed: CGFloat(state & 0xFF) / 255,
                    green: CGFloat((state >> 8) & 0xFF) / 255,
                    blue: CGFloat((state >> 16) & 0xFF) / 255,
                    alpha: 1
                ).cgColor
            )
            context.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }
        guard let image = context.makeImage() else { throw TestImageError.imageCreation }
        return image
    }

    /// Overlays a small solid patch in one corner — simulates a spinner/video/cursor changing
    /// pixels without the underlying content actually scrolling.
    private static func withCornerPatch(_ image: CGImage, color: NSColor) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestImageError.contextCreation }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: min(10, image.width), height: min(10, image.height)))
        guard let patched = context.makeImage() else { throw TestImageError.imageCreation }
        return patched
    }
}

/// Hands out a scripted sequence of frames, one per call — an actor so it is safely callable from
/// the engine actor's `@Sendable` `frameProvider` closure.
private actor ScriptedFrames {
    private var frames: [CGImage]
    private var index = 0

    init(_ frames: [CGImage]) {
        self.frames = frames
    }

    func next() async throws -> CGImage {
        guard index < frames.count else { throw TestCaptureError.persistence }
        defer { index += 1 }
        return frames[index]
    }
}

/// Scripted frame provider where a `nil` entry (and running off the end) throws — drives the
/// engine's consecutive-capture-failure policy.
private actor FlakyFrames {
    private var outcomes: [CGImage?]
    private var index = 0

    init(_ outcomes: [CGImage?]) {
        self.outcomes = outcomes
    }

    func next() async throws -> CGImage {
        guard index < outcomes.count, let frame = outcomes[index] else {
            index += 1
            throw TestCaptureError.persistence
        }
        index += 1
        return frame
    }
}

private final class ClockBox: @unchecked Sendable {
    var value: TimeInterval
    init(value: TimeInterval) { self.value = value }
}

/// Fake `ManualScrollTargetResolving` with scripted `windowExists` results (consumed in order,
/// one per call — matches the once-per-monitor-tick call cadence) and a front-to-back window list
/// for `resume(reresolvingAt:)`. `topmostWindow` applies the same own-bundle filter the system
/// resolver does, so a caller that forgets to pass the exclusion fails a test instead of silently
/// adopting one of our own windows.
private final class FakeManualScrollTargetResolver: ManualScrollTargetResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var existsResults: [Bool]
    private let windows: [ManualScrollTarget]

    convenience init(existsResults: [Bool], topmostResult: ManualScrollTarget?) {
        self.init(existsResults: existsResults, windows: topmostResult.map { [$0] } ?? [])
    }

    init(existsResults: [Bool], windows: [ManualScrollTarget]) {
        self.existsResults = existsResults
        self.windows = windows
    }

    func topmostWindow(at quartzPoint: CGPoint, excludingBundleIdentifier: String?) -> ManualScrollTarget? {
        windows.first { window in
            guard let excludingBundleIdentifier else { return true }
            return window.ownerBundleIdentifier != excludingBundleIdentifier
        }
    }

    func windowExists(_ windowID: CGWindowID, intersecting quartzRect: CGRect?) -> Bool {
        lock.withLock {
            guard !existsResults.isEmpty else { return true }
            return existsResults.removeFirst()
        }
    }
}
