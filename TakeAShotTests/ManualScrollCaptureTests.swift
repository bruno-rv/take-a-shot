import AppKit
import XCTest
@testable import TakeAShot

final class ManualScrollCaptureTests: XCTestCase {
    // MARK: - FrameShiftMatcher: signed-shift semantics

    func testShiftDetectsDownwardMotion() throws {
        let document = try Self.verticalBands(rowCount: 900, width: 80)
        let previous = try document.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 300)).unwrapped()
        let next = try document.cropping(to: CGRect(x: 0, y: 50, width: 80, height: 300)).unwrapped()

        let shift = try FrameShiftMatcher().shift(from: previous, to: next)

        XCTAssertEqual(shift, 50)
    }

    func testShiftDetectsUpwardMotion() throws {
        let document = try Self.verticalBands(rowCount: 900, width: 80)
        let previous = try document.cropping(to: CGRect(x: 0, y: 200, width: 80, height: 300)).unwrapped()
        let next = try document.cropping(to: CGRect(x: 0, y: 150, width: 80, height: 300)).unwrapped()

        let shift = try FrameShiftMatcher().shift(from: previous, to: next)

        XCTAssertEqual(shift, -50)
    }

    func testShiftReturnsNilForAmbiguousPeriodicContent() throws {
        let document = try Self.periodicBands(rowCount: 900, width: 80, period: 100)
        let previous = try document.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 500)).unwrapped()
        let next = try document.cropping(to: CGRect(x: 0, y: 250, width: 80, height: 500)).unwrapped()

        let shift = try FrameShiftMatcher().shift(from: previous, to: next)

        XCTAssertNil(shift)
    }

    func testShiftReturnsZeroForInPlaceContentChange() throws {
        let base = try Self.verticalBands(rowCount: 300, width: 80)
        let patched = try Self.withCornerPatch(base, color: .red)

        let shift = try FrameShiftMatcher().shift(from: base, to: patched)

        XCTAssertEqual(shift, 0)
    }

    func testShiftScalesToFullResolutionForFramesTallerThanTheSampleHeight() throws {
        // Height (800) exceeds `maximumSampleHeight` (400, the matcher's default), forcing
        // downsampling; the 800/400 = 2.0 ratio keeps the sample-space shift (300/2 = 150) an
        // exact integer so this isolates the full-resolution *scaling* behavior (PLAN.md round-3
        // finding: a matcher that forgot to scale back up would return ~150, not ~300).
        let document = try Self.verticalBands(rowCount: 1_200, width: 80)
        let previous = try document.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 800)).unwrapped()
        let next = try document.cropping(to: CGRect(x: 0, y: 300, width: 80, height: 800)).unwrapped()

        let shift = try FrameShiftMatcher().shift(from: previous, to: next)

        let unwrapped = try shift.unwrapped()
        XCTAssertEqual(Double(unwrapped), 300, accuracy: 4)
    }

    func testShiftThrowsForMismatchedFrameDimensions() throws {
        let previous = try TestImage.solid(width: 80, height: 300, color: .black)
        let next = try TestImage.solid(width: 60, height: 300, color: .black)

        XCTAssertThrowsError(try FrameShiftMatcher().shift(from: previous, to: next)) { error in
            XCTAssertEqual(error as? ManualScrollCaptureError, .invalidFrame)
        }
    }

    // MARK: - Viewport / extent bookkeeping

    func testReturnAcrossSeedAddsZeroRows() {
        var viewport = ManualScrollViewport(seedHeight: 100, frameHeight: 100)

        let scrolledUp = viewport.apply(shift: -40)
        XCTAssertEqual(scrolledUp.up, -40..<0)
        XCTAssertNil(scrolledUp.down)

        let backToSeed = viewport.apply(shift: 40)
        XCTAssertNil(backToSeed.up)
        XCTAssertNil(backToSeed.down)
        XCTAssertEqual(viewport.extent, -40..<100)
    }

    func testUpThenDownThenUpDedupesAlreadyCapturedRows() {
        var viewport = ManualScrollViewport(seedHeight: 100, frameHeight: 100)

        XCTAssertEqual(viewport.apply(shift: -40).up, -40..<0)
        let backToSeed = viewport.apply(shift: 40)
        XCTAssertNil(backToSeed.up)
        XCTAssertNil(backToSeed.down)
        let revisited = viewport.apply(shift: -40)

        XCTAssertNil(revisited.up)
        XCTAssertNil(revisited.down)
        XCTAssertEqual(viewport.extent, -40..<100)
    }

    // MARK: - Coordinate conversion helper

    func testFrameCropRectConvertsStitchedRangeToFrameLocalTopOrigin() {
        let rect = StitchedRowConversion.frameCropRect(
            stitchedRange: 120..<150,
            frameStitchedTop: 100,
            frameWidth: 80
        )

        XCTAssertEqual(rect, CGRect(x: 0, y: 20, width: 80, height: 30))
    }

    // MARK: - StripStore metadata + composition order

    func testStripStoreRecordsMetadataAndReturnsBytesInAppendOrder() throws {
        let store = try StripStore(width: 80, temporaryDirectory: temporaryDirectory())
        let stripA = try TestImage.solid(width: 80, height: 10, color: .red)
        let stripB = try TestImage.solid(width: 80, height: 20, color: .blue)

        try store.append(stripA, stitchedRange: 0..<10)
        try store.append(stripB, stitchedRange: 10..<30)

        XCTAssertEqual(store.strips.map(\.stitchedRange), [0..<10, 10..<30])
        XCTAssertEqual(store.strips[0].byteOffset, 0)
        XCTAssertEqual(store.strips[0].byteCount, 80 * 10 * 4)
        XCTAssertEqual(store.strips[1].byteOffset, 80 * 10 * 4)
        XCTAssertEqual(try store.data(for: store.strips[0]), try RawPixelFile.rgbaData(for: stripA))
        XCTAssertEqual(try store.data(for: store.strips[1]), try RawPixelFile.rgbaData(for: stripB))
    }

    func testStripStoreCleansUpTemporaryArtifactOnAbandonment() throws {
        var store: StripStore? = try StripStore(width: 80, temporaryDirectory: temporaryDirectory())
        let artifactDirectory = try store.unwrapped().temporaryArtifactDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDirectory.path))

        store = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactDirectory.path))
    }

    // MARK: - Final pixel order (end-to-end composition)

    func testComposesUpReversedSeedAndDownInCorrectTopDownPixelOrder() throws {
        let document = try Self.verticalBands(rowCount: 1_200, width: 80)
        func slice(_ offset: Int) throws -> CGImage {
            try document.cropping(to: CGRect(x: 0, y: offset, width: 80, height: 200)).unwrapped()
        }
        let seed = try slice(500)
        let worker = try ManualScrollCaptureWorker(seed: seed, temporaryDirectory: temporaryDirectory())

        XCTAssertEqual(try worker.process(frame: slice(560)), 60)
        XCTAssertEqual(try worker.process(frame: slice(410)), -150)
        XCTAssertEqual(try worker.process(frame: slice(350)), -60)
        XCTAssertEqual(worker.upStripCount, 2)
        XCTAssertEqual(worker.downStripCount, 1)

        let composed = try worker.compose()

        XCTAssertEqual(composed.width, 80)
        XCTAssertEqual(composed.height, 410)
        let expected = try document.cropping(to: CGRect(x: 0, y: 350, width: 80, height: 410)).unwrapped()
        for row in [0, 59, 60, 149, 150, 349, 350, 409] {
            let actual = try TestImage.pixelColor(in: composed, x: 40, y: row)
            let expectedColor = try TestImage.pixelColor(in: expected, x: 40, y: row)
            XCTAssertEqual(actual.redComponent, expectedColor.redComponent, accuracy: 0.02)
            XCTAssertEqual(actual.greenComponent, expectedColor.greenComponent, accuracy: 0.02)
            XCTAssertEqual(actual.blueComponent, expectedColor.blueComponent, accuracy: 0.02)
        }
        XCTAssertTrue(worker.areStoresCleanedUp)
    }

    func testCancelAndCleanUpRemovesTempFilesWithoutComposing() throws {
        let seed = try TestImage.solid(width: 80, height: 50, color: .black)
        let worker = try ManualScrollCaptureWorker(seed: seed, temporaryDirectory: temporaryDirectory())
        let unrelated = try TestImage.solid(width: 80, height: 50, color: .white)
        _ = try worker.process(frame: unrelated)

        worker.cancelAndCleanUp()

        XCTAssertTrue(worker.areStoresCleanedUp)
    }

    func testInPlaceContentChangeDoesNotReplacePreviousFrameOrGrowExtent() throws {
        let seed = try Self.verticalBands(rowCount: 300, width: 80)
        let patched = try Self.withCornerPatch(seed, color: .red)
        let worker = try ManualScrollCaptureWorker(seed: seed, temporaryDirectory: temporaryDirectory())

        let result = try worker.process(frame: patched)

        XCTAssertEqual(result, 0)
        XCTAssertTrue(worker.previousFrame === seed)
        XCTAssertEqual(worker.viewport.extent, 0..<300)
        XCTAssertEqual(worker.upStripCount, 0)
        XCTAssertEqual(worker.downStripCount, 0)
    }

    // MARK: - Budget accounting (seed counted once)

    func testBudgetReservesSeedExactlyOnceThenAccumulatesAdditionalHeight() throws {
        var budget = ManualScrollBudget(
            maximumPixelHeight: 1_000,
            maximumPixelWidth: 500,
            maximumOutputBytes: 10_000_000
        )

        try budget.reserveSeed(width: 80, height: 50)
        XCTAssertEqual(budget.totalPixelHeight, 50)

        try budget.reserve(additionalHeight: 30)
        XCTAssertEqual(budget.totalPixelHeight, 80)
    }

    func testBudgetThrowsWidthLimitForOversizedSeed() {
        var budget = ManualScrollBudget(maximumPixelWidth: 100)

        XCTAssertThrowsError(try budget.reserveSeed(width: 200, height: 10)) { error in
            XCTAssertEqual(error as? ManualScrollCaptureError, .widthLimit)
        }
    }

    func testBudgetThrowsPixelLimitWhenHeightExceeded() throws {
        var budget = ManualScrollBudget(maximumPixelHeight: 100)
        try budget.reserveSeed(width: 80, height: 80)

        XCTAssertThrowsError(try budget.reserve(additionalHeight: 30)) { error in
            XCTAssertEqual(error as? ManualScrollCaptureError, .pixelLimit)
        }
    }

    func testBudgetThrowsByteLimitWhenBytesExceeded() throws {
        var budget = ManualScrollBudget(maximumPixelHeight: 100_000, maximumOutputBytes: 80 * 50 * 4)
        try budget.reserveSeed(width: 80, height: 50)

        XCTAssertThrowsError(try budget.reserve(additionalHeight: 1)) { error in
            XCTAssertEqual(error as? ManualScrollCaptureError, .byteLimit)
        }
    }

    func testProcessLeavesExtentAndPreviousFrameUncommittedWhenBudgetCapIsHit() throws {
        // Seed reserves 80x50=50 rows; capping the budget at 60 leaves room for a shift smaller
        // than the rejected one below, so a rejected process() must not have grown the extent or
        // advanced previousFrame — otherwise a later compose() would map past the end of a store
        // file that never received the rejected strip (PLAN.md §6 cap-must-stay-composable).
        let seed = try Self.verticalBands(rowCount: 200, width: 80).cropping(
            to: CGRect(x: 0, y: 0, width: 80, height: 50)
        ).unwrapped()
        let budget = ManualScrollBudget(maximumPixelHeight: 60)
        let worker = try ManualScrollCaptureWorker(seed: seed, budget: budget, temporaryDirectory: temporaryDirectory())
        let document = try Self.verticalBands(rowCount: 200, width: 80)
        let next = try document.cropping(to: CGRect(x: 0, y: 30, width: 80, height: 50)).unwrapped()

        XCTAssertThrowsError(try worker.process(frame: next)) { error in
            XCTAssertEqual(error as? ManualScrollCaptureError, .pixelLimit)
        }

        XCTAssertEqual(worker.viewport.extent, 0..<50)
        XCTAssertEqual(worker.budget.totalPixelHeight, 50)
        XCTAssertTrue(worker.previousFrame === seed)
        XCTAssertEqual(worker.downStripCount, 0)

        let composed = try worker.compose()
        XCTAssertEqual(composed.height, 50)
    }

    // MARK: - Unmatched-counter -> degraded

    func testConsecutiveUnmatchedFramesMarkSessionDegradedAtThreshold() throws {
        let seed = try TestImage.solid(width: 80, height: 50, color: .black)
        let worker = try ManualScrollCaptureWorker(seed: seed, temporaryDirectory: temporaryDirectory())
        let unrelated = try TestImage.solid(width: 80, height: 50, color: .white)

        for _ in 0..<(ManualScrollCaptureWorker.unmatchedDegradedThreshold - 1) {
            XCTAssertNil(try worker.process(frame: unrelated))
        }
        XCTAssertFalse(worker.isDegraded)

        XCTAssertNil(try worker.process(frame: unrelated))

        XCTAssertTrue(worker.isDegraded)
        XCTAssertEqual(worker.consecutiveUnmatchedCount, ManualScrollCaptureWorker.unmatchedDegradedThreshold)
        XCTAssertTrue(worker.previousFrame === seed)
    }

    // MARK: - Fixtures

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

        var state: UInt64 = 0x2545_F491_4F6C_DD1D
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

    private static func periodicBands(rowCount: Int, width: Int, period: Int) throws -> CGImage {
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
                : try base.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)).unwrapped()
            context.draw(strip, in: CGRect(x: 0, y: start, width: width, height: height))
        }
        guard let image = context.makeImage() else { throw TestImageError.imageCreation }
        return image
    }

    /// Overlays a small solid patch in one corner of `image` — simulates a spinner/video/cursor
    /// changing pixels without the underlying content actually scrolling.
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
