import AppKit
import XCTest

enum TestImage {
    static func solid(width: Int, height: Int, color: NSColor) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestImageError.contextCreation }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestImageError.imageCreation }
        return image
    }

    static func verticalSplit(
        width: Int,
        height: Int,
        leftColor: NSColor,
        rightColor: NSColor
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestImageError.contextCreation }
        context.setFillColor(leftColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(rightColor.cgColor)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        guard let image = context.makeImage() else { throw TestImageError.imageCreation }
        return image
    }

    static func pixelColor(in image: CGImage, x: Int, y: Int) throws -> NSColor {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            throw TestImageError.colorSpaceConversion
        }
        return color
    }

    static func containsPixel(
        in image: CGImage,
        matching predicate: (NSColor) -> Bool
    ) -> Bool {
        let representation = NSBitmapImageRep(cgImage: image)
        for y in 0..<image.height {
            for x in 0..<image.width {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if predicate(color) { return true }
            }
        }
        return false
    }
}

enum TestImageError: Error { case contextCreation, imageCreation, colorSpaceConversion }

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

extension Optional {
    func unwrapped(file: StaticString = #filePath, line: UInt = #line) throws -> Wrapped {
        try XCTUnwrap(self, file: file, line: line)
    }
}
