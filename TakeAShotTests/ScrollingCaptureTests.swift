import AppKit
import XCTest
@testable import TakeAShot

final class ScrollingCaptureTests: XCTestCase {
    func testFindsOverlapAndAppendsOnlyNovelRows() throws {
        let document = try Self.verticalBands(rowCount: 900, width: 80)
        let first = try document.cropping(
            to: CGRect(x: 0, y: 0, width: 80, height: 500)
        ).unwrapped()
        let second = try document.cropping(
            to: CGRect(x: 0, y: 300, width: 80, height: 500)
        ).unwrapped()

        let match = try FrameStitcher().match(previous: first, next: second)

        XCTAssertEqual(match.overlapRows, 200, accuracy: 2)
        XCTAssertEqual(match.novelRows, 300, accuracy: 2)
        XCTAssertGreaterThan(match.confidence, 0.92)

        let temporaryRoot = temporaryDirectory()
        let stitcher = try IncrementalImageStitcher(
            firstFrame: first,
            maximumPixelHeight: 1_000,
            temporaryDirectory: temporaryRoot
        )
        let artifactDirectory = stitcher.temporaryArtifactDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDirectory.path))
        XCTAssertLessThanOrEqual(
            stitcher.peakWorkingAllocationBytes,
            first.width * first.height * 4
        )
        try stitcher.append(second, match: match)
        XCTAssertEqual(stitcher.outputByteCount, 80 * 800 * 4)
        let stitched = try stitcher.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactDirectory.path))
        XCTAssertEqual(stitched.width, 80)
        XCTAssertEqual(stitched.height, 800, accuracy: 2)
        let expected = try document.cropping(
            to: CGRect(x: 0, y: 0, width: 80, height: 800)
        ).unwrapped()
        for row in [0, 199, 499, 500, 799] {
            let actualColor = try TestImage.pixelColor(in: stitched, x: 40, y: row)
            let expectedColor = try TestImage.pixelColor(in: expected, x: 40, y: row)
            XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.02)
            XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.02)
            XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.02)
        }
    }

    func testRepeatedFrameStopsWithoutAddingRows() throws {
        let frame = try Self.verticalBands(rowCount: 500, width: 80)

        let match = try FrameStitcher().match(previous: frame, next: frame)

        XCTAssertEqual(match.overlapRows, 500)
        XCTAssertEqual(match.novelRows, 0)
        XCTAssertGreaterThan(match.confidence, 0.99)
    }

    func testNearBottomSmallAdvanceFindsNinetyFivePercentOverlap() throws {
        let document = try Self.verticalBands(rowCount: 550, width: 80)
        let first = try document.cropping(
            to: CGRect(x: 0, y: 0, width: 80, height: 500)
        ).unwrapped()
        let second = try document.cropping(
            to: CGRect(x: 0, y: 25, width: 80, height: 500)
        ).unwrapped()

        let match = try FrameStitcher().match(previous: first, next: second)

        XCTAssertEqual(match.overlapRows, 475, accuracy: 2)
        XCTAssertEqual(match.novelRows, 25, accuracy: 2)
    }

    func testAmbiguousPeriodicOverlapFailsRatherThanChoosingACompetingPeak() throws {
        let document = try Self.periodicBands(rowCount: 900, width: 80, period: 100)
        let first = try document.cropping(
            to: CGRect(x: 0, y: 0, width: 80, height: 500)
        ).unwrapped()
        let second = try document.cropping(
            to: CGRect(x: 0, y: 250, width: 80, height: 500)
        ).unwrapped()

        XCTAssertThrowsError(try FrameStitcher().match(previous: first, next: second)) { error in
            XCTAssertEqual(error as? ScrollingCaptureError, .lowConfidence)
        }
    }

    func testFixedTopAndBottomChromeIsKeptOnceAtTheOutputEdges() throws {
        let page = try Self.verticalBands(rowCount: 700, width: 80)
        let first = try Self.frameWithFixedChrome(page: page, contentStart: 0)
        let second = try Self.frameWithFixedChrome(page: page, contentStart: 200)

        let match = try FrameStitcher().match(previous: first, next: second)

        XCTAssertEqual(match.overlapRows, 200, accuracy: 2)
        XCTAssertEqual(match.replacedBottomRows, 50, accuracy: 2)
        let stitcher = try IncrementalImageStitcher(
            firstFrame: first,
            maximumPixelHeight: 1_000
        )
        try stitcher.append(second, match: match)
        let stitched = try stitcher.finish()
        let expected = try Self.frameWithFixedChrome(
            page: page,
            contentStart: 0,
            contentHeight: 600
        )
        XCTAssertEqual(stitched.height, 700, accuracy: 2)
        for row in [0, 49, 50, 449, 450, 649, 650, 699] {
            let actualColor = try TestImage.pixelColor(in: stitched, x: 40, y: row)
            let expectedColor = try TestImage.pixelColor(in: expected, x: 40, y: row)
            XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.02)
            XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.02)
            XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.02)
        }
    }

    func testUnrelatedFramesFailWithLowConfidence() throws {
        let black = try TestImage.solid(width: 80, height: 500, color: .black)
        let white = try TestImage.solid(width: 80, height: 500, color: .white)

        XCTAssertThrowsError(try FrameStitcher().match(previous: black, next: white)) { error in
            XCTAssertEqual(error as? ScrollingCaptureError, .lowConfidence)
        }
    }

    func testIncrementalStitcherRejectsOutputBeyondPixelLimit() throws {
        let document = try Self.verticalBands(rowCount: 900, width: 80)
        let first = try document.cropping(
            to: CGRect(x: 0, y: 0, width: 80, height: 500)
        ).unwrapped()
        let second = try document.cropping(
            to: CGRect(x: 0, y: 300, width: 80, height: 500)
        ).unwrapped()
        let match = try FrameStitcher().match(previous: first, next: second)
        let stitcher = try IncrementalImageStitcher(
            firstFrame: first,
            maximumPixelHeight: 700
        )

        XCTAssertThrowsError(try stitcher.append(second, match: match)) { error in
            XCTAssertEqual(error as? ScrollingCaptureError, .pixelLimit)
        }
        XCTAssertEqual(try stitcher.finish().height, 500)
    }

    func testFileBackedStitcherRejectsUnsafeWidthAndByteBudget() throws {
        let frame = try Self.verticalBands(rowCount: 500, width: 80)

        XCTAssertThrowsError(
            try IncrementalImageStitcher(
                firstFrame: frame,
                maximumPixelHeight: 30_000,
                maximumPixelWidth: 79
            )
        ) { error in
            XCTAssertEqual(error as? ScrollingCaptureError, .widthLimit)
        }
        XCTAssertThrowsError(
            try IncrementalImageStitcher(
                firstFrame: frame,
                maximumPixelHeight: 30_000,
                maximumOutputBytes: 159_999
            )
        ) { error in
            XCTAssertEqual(error as? ScrollingCaptureError, .byteLimit)
        }
    }

    func testFileBackedStitcherCleansTemporaryArtifactOnAbandonment() throws {
        let root = temporaryDirectory()
        let frame = try Self.verticalBands(rowCount: 500, width: 80)
        var stitcher: IncrementalImageStitcher? = try IncrementalImageStitcher(
            firstFrame: frame,
            maximumPixelHeight: 1_000,
            temporaryDirectory: root
        )
        let artifactDirectory = try stitcher.map(\.temporaryArtifactDirectory).unwrapped()
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDirectory.path))

        stitcher = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactDirectory.path))
    }

    func testFirstRepeatedFrameReturnsIncompatiblePartialInsteadOfCompletedViewport() async throws {
        let frame = try Self.verticalBands(rowCount: 500, width: 80)
        let capturer = SequenceScreenshotCapturer(frames: [frame, frame])
        let scroller = RecordingWindowScroller()
        let engine = ScrollingCaptureEngine(
            capturer: capturer,
            scroller: scroller,
            settle: {},
            elapsed: { 0 }
        )

        let result = try await engine.capture(
            target: Self.target(),
            options: CaptureOptions(),
            progress: { _ in }
        )

        guard case .partial(let capture, let reason) = result else {
            return XCTFail("Expected an incompatible partial capture")
        }
        XCTAssertEqual(reason, .noScrollProgress)
        XCTAssertEqual(capture.kind, .scrolling)
        XCTAssertEqual(capture.pixelSize, PixelSize(width: 80, height: 500))
        XCTAssertTrue(result.requiresPersistenceConfirmation)
        XCTAssertEqual(scroller.scrollCount, 1)
    }

    func testRepeatAfterAcceptedNovelStripCompletesCapture() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 80)
        let first = try document.cropping(
            to: CGRect(x: 0, y: 0, width: 80, height: 500)
        ).unwrapped()
        let second = try document.cropping(
            to: CGRect(x: 0, y: 300, width: 80, height: 500)
        ).unwrapped()
        let engine = ScrollingCaptureEngine(
            capturer: SequenceScreenshotCapturer(frames: [first, second, second]),
            scroller: RecordingWindowScroller(),
            settle: {},
            elapsed: { 0 }
        )

        let result = try await engine.capture(
            target: Self.target(),
            options: CaptureOptions(),
            progress: { _ in }
        )

        guard case .completed(let capture) = result else {
            return XCTFail("Expected completion after accepted scrolling progress")
        }
        XCTAssertEqual(capture.pixelSize.height, 800)
        XCTAssertFalse(result.requiresPersistenceConfirmation)
    }

    func testLowConfidenceReturnsExplicitPartialCapture() async throws {
        let first = try TestImage.solid(width: 80, height: 500, color: .black)
        let unrelated = try TestImage.solid(width: 80, height: 500, color: .white)
        let engine = ScrollingCaptureEngine(
            capturer: SequenceScreenshotCapturer(frames: [first, unrelated]),
            scroller: RecordingWindowScroller(),
            settle: {},
            elapsed: { 0 }
        )

        let result = try await engine.capture(
            target: Self.target(),
            options: CaptureOptions(),
            progress: { _ in }
        )

        guard case .partial(let capture, let reason) = result else {
            return XCTFail("Expected an explicit partial capture")
        }
        XCTAssertEqual(reason, .lowConfidence)
        XCTAssertEqual(capture.pixelSize.height, 500)
    }

    func testFrameLimitReturnsExplicitPartialBeforeAnotherScroll() async throws {
        let frame = try Self.verticalBands(rowCount: 500, width: 80)
        let scroller = RecordingWindowScroller()
        let engine = ScrollingCaptureEngine(
            capturer: SequenceScreenshotCapturer(frames: [frame]),
            scroller: scroller,
            limits: ScrollingCaptureLimits(
                maximumFrames: 1,
                maximumPixelHeight: 30_000,
                maximumDuration: 60
            ),
            settle: {},
            elapsed: { 0 }
        )

        let result = try await engine.capture(
            target: Self.target(),
            options: CaptureOptions(),
            progress: { _ in }
        )

        guard case .partial(let capture, let reason) = result else {
            return XCTFail("Expected a partial capture")
        }
        XCTAssertEqual(reason, .frameLimit)
        XCTAssertEqual(capture.pixelSize.height, 500)
        XCTAssertEqual(scroller.scrollCount, 0)
    }

    func testPixelLimitReturnsExplicitPartialWithoutAppendingOverflowFrame() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 80)
        let first = try document.cropping(
            to: CGRect(x: 0, y: 0, width: 80, height: 500)
        ).unwrapped()
        let second = try document.cropping(
            to: CGRect(x: 0, y: 300, width: 80, height: 500)
        ).unwrapped()
        let engine = ScrollingCaptureEngine(
            capturer: SequenceScreenshotCapturer(frames: [first, second]),
            scroller: RecordingWindowScroller(),
            limits: ScrollingCaptureLimits(
                maximumFrames: 100,
                maximumPixelHeight: 700,
                maximumDuration: 60
            ),
            settle: {},
            elapsed: { 0 }
        )

        let result = try await engine.capture(
            target: Self.target(),
            options: CaptureOptions(),
            progress: { _ in }
        )

        guard case .partial(let capture, let reason) = result else {
            return XCTFail("Expected a partial capture")
        }
        XCTAssertEqual(reason, .pixelLimit)
        XCTAssertEqual(capture.pixelSize.height, 500)
    }

    func testByteLimitReturnsExplicitPartialWithoutAppendingOverflowFrame() async throws {
        let document = try Self.verticalBands(rowCount: 900, width: 80)
        let first = try document.cropping(
            to: CGRect(x: 0, y: 0, width: 80, height: 500)
        ).unwrapped()
        let second = try document.cropping(
            to: CGRect(x: 0, y: 300, width: 80, height: 500)
        ).unwrapped()
        let engine = ScrollingCaptureEngine(
            capturer: SequenceScreenshotCapturer(frames: [first, second]),
            scroller: RecordingWindowScroller(),
            limits: ScrollingCaptureLimits(maximumOutputBytes: 200_000),
            settle: {},
            elapsed: { 0 }
        )

        let result = try await engine.capture(
            target: Self.target(),
            options: CaptureOptions(),
            progress: { _ in }
        )

        guard case .partial(let capture, let reason) = result else {
            return XCTFail("Expected a byte-limited partial capture")
        }
        XCTAssertEqual(reason, .byteLimit)
        XCTAssertEqual(capture.pixelSize.height, 500)
    }

    func testDurationLimitReturnsExplicitPartial() async throws {
        let frame = try Self.verticalBands(rowCount: 500, width: 80)
        let engine = ScrollingCaptureEngine(
            capturer: SequenceScreenshotCapturer(frames: [frame]),
            scroller: RecordingWindowScroller(),
            limits: ScrollingCaptureLimits(
                maximumFrames: 100,
                maximumPixelHeight: 30_000,
                maximumDuration: 60
            ),
            settle: {},
            elapsed: { 60 }
        )

        let result = try await engine.capture(
            target: Self.target(),
            options: CaptureOptions(),
            progress: { _ in }
        )

        guard case .partial(_, let reason) = result else {
            return XCTFail("Expected a partial capture")
        }
        XCTAssertEqual(reason, .durationLimit)
    }

    func testCancellationDuringSettleReturnsExplicitPartial() async throws {
        let frame = try Self.verticalBands(rowCount: 500, width: 80)
        let engine = ScrollingCaptureEngine(
            capturer: SequenceScreenshotCapturer(frames: [frame]),
            scroller: RecordingWindowScroller(),
            settle: { throw CancellationError() },
            elapsed: { 0 }
        )

        let result = try await engine.capture(
            target: Self.target(),
            options: CaptureOptions(),
            progress: { _ in }
        )

        guard case .partial(_, let reason) = result else {
            return XCTFail("Expected a partial capture")
        }
        XCTAssertEqual(reason, .cancelled)
    }

    func testCancellationFromSubsequentCaptureReturnsExistingPartialAndCleansTempFile() async throws {
        let root = temporaryDirectory()
        let frame = try Self.verticalBands(rowCount: 500, width: 80)
        let engine = ScrollingCaptureEngine(
            capturer: CancellingAfterFirstFrameCapturer(frame: frame),
            scroller: RecordingWindowScroller(),
            temporaryDirectory: root,
            settle: {},
            elapsed: { 0 }
        )

        let result = try await engine.capture(
            target: Self.target(),
            options: CaptureOptions(),
            progress: { _ in }
        )

        guard case .partial(let capture, let reason) = result else {
            return XCTFail("Expected the already captured viewport as a partial")
        }
        XCTAssertEqual(reason, .cancelled)
        XCTAssertEqual(capture.pixelSize.height, 500)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            []
        )
    }

    func testScrollerRefusesEventWhenSelectedWindowIsNotVerifiedTopmostAtFreshCenter() throws {
        let refreshedFrame = CGRect(x: 400, y: 300, width: 200, height: 160)
        let targeting = StubWindowTargeting(
            refreshedFrame: refreshedFrame,
            isSelectedWindowTopmost: false
        )
        let eventPoster = RecordingScrollEventPoster()
        let scroller = AccessibilityWindowScroller(
            targeting: targeting,
            eventPoster: eventPoster
        )

        XCTAssertThrowsError(
            try scroller.scroll(target: Self.target(), deltaY: -300)
        ) { error in
            XCTAssertEqual(error as? ScrollingCaptureError, .targetUnavailable)
        }
        XCTAssertEqual(targeting.requestedWindowIDs, [42])
        XCTAssertTrue(eventPoster.events.isEmpty)
    }

    func testScrollerUsesRefreshedVerifiedTargetFrameForEventLocation() throws {
        let refreshedFrame = CGRect(x: 400, y: 300, width: 200, height: 160)
        let targeting = StubWindowTargeting(
            refreshedFrame: refreshedFrame,
            isSelectedWindowTopmost: true
        )
        let eventPoster = RecordingScrollEventPoster()
        let scroller = AccessibilityWindowScroller(
            targeting: targeting,
            eventPoster: eventPoster
        )

        let refreshedTarget = try scroller.scroll(
            target: Self.target(),
            deltaY: -300
        )

        XCTAssertEqual(refreshedTarget.frame, refreshedFrame)
        XCTAssertEqual(
            eventPoster.events,
            [ScrollEventRequest(location: CGPoint(x: 500, y: 380), deltaY: -300)]
        )
    }

    func testAccessibilityDenialFailsBeforeCapturing() async throws {
        let frame = try Self.verticalBands(rowCount: 500, width: 80)
        let capturer = SequenceScreenshotCapturer(frames: [frame])
        let engine = ScrollingCaptureEngine(
            capturer: capturer,
            scroller: RecordingWindowScroller(trusted: false),
            settle: {},
            elapsed: { 0 }
        )

        do {
            _ = try await engine.capture(
                target: Self.target(),
                options: CaptureOptions(),
                progress: { _ in }
            )
            XCTFail("Expected Accessibility denial")
        } catch {
            XCTAssertEqual(error as? ScrollingCaptureError, .accessibilityDenied)
        }
        let captureCount = await capturer.captureCount
        XCTAssertEqual(captureCount, 0)
    }

    private static func verticalBands(rowCount: Int, width: Int) throws -> CGImage {
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

        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for row in 0..<rowCount {
            state ^= UInt64(row) &+ 0x9E37_79B9_7F4A_7C15
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

    private static func periodicBands(
        rowCount: Int,
        width: Int,
        period: Int
    ) throws -> CGImage {
        let base = try verticalBands(rowCount: period, width: width)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: rowCount,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestImageError.contextCreation }
        for start in stride(from: 0, to: rowCount, by: period) {
            let height = min(period, rowCount - start)
            let strip = height == period
                ? base
                : try base.cropping(
                    to: CGRect(x: 0, y: 0, width: width, height: height)
                ).unwrapped()
            context.draw(
                strip,
                in: CGRect(x: 0, y: start, width: width, height: height)
            )
        }
        guard let image = context.makeImage() else { throw TestImageError.imageCreation }
        return image
    }

    private static func frameWithFixedChrome(
        page: CGImage,
        contentStart: Int,
        contentHeight: Int = 400
    ) throws -> CGImage {
        let width = page.width
        let chromeHeight = 50
        guard
            let content = page.cropping(
                to: CGRect(
                    x: 0,
                    y: contentStart,
                    width: width,
                    height: contentHeight
                )
            ),
            let context = CGContext(
                data: nil,
                width: width,
                height: contentHeight + chromeHeight * 2,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw TestImageError.contextCreation }

        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: chromeHeight))
        context.draw(
            content,
            in: CGRect(
                x: 0,
                y: chromeHeight,
                width: width,
                height: contentHeight
            )
        )
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(
            CGRect(
                x: 0,
                y: chromeHeight + contentHeight,
                width: width,
                height: chromeHeight
            )
        )
        guard let image = context.makeImage() else { throw TestImageError.imageCreation }
        return image
    }

    private static func target() -> ScrollingWindowTarget {
        ScrollingWindowTarget(
            windowID: 42,
            title: "Window",
            frame: CGRect(x: 10, y: 20, width: 80, height: 500)
        )
    }
}

private actor SequenceScreenshotCapturer: ScreenshotCapturing {
    private let frames: [CGImage]
    private var index = 0

    init(frames: [CGImage]) {
        self.frames = frames
    }

    var captureCount: Int { index }

    func sources() async throws -> CaptureSources {
        CaptureSources(displays: [], windows: [])
    }

    func captureArea(
        _ rect: CGRect,
        display: DisplayGeometry,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        throw CaptureError.captureFailed("Unexpected area capture")
    }

    func captureDisplay(
        _ displayID: CGDirectDisplayID,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        throw CaptureError.captureFailed("Unexpected display capture")
    }

    func captureWindow(
        _ windowID: CGWindowID,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        guard index < frames.count else {
            throw CaptureError.captureFailed("No more frames")
        }
        let image = frames[index]
        index += 1
        return CapturedImage(
            id: UUID(),
            kind: .window,
            title: "Window",
            createdAt: .now,
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height)
        )
    }
}

private actor CancellingAfterFirstFrameCapturer: ScreenshotCapturing {
    private let frame: CGImage
    private var captureCount = 0

    init(frame: CGImage) {
        self.frame = frame
    }

    func sources() async throws -> CaptureSources {
        CaptureSources(displays: [], windows: [])
    }

    func captureArea(
        _ rect: CGRect,
        display: DisplayGeometry,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        throw CaptureError.captureFailed("Unexpected area capture")
    }

    func captureDisplay(
        _ displayID: CGDirectDisplayID,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        throw CaptureError.captureFailed("Unexpected display capture")
    }

    func captureWindow(
        _ windowID: CGWindowID,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        captureCount += 1
        guard captureCount == 1 else { throw CancellationError() }
        return CapturedImage(
            id: UUID(),
            kind: .window,
            title: "Window",
            createdAt: .now,
            image: frame,
            pixelSize: PixelSize(width: frame.width, height: frame.height)
        )
    }
}

private final class StubWindowTargeting: WindowTargeting, @unchecked Sendable {
    private let lock = NSLock()
    private let refreshedFrame: CGRect
    private let isSelectedWindowTopmost: Bool
    private var storedWindowIDs: [CGWindowID] = []

    init(refreshedFrame: CGRect, isSelectedWindowTopmost: Bool) {
        self.refreshedFrame = refreshedFrame
        self.isSelectedWindowTopmost = isSelectedWindowTopmost
    }

    var requestedWindowIDs: [CGWindowID] {
        lock.withLock { storedWindowIDs }
    }

    func raiseAndResolveFrame(for target: ScrollingWindowTarget) throws -> CGRect {
        lock.withLock { storedWindowIDs.append(target.windowID) }
        return refreshedFrame
    }

    func isTopmost(windowID: CGWindowID, at point: CGPoint) -> Bool {
        isSelectedWindowTopmost
    }
}

private final class RecordingScrollEventPoster: ScrollEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [ScrollEventRequest] = []

    var events: [ScrollEventRequest] {
        lock.withLock { storedEvents }
    }

    func post(_ request: ScrollEventRequest) throws {
        lock.withLock { storedEvents.append(request) }
    }
}

private final class RecordingWindowScroller: WindowScrolling, @unchecked Sendable {
    private let lock = NSLock()
    private let trusted: Bool
    private var storedScrollCount = 0

    init(trusted: Bool = true) {
        self.trusted = trusted
    }

    var scrollCount: Int {
        lock.withLock { storedScrollCount }
    }

    func isTrusted(prompt: Bool) -> Bool {
        trusted
    }

    func prepare(target: ScrollingWindowTarget) throws -> ScrollingWindowTarget {
        target
    }

    func scroll(
        target: ScrollingWindowTarget,
        deltaY: Int
    ) throws -> ScrollingWindowTarget {
        lock.withLock { storedScrollCount += 1 }
        return target
    }
}
