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

struct AnnotationRenderer {
    private let imageContext = CIContext()

    func render(
        source: CGImage,
        document: AnnotationDocument,
        appliesCrop: Bool = true
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
                draw(annotation, in: context, imageSize: size)
            case .text(let annotation):
                draw(annotation, in: context, imageSize: size)
            case .highlight(let annotation):
                draw(annotation, in: context, imageSize: size)
            case .blur(let annotation):
                try draw(annotation, in: context, imageBounds: bounds, imageSize: size)
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

    private func draw(
        _ annotation: ArrowAnnotation,
        in context: CGContext,
        imageSize: CGSize
    ) {
        let start = pixelPoint(for: annotation.start, imageSize: imageSize)
        let end = pixelPoint(for: annotation.end, imageSize: imageSize)
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let length = hypot(deltaX, deltaY)
        guard length > 0 else { return }

        let lineWidth = max(1, CGFloat(annotation.strokeWidth))
        let arrowHeadLength = min(length * 0.4, max(8, lineWidth * 3))
        let angle = atan2(deltaY, deltaX)
        let spread = CGFloat.pi / 6

        context.saveGState()
        context.setStrokeColor(annotation.color.cgColor)
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

    private func draw(
        _ annotation: TextAnnotation,
        in context: CGContext,
        imageSize: CGSize
    ) {
        guard !annotation.text.isEmpty else { return }
        let rect = pixelRect(for: annotation.bounds, imageSize: imageSize)
        guard rect.width > 0, rect.height > 0 else { return }

        let font = CTFontCreateWithName(
            "Helvetica" as CFString,
            max(1, CGFloat(annotation.fontSize)),
            nil
        )
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.color.cgColor,
        ]
        let text = NSAttributedString(string: annotation.text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: text.length),
            path,
            nil
        )

        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func draw(
        _ annotation: RectAnnotation,
        in context: CGContext,
        imageSize: CGSize
    ) {
        let rect = pixelRect(for: annotation.rect, imageSize: imageSize)
        guard rect.width > 0, rect.height > 0 else { return }
        let opacity = max(0, min(1, annotation.amount))

        context.saveGState()
        context.setFillColor(annotation.color.cgColor.copy(alpha: annotation.color.alpha * opacity) ?? annotation.color.cgColor)
        context.fill(rect)
        context.restoreGState()
    }

    private func draw(
        _ annotation: RectAnnotation,
        in context: CGContext,
        imageBounds: CGRect,
        imageSize: CGSize
    ) throws {
        let outputRect = pixelRect(for: annotation.rect, imageSize: imageSize)
            .intersection(imageBounds)
        let radius = max(0, CGFloat(annotation.amount))
        guard !outputRect.isNull, outputRect.width > 0, outputRect.height > 0, radius > 0 else {
            return
        }
        guard let currentImage = context.makeImage() else { throw ImagePipelineError.contextCreation }

        let samplingRect = Self.blurSamplingRect(
            for: outputRect,
            radius: radius,
            imageBounds: imageBounds
        )
        let inputRegion = CIImage(cgImage: currentImage).cropped(to: samplingRect)
        let blurred = inputRegion
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: outputRect)
        guard let blurredImage = imageContext.createCGImage(blurred, from: outputRect) else {
            throw ImagePipelineError.contextCreation
        }

        context.draw(blurredImage, in: outputRect)
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
