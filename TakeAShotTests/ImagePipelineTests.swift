import AppKit
import ImageIO
import XCTest
@testable import TakeAShot

final class ImagePipelineTests: XCTestCase {
    func testAtomicMediaCopyReplacesExistingApprovedDestination() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let destination = root.appendingPathComponent("destination.mp4")
        try Data("new-media".utf8).write(to: source)
        try Data("old-media".utf8).write(to: destination)

        try AtomicMediaFileCopy.copyReplacing(source: source, destination: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("new-media".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("new-media".utf8))
    }
    func testPNGEncodingPreservesPixelDimensions() throws {
        let source = try TestImage.solid(width: 40, height: 30, color: .white)

        let data = try ImageExporter.pngData(for: source)

        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 40)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 30)
    }

    func testJPEGQualityIsClampedToValidBounds() throws {
        let source = try TestImage.verticalSplit(
            width: 40,
            height: 30,
            leftColor: .black,
            rightColor: .white
        )

        let belowMinimum = try ImageExporter.jpegData(for: source, quality: -1)
        let minimum = try ImageExporter.jpegData(for: source, quality: 0)
        let maximum = try ImageExporter.jpegData(for: source, quality: 1)
        let aboveMaximum = try ImageExporter.jpegData(for: source, quality: 2)

        XCTAssertEqual(belowMinimum, minimum)
        XCTAssertEqual(aboveMaximum, maximum)
    }

    func testWritePersistsEncodedData() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("capture.png")
        let data = Data([0x01, 0x02, 0x03])

        try ImageExporter.write(data, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    func testArrowRenderingChangesSamplePixel() throws {
        let source = try TestImage.solid(width: 100, height: 60, color: .white)
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .arrow(.init(
                    id: UUID(),
                    start: .init(x: 0.2, y: 0.5),
                    end: .init(x: 0.8, y: 0.5),
                    color: .red,
                    strokeWidth: 6
                )),
            ]
        )

        let rendered = try AnnotationRenderer().render(source: source, document: document)
        let sample = try TestImage.pixelColor(in: rendered, x: 50, y: 30)

        XCTAssertGreaterThan(sample.redComponent, 0.8)
        XCTAssertLessThan(sample.greenComponent, 0.2)
        XCTAssertLessThan(sample.blueComponent, 0.2)
    }

    func testTextRenderingChangesPixelsInsideImage() throws {
        let source = try TestImage.solid(width: 120, height: 60, color: .white)
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .text(.init(
                    id: UUID(),
                    bounds: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                    text: "A",
                    fontSize: 32,
                    color: .red
                )),
            ]
        )

        let rendered = try AnnotationRenderer().render(source: source, document: document)

        XCTAssertTrue(TestImage.containsPixel(in: rendered) { color in
            color.redComponent > 0.8 && color.greenComponent < 0.8 && color.blueComponent < 0.8
        })
    }

    func testEmojiAnnotationRendersAsTextGlyph() throws {
        let source = try TestImage.solid(width: 120, height: 60, color: .white)
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .text(.init(
                    id: UUID(),
                    bounds: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                    text: "😀",
                    fontSize: 32,
                    color: .red
                )),
            ]
        )

        let rendered = try AnnotationRenderer().render(source: source, document: document)

        XCTAssertTrue(TestImage.containsPixel(in: rendered) { color in
            !(color.redComponent > 0.98 && color.greenComponent > 0.98 && color.blueComponent > 0.98)
        })
    }

    func testShapeRenderingDrawsOutlineButLeavesInteriorUnchanged() throws {
        let source = try TestImage.solid(width: 100, height: 80, color: .white)
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .shape(.init(
                    id: UUID(),
                    kind: .rect,
                    rect: .init(x: 0.1, y: 0.1, width: 0.6, height: 0.6),
                    color: .red,
                    strokeWidth: 4
                )),
            ]
        )

        let rendered = try AnnotationRenderer().render(source: source, document: document)

        let interior = try TestImage.pixelColor(in: rendered, x: 40, y: 48)
        XCTAssertGreaterThan(interior.redComponent, 0.95)
        XCTAssertGreaterThan(interior.greenComponent, 0.95)
        XCTAssertGreaterThan(interior.blueComponent, 0.95)

        XCTAssertTrue(TestImage.containsPixel(in: rendered) { color in
            color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2
        })
    }

    func testEllipseShapeRenderingDrawsOutline() throws {
        let source = try TestImage.solid(width: 100, height: 80, color: .white)
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .shape(.init(
                    id: UUID(),
                    kind: .ellipse,
                    rect: .init(x: 0.1, y: 0.1, width: 0.6, height: 0.6),
                    color: .red,
                    strokeWidth: 4
                )),
            ]
        )

        let rendered = try AnnotationRenderer().render(source: source, document: document)

        XCTAssertTrue(TestImage.containsPixel(in: rendered) { color in
            color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2
        })
    }

    func testStepBadgeRenderingFillsFixedAccentCircle() throws {
        let source = try TestImage.solid(width: 300, height: 240, color: .white)
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .step(.init(id: UUID(), center: .init(x: 0.5, y: 0.5), number: 3)),
            ]
        )

        let rendered = try AnnotationRenderer().render(source: source, document: document)

        XCTAssertTrue(TestImage.containsPixel(in: rendered) { color in
            color.blueComponent > 0.8 && color.redComponent < 0.5
        })
    }

    func testDraftAdapterMatchesDocumentAdapterForIdenticallyPlacedItems() throws {
        let width = 300
        let height = 240
        let source = try TestImage.solid(width: width, height: height, color: .white)
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .arrow(.init(
                    id: UUID(),
                    start: .init(x: 0.2, y: 0.75),
                    end: .init(x: 0.6, y: 0.75),
                    color: .red,
                    strokeWidth: 6
                )),
                .shape(.init(
                    id: UUID(),
                    kind: .rect,
                    rect: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.15),
                    color: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1),
                    strokeWidth: 4
                )),
                .step(.init(id: UUID(), center: .init(x: 0.5, y: 0.3), number: 7)),
            ]
        )

        let documentRendered = try AnnotationRenderer().render(source: source, document: document)

        // Match the document adapter's own bitmap context exactly (sRGB + byteOrder32Big) so this
        // compares pixels, not incidental PNG color-profile encoding differences.
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let draftContext = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        draftContext.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Same logical items, expressed in the pixel space the document adapter would have
        // produced for them (asymmetric Y so a flip bug in either adapter would be caught).
        try AnnotationRenderer().drawDraft(
            [
                .arrow(
                    start: CGPoint(x: 60, y: 60),
                    end: CGPoint(x: 180, y: 60),
                    color: .red,
                    strokeWidth: 6
                ),
                .shape(
                    kind: .rect,
                    rect: CGRect(x: 30, y: 156, width: 90, height: 36),
                    color: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1),
                    strokeWidth: 4
                ),
                .step(center: CGPoint(x: 150, y: 168), number: 7),
            ],
            in: draftContext,
            origin: .zero,
            scale: 1,
            canvasBounds: CGRect(x: 0, y: 0, width: width, height: height)
        )
        let draftRendered = try XCTUnwrap(draftContext.makeImage())

        XCTAssertEqual(
            try ImageExporter.pngData(for: documentRendered),
            try ImageExporter.pngData(for: draftRendered)
        )
    }

    /// The live-preview call site (`SelectionOverlayView.drawDraftItems`) passes a `.blur` item
    /// together with a non-zero `origin` (the display's global frame origin, per
    /// `ImagePipeline.swift:182-193`'s contract) — the exact combination
    /// `testDraftAdapterMatchesDocumentAdapterForIdenticallyPlacedItems` above doesn't cover, and
    /// the one a `canvasBounds` bug (passing view-local bounds instead of the display-global rect)
    /// silently breaks on any display whose origin isn't (0, 0). A black/white split source makes
    /// blurring visible: sampling from the wrong region (as the bug would, since the mismatched
    /// `canvasBounds` shifts the blur's clip/sampling rect away from the item) produces different
    /// output pixels than the document adapter's.
    func testDraftAdapterMatchesDocumentAdapterForBlurWithNonZeroOrigin() throws {
        let width = 200
        let height = 160
        let source = try TestImage.verticalSplit(width: width, height: height, leftColor: .black, rightColor: .white)
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .blur(.init(
                    id: UUID(),
                    rect: .init(x: 0.35, y: 0.3, width: 0.3, height: 0.4),
                    color: .red,
                    amount: 8
                )),
            ]
        )

        let documentRendered = try AnnotationRenderer().render(source: source, document: document)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let draftContext = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        draftContext.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Simulates a secondary display: draft items are expressed in display-global coordinates
        // (pixel rect + origin), and `canvasBounds` must be the matching display-global rect —
        // exactly what `SelectionOverlayView.drawDraftItems` now passes via `globalRect(bounds)`.
        let origin = CGPoint(x: 340, y: 90)
        try AnnotationRenderer().drawDraft(
            [
                .blur(
                    rect: CGRect(x: 70 + origin.x, y: 48 + origin.y, width: 60, height: 64),
                    color: .red,
                    amount: 8
                ),
            ],
            in: draftContext,
            origin: origin,
            scale: 1,
            canvasBounds: CGRect(origin: origin, size: CGSize(width: width, height: height))
        )
        let draftRendered = try XCTUnwrap(draftContext.makeImage())

        XCTAssertEqual(
            try ImageExporter.pngData(for: documentRendered),
            try ImageExporter.pngData(for: draftRendered)
        )
    }

    /// Root cause (confirmed): `SelectionOverlayView.drawDraftItems` draws into the overlay's own
    /// layer-backed `CGContext`, whose `makeImage()` call returns `nil` there (an AppKit quirk of
    /// that specific live-draw context) — `AnnotationRenderer.blurRect` throws
    /// `.contextCreation`, and the `try?` at the call site swallows it, so the live blur preview
    /// silently draws nothing. `drawDraft`'s `source:` parameter lets `.blur` crop and blur
    /// straight from the frozen snapshot instead of reading the context back, sidestepping
    /// `makeImage()` for this path entirely.
    ///
    /// A plain bitmap `CGContext` (used below) still succeeds at `makeImage()`, unlike the real
    /// overlay — so this test can't rely on "did it throw"; it has to prove *which image* the
    /// blurred pixels came from. The context is filled solid red (a color absent from the
    /// snapshot); the snapshot is a four-quadrant image at 2x the context's size (mimicking a
    /// Retina display, and exercising the source/context scale mapping). The draft blur rect sits
    /// deep inside the snapshot's green quadrant, comfortably clear of every quadrant boundary and
    /// the blur's own sampling margin. Correct behavior samples green; reading the context back
    /// (the bug) samples red; a flipped x or y mapping samples one of the other three quadrant
    /// colors instead — all four failure modes are distinguishable from the one correct outcome.
    func testDraftBlurPreviewSourcesPixelsFromSnapshotNotContextReadback() throws {
        let canvasSize = 100
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: canvasSize,
            height: canvasSize,
            bitsPerComponent: 8,
            bytesPerRow: canvasSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

        let snapshotSize = canvasSize * 2
        let half = snapshotSize / 2
        let snapshotContext = try XCTUnwrap(CGContext(
            data: nil,
            width: snapshotSize,
            height: snapshotSize,
            bitsPerComponent: 8,
            bytesPerRow: snapshotSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let quadrants: [(CGRect, NSColor)] = [
            (CGRect(x: 0, y: 0, width: half, height: half), NSColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: half, y: 0, width: half, height: half), NSColor(red: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: half, width: half, height: half), NSColor(red: 1, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: half, y: half, width: half, height: half), NSColor(red: 1, green: 0, blue: 1, alpha: 1)),
        ]
        for (rect, color) in quadrants {
            snapshotContext.setFillColor(color.cgColor)
            snapshotContext.fill(rect)
        }
        let snapshot = try XCTUnwrap(snapshotContext.makeImage())

        // Deep inside the (half, 0, half, half) quadrant — green.
        let blurRect = CGRect(x: 60, y: 10, width: 30, height: 30)
        try AnnotationRenderer().drawDraft(
            [.blur(rect: blurRect, color: .red, amount: 4)],
            in: context,
            origin: .zero,
            scale: 1,
            canvasBounds: CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize),
            source: snapshot
        )

        let rendered = try XCTUnwrap(context.makeImage())

        // `CGImage.cropping(to:)` + `TestImage.pixelColor` (via `NSBitmapImageRep`) read pixels
        // top-down; `context`/`drawDraft` place items in Core Graphics' native bottom-up point
        // space. Flipping here (same formula as `AnnotationRenderer.pixelRect`) converts a
        // context-space rect to the top-down crop rect that contains the same drawn content.
        func topDownCrop(_ contextRect: CGRect) -> CGRect {
            CGRect(
                x: contextRect.minX,
                y: CGFloat(canvasSize) - contextRect.maxY,
                width: contextRect.width,
                height: contextRect.height
            )
        }

        let insideCrop = try XCTUnwrap(rendered.cropping(to: topDownCrop(CGRect(x: 72, y: 22, width: 6, height: 6))))
        let inside = try TestImage.pixelColor(in: insideCrop, x: 0, y: 0)
        XCTAssertGreaterThan(inside.greenComponent, 0.7)
        XCTAssertLessThan(inside.redComponent, 0.3)
        XCTAssertLessThan(inside.blueComponent, 0.3)

        let outsideCrop = try XCTUnwrap(rendered.cropping(to: topDownCrop(CGRect(x: 5, y: 5, width: 2, height: 2))))
        let outside = try TestImage.pixelColor(in: outsideCrop, x: 0, y: 0)
        XCTAssertGreaterThan(outside.redComponent, 0.9)
        XCTAssertLessThan(outside.greenComponent, 0.1)
    }

    func testPreviewUsesTheSameTextAndBlurPixelsAsUncroppedExport() async throws {
        let source = try TestImage.verticalSplit(
            width: 120,
            height: 80,
            leftColor: .black,
            rightColor: .white
        )
        let capture = CapturedImage(
            id: UUID(),
            kind: .area,
            title: "Preview parity",
            createdAt: .now,
            image: source,
            pixelSize: PixelSize(width: source.width, height: source.height)
        )
        let document = AnnotationDocument(
            captureID: capture.id,
            items: [
                .text(.init(
                    id: UUID(),
                    bounds: .init(x: 0.05, y: 0.05, width: 0.7, height: 0.35),
                    text: "Parity",
                    fontSize: 24,
                    color: .red
                )),
                .blur(.init(
                    id: UUID(),
                    rect: .init(x: 0.42, y: 0.45, width: 0.2, height: 0.4),
                    color: .red,
                    amount: 6
                )),
            ],
            cropRect: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )

        let preview = try await AnnotationPreviewService().render(
            capture: capture,
            document: document,
            maxPixelSize: 120
        )
        let exportSurface = try AnnotationRenderer().render(
            source: source,
            document: document,
            appliesCrop: false
        )

        XCTAssertEqual(try ImageExporter.pngData(for: preview), try ImageExporter.pngData(for: exportSurface))
        XCTAssertEqual(preview.width, source.width)
        XCTAssertEqual(preview.height, source.height)
    }

    func testPreviewDownsamplesLargeSourceToRequestedDisplaySurface() async throws {
        let source = try TestImage.solid(width: 400, height: 200, color: .white)
        let capture = CapturedImage(
            id: UUID(),
            kind: .area,
            title: "Downsample",
            createdAt: .now,
            image: source,
            pixelSize: PixelSize(width: source.width, height: source.height)
        )
        let document = AnnotationDocument(
            captureID: capture.id,
            items: [
                .text(.init(
                    id: UUID(),
                    bounds: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.3),
                    text: "Scaled",
                    fontSize: 40,
                    color: .red
                )),
                .blur(.init(
                    id: UUID(),
                    rect: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.3),
                    color: .red,
                    amount: 12
                )),
            ]
        )

        let preview = try await AnnotationPreviewService().render(
            capture: capture,
            document: document,
            maxPixelSize: 100
        )

        XCTAssertEqual(preview.width, 100)
        XCTAssertEqual(preview.height, 50)
        XCTAssertTrue(TestImage.containsPixel(in: preview) { color in
            color.redComponent > 0.7 && color.greenComponent < 0.8
        })
    }

    func testPreviewSurfaceHasAHardPixelBoundEvenWhenCallerRequestsMore() async throws {
        let source = try TestImage.solid(width: 4_200, height: 1, color: .white)
        let capture = CapturedImage(
            id: UUID(),
            kind: .area,
            title: "Bounded preview",
            createdAt: .now,
            image: source,
            pixelSize: PixelSize(width: source.width, height: source.height)
        )

        let preview = try await AnnotationPreviewService().render(
            capture: capture,
            document: AnnotationDocument(captureID: capture.id),
            maxPixelSize: 20_000
        )

        XCTAssertEqual(AnnotationPreviewService.maximumPixelSize, 4_096)
        XCTAssertEqual(preview.width, 4_096)
        XCTAssertEqual(preview.height, 1)
    }

    func testHighlightRenderingBlendsConfiguredColor() throws {
        let source = try TestImage.solid(width: 40, height: 20, color: .white)
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .highlight(.init(
                    id: UUID(),
                    rect: .init(x: 0.25, y: 0, width: 0.5, height: 1),
                    color: .init(red: 0, green: 0, blue: 1, alpha: 1),
                    amount: 0.5
                )),
            ]
        )

        let rendered = try AnnotationRenderer().render(source: source, document: document)
        let base = try TestImage.pixelColor(in: rendered, x: 5, y: 10)
        let sample = try TestImage.pixelColor(in: rendered, x: 20, y: 10)

        XCTAssertLessThan(sample.redComponent, base.redComponent - 0.2)
        XCTAssertGreaterThan(sample.redComponent, 0.1)
        XCTAssertLessThan(sample.greenComponent, base.greenComponent - 0.2)
        XCTAssertGreaterThan(sample.greenComponent, 0.1)
        XCTAssertEqual(sample.redComponent, sample.greenComponent, accuracy: 0.03)
        XCTAssertEqual(sample.blueComponent, base.blueComponent, accuracy: 0.03)
    }

    func testBlurOnlyChangesPixelsInsideConfiguredRegion() throws {
        let source = try TestImage.verticalSplit(
            width: 40,
            height: 20,
            leftColor: .black,
            rightColor: .white
        )
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .blur(.init(
                    id: UUID(),
                    rect: .init(x: 0.4, y: 0, width: 0.2, height: 1),
                    color: .red,
                    amount: 4
                )),
            ]
        )

        let rendered = try AnnotationRenderer().render(source: source, document: document)
        let outsideLeft = try TestImage.pixelColor(in: rendered, x: 5, y: 10)
        let inside = try TestImage.pixelColor(in: rendered, x: 19, y: 10)
        let outsideRight = try TestImage.pixelColor(in: rendered, x: 35, y: 10)

        XCTAssertLessThan(outsideLeft.redComponent, 0.02)
        XCTAssertGreaterThan(inside.redComponent, 0.05)
        XCTAssertLessThan(inside.redComponent, 0.95)
        XCTAssertGreaterThan(outsideRight.redComponent, 0.98)
    }

    func testBlurSamplingRectIsBoundedForSmallRegionInLargeImage() {
        let imageBounds = CGRect(x: 0, y: 0, width: 30_000, height: 12_000)
        let outputRect = CGRect(x: 12_000, y: 4_000, width: 200, height: 100)
        let radius: CGFloat = 20

        let samplingRect = AnnotationRenderer.blurSamplingRect(
            for: outputRect,
            radius: radius,
            imageBounds: imageBounds
        )

        XCTAssertTrue(imageBounds.contains(samplingRect))
        XCTAssertTrue(samplingRect.contains(outputRect))
        XCTAssertLessThan(
            samplingRect.width * samplingRect.height,
            imageBounds.width * imageBounds.height / 1_000
        )
        XCTAssertLessThanOrEqual(samplingRect.minX, outputRect.minX - radius)
        XCTAssertGreaterThanOrEqual(samplingRect.maxX, outputRect.maxX + radius)
        XCTAssertLessThanOrEqual(samplingRect.minY, outputRect.minY - radius)
        XCTAssertGreaterThanOrEqual(samplingRect.maxY, outputRect.maxY + radius)
    }

    func testCropChangesRenderedDimensions() throws {
        let source = try TestImage.solid(width: 100, height: 80, color: .white)
        let document = AnnotationDocument(
            captureID: UUID(),
            cropRect: .init(x: 0.1, y: 0.25, width: 0.5, height: 0.5)
        )

        let rendered = try AnnotationRenderer().render(source: source, document: document)

        XCTAssertEqual(rendered.width, 50)
        XCTAssertEqual(rendered.height, 40)
    }

    func testCropIsAppliedAfterAnnotationsInTopLeftCoordinates() throws {
        let source = try TestImage.solid(width: 100, height: 100, color: .white)
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .arrow(.init(
                    id: UUID(),
                    start: .init(x: 0.2, y: 0.1),
                    end: .init(x: 0.8, y: 0.1),
                    color: .red,
                    strokeWidth: 6
                )),
            ],
            cropRect: .init(x: 0, y: 0, width: 1, height: 0.5)
        )

        let rendered = try AnnotationRenderer().render(source: source, document: document)

        XCTAssertEqual(rendered.height, 50)
        XCTAssertTrue(TestImage.containsPixel(in: rendered) { color in
            color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2
        })
    }

    func testThumbnailConstrainsMaximumPixelSize() throws {
        let source = try TestImage.solid(width: 100, height: 50, color: .white)

        let thumbnail = try ImageExporter.thumbnail(for: source, maxPixelSize: 30)

        XCTAssertEqual(thumbnail.width, 30)
        XCTAssertEqual(thumbnail.height, 15)
    }
}
