import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImagePipelineError: Error, Equatable {
    case contextCreation
    case destinationCreation
    case finalization
    case cropOutsideImage
}

enum ImageExporter {
    static func pngData(for image: CGImage) throws -> Data {
        try encode(image, type: UTType.png.identifier as CFString, properties: [:])
    }

    static func jpegData(for image: CGImage, quality: Double) throws -> Data {
        let opaqueImage = try imageWithWhiteBackground(image)
        return try encode(
            opaqueImage,
            type: UTType.jpeg.identifier as CFString,
            properties: [
                kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality)),
            ]
        )
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    static func thumbnail(for image: CGImage, maxPixelSize: Int) throws -> CGImage {
        guard maxPixelSize > 0 else { throw ImagePipelineError.contextCreation }
        let largestDimension = max(image.width, image.height)
        guard largestDimension > maxPixelSize else { return image }

        let scale = CGFloat(maxPixelSize) / CGFloat(largestDimension)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = makeBitmapContext(width: width, height: height) else {
            throw ImagePipelineError.contextCreation
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { throw ImagePipelineError.contextCreation }
        return thumbnail
    }

    private static func encode(
        _ image: CGImage,
        type: CFString,
        properties: [CFString: Any]
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw ImagePipelineError.destinationCreation
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImagePipelineError.finalization
        }
        return data as Data
    }

    private static func imageWithWhiteBackground(_ image: CGImage) throws -> CGImage {
        guard let context = makeBitmapContext(width: image.width, height: image.height, opaque: true) else {
            throw ImagePipelineError.contextCreation
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let opaqueImage = context.makeImage() else { throw ImagePipelineError.contextCreation }
        return opaqueImage
    }
}

/// A single Quick Annotation draft item in a caller-supplied, unclamped point space
/// (e.g. display-global or overlay-local coordinates) — never normalized, never clamped.
/// Mirrors `AnnotationItem`'s cases minus identity, since drafts are pre-capture working state
/// that never becomes a persisted `AnnotationItem` directly.
enum AnnotationDraftItem: Equatable {
    case arrow(start: CGPoint, end: CGPoint, color: RGBAColor, strokeWidth: Double)
    case text(bounds: CGRect, text: String, fontSize: Double, color: RGBAColor)
    case highlight(rect: CGRect, color: RGBAColor, amount: Double)
    case blur(rect: CGRect, color: RGBAColor, amount: Double)
    case shape(kind: ShapeKind, rect: CGRect, color: RGBAColor, strokeWidth: Double)
    case step(center: CGPoint, number: Int)
}

/// Renders `AnnotationItem`s (and, pre-capture, `AnnotationDraftItem`s) onto a `CGContext` using a
/// shared set of drawing primitives. Two adapters own the coordinate transforms and call the same
/// primitives, per docs/adr/0001: the **document adapter** (`render(source:document:)`, the Bake
/// path — normalized 0-1 coordinates → image pixels) and the **draft adapter** (`drawDraft`, the
/// Selection Overlay's pre-capture preview — caller-supplied point space → context points, via a
/// simple origin+scale transform, with no clamping).
struct AnnotationRenderer {
    private let imageContext = CIContext()

    // MARK: - Document adapter (Bake path)

    func render(
        source: CGImage,
        document: AnnotationDocument,
        appliesCrop: Bool = true,
        annotationScale: CGFloat = 1
    ) throws -> CGImage {
        let size = CGSize(width: source.width, height: source.height)
        let bounds = CGRect(origin: .zero, size: size)
        guard let context = makeBitmapContext(width: source.width, height: source.height) else {
            throw ImagePipelineError.contextCreation
        }
        context.draw(source, in: bounds)

        for item in document.items {
            switch item {
            case .arrow(let annotation):
                strokeArrow(
                    from: pixelPoint(for: annotation.start, imageSize: size),
                    to: pixelPoint(for: annotation.end, imageSize: size),
                    color: annotation.color,
                    lineWidth: max(1, CGFloat(annotation.strokeWidth) * annotationScale),
                    in: context
                )
            case .text(let annotation):
                drawTextRun(
                    annotation.text,
                    in: pixelRect(for: annotation.bounds, imageSize: size),
                    fontSize: max(1, CGFloat(annotation.fontSize) * annotationScale),
                    color: annotation.color,
                    in: context
                )
            case .highlight(let annotation):
                fillRect(
                    pixelRect(for: annotation.rect, imageSize: size),
                    color: annotation.color,
                    opacity: annotation.amount,
                    in: context
                )
            case .blur(let annotation):
                try blurRect(
                    pixelRect(for: annotation.rect, imageSize: size),
                    radius: max(0, CGFloat(annotation.amount) * annotationScale),
                    imageBounds: bounds,
                    in: context
                )
            case .shape(let annotation):
                strokeShape(
                    kind: annotation.kind,
                    rect: pixelRect(for: annotation.rect, imageSize: size),
                    color: annotation.color,
                    lineWidth: max(1, CGFloat(annotation.strokeWidth) * annotationScale),
                    in: context
                )
            case .step(let annotation):
                let diameter = CGFloat(StepAnnotation.diameterFraction) * min(size.width, size.height)
                drawStepBadge(
                    center: pixelPoint(for: annotation.center, imageSize: size),
                    diameter: diameter,
                    number: annotation.number,
                    in: context
                )
            }
        }

        guard let rendered = context.makeImage() else { throw ImagePipelineError.contextCreation }
        guard appliesCrop, let crop = document.cropRect else { return rendered }
        let cropRect = cropPixelRect(for: crop, imageSize: size).integral.intersection(bounds)
        guard !cropRect.isNull, cropRect.width > 0, cropRect.height > 0,
              let cropped = rendered.cropping(to: cropRect)
        else {
            throw ImagePipelineError.cropOutsideImage
        }
        return cropped
    }

    // MARK: - Draft adapter (Selection Overlay pre-capture preview)

    /// Draws draft items into `context` using the same primitives as the document adapter.
    /// `origin`/`scale` map a draft point into the context's point space:
    /// `contextPoint = (draftPoint - origin) * scale`. Geometry is never clamped — out-of-selection
    /// draft items are the overlay's responsibility (per-type rules applied at Confirm, not here).
    /// `canvasBounds` (in the same unscaled draft space as the items) is used to clip blur sampling
    /// and to size step badges, mirroring how the document adapter uses the image's own bounds.
    /// `source`, when provided, is the frozen snapshot the caller already drew as the bottom layer
    /// of `context` (in `canvasBounds`) — `.blur` samples and blurs directly from it instead of
    /// reading `context` back via `makeImage()`, which is `nil` inside the Selection Overlay's own
    /// layer-backed live-draw context (the confirmed root cause of the live blur preview drawing
    /// nothing). Deliberate preview divergence: sourcing from the snapshot means the blur can't see
    /// other draft items drawn beneath it in the same pass — bake (`render(source:document:)`)
    /// remains ground truth. Defaults to `nil`, which keeps the original context-read-back behavior
    /// for every other caller (document-adapter parity tests, synthetic-context callers).
    func drawDraft(
        _ items: [AnnotationDraftItem],
        in context: CGContext,
        origin: CGPoint,
        scale: CGFloat,
        canvasBounds: CGRect,
        source: CGImage? = nil
    ) throws {
        func transformedPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - origin.x) * scale, y: (point.y - origin.y) * scale)
        }
        func transformedRect(_ rect: CGRect) -> CGRect {
            CGRect(
                x: (rect.minX - origin.x) * scale,
                y: (rect.minY - origin.y) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
        }

        let targetBounds = transformedRect(canvasBounds)

        for item in items {
            switch item {
            case let .arrow(start, end, color, strokeWidth):
                strokeArrow(
                    from: transformedPoint(start),
                    to: transformedPoint(end),
                    color: color,
                    lineWidth: max(1, CGFloat(strokeWidth) * scale),
                    in: context
                )
            case let .text(bounds, text, fontSize, color):
                drawTextRun(
                    text,
                    in: transformedRect(bounds),
                    fontSize: max(1, CGFloat(fontSize) * scale),
                    color: color,
                    in: context
                )
            case let .highlight(rect, color, amount):
                fillRect(transformedRect(rect), color: color, opacity: amount, in: context)
            case let .blur(rect, color, amount):
                try blurRect(
                    transformedRect(rect),
                    radius: max(0, CGFloat(amount) * scale),
                    imageBounds: targetBounds,
                    source: source,
                    in: context
                )
            case let .shape(kind, rect, color, strokeWidth):
                strokeShape(
                    kind: kind,
                    rect: transformedRect(rect),
                    color: color,
                    lineWidth: max(1, CGFloat(strokeWidth) * scale),
                    in: context
                )
            case let .step(center, number):
                let diameter = CGFloat(StepAnnotation.diameterFraction)
                    * min(targetBounds.width, targetBounds.height)
                drawStepBadge(
                    center: transformedPoint(center),
                    diameter: diameter,
                    number: number,
                    in: context
                )
            }
        }
    }

    // MARK: - Shared render primitives

    private func strokeArrow(
        from start: CGPoint,
        to end: CGPoint,
        color: RGBAColor,
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let length = hypot(deltaX, deltaY)
        guard length > 0 else { return }

        let arrowHeadLength = min(length * 0.4, max(8, lineWidth * 3))
        let angle = atan2(deltaY, deltaX)
        let spread = CGFloat.pi / 6

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.move(to: end)
        context.addLine(to: CGPoint(
            x: end.x - arrowHeadLength * cos(angle - spread),
            y: end.y - arrowHeadLength * sin(angle - spread)
        ))
        context.move(to: end)
        context.addLine(to: CGPoint(
            x: end.x - arrowHeadLength * cos(angle + spread),
            y: end.y - arrowHeadLength * sin(angle + spread)
        ))
        context.strokePath()
        context.restoreGState()
    }

    private func drawTextRun(
        _ text: String,
        in rect: CGRect,
        fontSize: CGFloat,
        color: RGBAColor,
        in context: CGContext
    ) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }

        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText as CFAttributedString)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            path,
            nil
        )

        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func fillRect(
        _ rect: CGRect,
        color: RGBAColor,
        opacity: Double,
        in context: CGContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        let clampedOpacity = max(0, min(1, opacity))

        context.saveGState()
        context.setFillColor(color.cgColor.copy(alpha: color.alpha * clampedOpacity) ?? color.cgColor)
        context.fill(rect)
        context.restoreGState()
    }

    private func blurRect(
        _ outputRect: CGRect,
        radius: CGFloat,
        imageBounds: CGRect,
        source: CGImage? = nil,
        in context: CGContext
    ) throws {
        let clippedOutput = outputRect.intersection(imageBounds)
        guard !clippedOutput.isNull, clippedOutput.width > 0, clippedOutput.height > 0, radius > 0 else {
            return
        }

        // Live-preview path: sample the caller-supplied snapshot directly (same coordinate
        // convention as `context`, just uniformly scaled — `source`'s pixel size vs `imageBounds`'
        // point size), instead of `context.makeImage()`, which returns `nil` in the Selection
        // Overlay's own layer-backed context.
        if let source, imageBounds.width > 0, imageBounds.height > 0 {
            let scaleX = CGFloat(source.width) / imageBounds.width
            let scaleY = CGFloat(source.height) / imageBounds.height
            let sourceBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            let sourceOutput = CGRect(
                x: (clippedOutput.minX - imageBounds.minX) * scaleX,
                y: (clippedOutput.minY - imageBounds.minY) * scaleY,
                width: clippedOutput.width * scaleX,
                height: clippedOutput.height * scaleY
            ).intersection(sourceBounds)
            guard !sourceOutput.isNull, sourceOutput.width > 0, sourceOutput.height > 0 else { return }

            let blurredImage = try gaussianBlurred(
                CIImage(cgImage: source),
                cropRect: sourceOutput,
                samplingBounds: sourceBounds,
                radius: radius * scaleX
            )
            context.draw(blurredImage, in: clippedOutput)
            return
        }

        guard let currentImage = context.makeImage() else { throw ImagePipelineError.contextCreation }
        let blurredImage = try gaussianBlurred(
            CIImage(cgImage: currentImage),
            cropRect: clippedOutput,
            samplingBounds: imageBounds,
            radius: radius
        )
        context.draw(blurredImage, in: clippedOutput)
    }

    private func gaussianBlurred(
        _ ciImage: CIImage,
        cropRect: CGRect,
        samplingBounds: CGRect,
        radius: CGFloat
    ) throws -> CGImage {
        let samplingRect = Self.blurSamplingRect(for: cropRect, radius: radius, imageBounds: samplingBounds)
        let inputRegion = ciImage.cropped(to: samplingRect)
        let blurred = inputRegion
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: cropRect)
        guard let result = imageContext.createCGImage(blurred, from: cropRect) else {
            throw ImagePipelineError.contextCreation
        }
        return result
    }

    private func strokeShape(
        kind: ShapeKind,
        rect: CGRect,
        color: RGBAColor,
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        switch kind {
        case .rect:
            context.stroke(rect)
        case .ellipse:
            context.strokeEllipse(in: rect)
        }
        context.restoreGState()
    }

    private func drawStepBadge(
        center: CGPoint,
        diameter: CGFloat,
        number: Int,
        in context: CGContext
    ) {
        guard diameter > 0 else { return }
        let radius = diameter / 2
        let badgeRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: diameter,
            height: diameter
        )

        context.saveGState()
        context.setFillColor(Self.stepBadgeFillColor.cgColor)
        context.fillEllipse(in: badgeRect)
        context.restoreGState()

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, diameter * 0.5, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Self.stepBadgeTextColor.cgColor,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\(number)", attributes: attributes) as CFAttributedString
        )
        let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: center.x - lineBounds.midX,
            y: center.y - lineBounds.midY
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func blurSamplingRect(
        for outputRect: CGRect,
        radius: CGFloat,
        imageBounds: CGRect
    ) -> CGRect {
        let samplingMargin = ceil(max(0, radius) * 3)
        return outputRect
            .insetBy(dx: -samplingMargin, dy: -samplingMargin)
            .intersection(imageBounds)
    }

    // MARK: - Normalized → pixel transforms (document adapter only)

    private func pixelPoint(for point: NormalizedPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(
            x: point.x * imageSize.width,
            y: (1 - point.y) * imageSize.height
        )
    }

    private func pixelRect(for rect: NormalizedRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: rect.x * imageSize.width,
            y: (1 - rect.y - rect.height) * imageSize.height,
            width: rect.width * imageSize.width,
            height: rect.height * imageSize.height
        )
    }

    private func cropPixelRect(for rect: NormalizedRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: rect.x * imageSize.width,
            y: rect.y * imageSize.height,
            width: rect.width * imageSize.width,
            height: rect.height * imageSize.height
        )
    }

    private static let stepBadgeFillColor = RGBAColor(red: 0.16, green: 0.5, blue: 1, alpha: 1)
    private static let stepBadgeTextColor = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
}

private func makeBitmapContext(
    width: Int,
    height: Int,
    opaque: Bool = false
) -> CGContext? {
    let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    return CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: alphaInfo.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    )
}

private extension RGBAColor {
    var cgColor: CGColor {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGColor(
            colorSpace: colorSpace,
            components: [red, green, blue, alpha]
        ) ?? CGColor(gray: 0, alpha: alpha)
    }
}
