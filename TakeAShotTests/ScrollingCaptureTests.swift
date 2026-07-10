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

        var stitcher = try IncrementalImageStitcher(
            firstFrame: first,
            maximumPixelHeight: 1_000
        )
        XCTAssertEqual(stitcher.allocatedPixelHeight, 500)
        try stitcher.append(second, match: match)
        XCTAssertEqual(stitcher.allocatedPixelHeight, 1_000)
        let stitched = try stitcher.finish()
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

    func testFixedTopAndBottomChromeIsKeptOnceAtTheOutputEdges() throws {
        let page = try Self.verticalBands(rowCount: 700, width: 80)
        let first = try Self.frameWithFixedChrome(page: page, contentStart: 0)
        let second = try Self.frameWithFixedChrome(page: page, contentStart: 200)

        let match = try FrameStitcher().match(previous: first, next: second)

        XCTAssertEqual(match.overlapRows, 200, accuracy: 2)
        XCTAssertEqual(match.replacedBottomRows, 50, accuracy: 2)
        var stitcher = try IncrementalImageStitcher(
            firstFrame: first,
            maximumPixelHeight: 1_000
        )
        try stitcher.append(second, match: match)
        XCTAssertEqual(try stitcher.finish().height, 700, accuracy: 2)
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
        var stitcher = try IncrementalImageStitcher(
            firstFrame: first,
            maximumPixelHeight: 700
        )

        XCTAssertThrowsError(try stitcher.append(second, match: match)) { error in
            XCTAssertEqual(error as? ScrollingCaptureError, .pixelLimit)
        }
        XCTAssertEqual(try stitcher.finish().height, 500)
    }

    func testRepeatedContentCompletesCaptureWithoutAppendingDuplicateRows() async throws {
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
            windowID: 42,
            windowFrame: CGRect(x: 10, y: 20, width: 80, height: 500),
            options: CaptureOptions(),
            progress: { _ in }
        )

        guard case .completed(let capture) = result else {
            return XCTFail("Expected a completed capture")
        }
        XCTAssertEqual(capture.kind, .scrolling)
        XCTAssertEqual(capture.pixelSize, PixelSize(width: 80, height: 500))
        XCTAssertEqual(scroller.scrollCount, 1)
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
            windowID: 42,
            windowFrame: CGRect(x: 10, y: 20, width: 80, height: 500),
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
            windowID: 42,
            windowFrame: CGRect(x: 10, y: 20, width: 80, height: 500),
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
            windowID: 42,
            windowFrame: CGRect(x: 10, y: 20, width: 80, height: 500),
            options: CaptureOptions(),
            progress: { _ in }
        )

        guard case .partial(let capture, let reason) = result else {
            return XCTFail("Expected a partial capture")
        }
        XCTAssertEqual(reason, .pixelLimit)
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
            windowID: 42,
            windowFrame: CGRect(x: 10, y: 20, width: 80, height: 500),
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
            windowID: 42,
            windowFrame: CGRect(x: 10, y: 20, width: 80, height: 500),
            options: CaptureOptions(),
            progress: { _ in }
        )

        guard case .partial(_, let reason) = result else {
            return XCTFail("Expected a partial capture")
        }
        XCTAssertEqual(reason, .cancelled)
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
                windowID: 42,
                windowFrame: CGRect(x: 10, y: 20, width: 80, height: 500),
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

        for row in 0..<rowCount {
            let value = CGFloat(row % 251) / 250
            context.setFillColor(
                NSColor(
                    calibratedRed: value,
                    green: 1 - value,
                    blue: CGFloat((row * 17) % 251) / 250,
                    alpha: 1
                ).cgColor
            )
            context.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }
        guard let image = context.makeImage() else { throw TestImageError.imageCreation }
        return image
    }

    private static func frameWithFixedChrome(
        page: CGImage,
        contentStart: Int
    ) throws -> CGImage {
        let width = page.width
        let chromeHeight = 50
        let contentHeight = 400
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

    func scroll(windowFrame: CGRect, deltaY: Int) throws {
        lock.withLock { storedScrollCount += 1 }
    }
}
