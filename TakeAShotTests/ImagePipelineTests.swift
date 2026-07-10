import AppKit
import ImageIO
import XCTest
@testable import TakeAShot

final class ImagePipelineTests: XCTestCase {
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
