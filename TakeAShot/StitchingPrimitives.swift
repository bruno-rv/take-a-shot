import CoreGraphics
import Darwin
import Foundation

/// Downsampled grayscale-luminance snapshot of a `CGImage`, used as the cheap, robust basis for
/// row-by-row correlation by both the automatic (`FrameStitcher`) and manual (`FrameShiftMatcher`)
/// overlap matchers. Extracted here so both share one implementation instead of two private
/// copies (PLAN.md §4).
struct LuminanceSample {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(image: CGImage, width: Int, height: Int) {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Row-range correlation over two `LuminanceSample`s, shared by every overlap/shift matcher in
/// the app. Returns a confidence in `[0, 1]`; `1` means the compared rows are pixel-identical.
enum LuminanceCorrelation {
    static func confidence(
        lhs: LuminanceSample,
        lhsStartRow: Int,
        rhs: LuminanceSample,
        rhsStartRow: Int,
        rowCount: Int
    ) -> Double {
        guard rowCount > 0 else { return 0 }
        let cellCount = rowCount * lhs.width
        var difference = 0
        for rowOffset in 0..<rowCount {
            let lhsOffset = (lhsStartRow + rowOffset) * lhs.width
            let rhsOffset = (rhsStartRow + rowOffset) * rhs.width
            for column in 0..<lhs.width {
                difference += abs(Int(lhs.pixels[lhsOffset + column]) - Int(rhs.pixels[rhsOffset + column]))
            }
        }
        let averageDifference = Double(difference) / Double(cellCount)
        return max(0, 1 - averageDifference / 24)
    }
}

/// Mechanical failure modes for the raw-pixel-file primitives below, independent of any capture
/// engine's own error vocabulary — each engine (`ScrollingCaptureError`, `ManualScrollCaptureError`)
/// maps these to its own case at its own call sites, so both keep their existing, engine-specific
/// error surfaces unchanged by this extraction.
enum RawPixelFileError: Error, Equatable, Sendable {
    case dimensionsTooLarge
    case mappingFailed
    case creationFailed
}

/// Low-level write/mmap/`CGDataProvider`→`CGImage` primitives shared by every append-only,
/// file-backed pixel store in the app (`IncrementalImageStitcher` for Auto Scrolling Capture,
/// `StripStore` for Manual Scroll Capture). Extracted so both use one tested implementation of
/// "render a CGImage to top-left-origin RGBA8 bytes" and "mmap a file of such bytes back into a
/// CGImage" (PLAN.md §6).
enum RawPixelFile {
    /// Renders `image` into top-left-origin RGBA8 bytes (row 0 = the image's own top row, per
    /// `CGImage.cropping(to:)`'s documented upper-left origin) with `width * 4`-byte rows — the
    /// same in-memory layout every append-only backing file in the app persists.
    static func rgbaData(for image: CGImage) throws -> Data {
        guard image.width <= Int.max / 4, image.height <= Int.max / (image.width * 4) else {
            throw RawPixelFileError.dimensionsTooLarge
        }
        let bytesPerRow = image.width * 4
        var data = Data(count: bytesPerRow * image.height)
        let rendered = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ).union(.byteOrder32Big).rawValue
            ) else { return false }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard rendered else { throw RawPixelFileError.creationFailed }
        return data
    }

    /// mmaps `url` read-only and wraps the mapping as a `CGImage` (no copy); the mapping is
    /// released via `munmap` when the returned image is deallocated. `width`/`height`/`bytesPerRow`
    /// must describe the same top-left-origin RGBA8 layout `rgbaData(for:)` writes.
    static func cgImage(
        mappingFileAt url: URL,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws -> CGImage {
        let fileDescriptor = Darwin.open(url.path, O_RDONLY)
        guard fileDescriptor >= 0 else {
            throw RawPixelFileError.mappingFailed
        }
        let byteCount = height * bytesPerRow
        let mappedBytes = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, fileDescriptor, 0)
        Darwin.close(fileDescriptor)
        guard mappedBytes != MAP_FAILED, let mappedBytes else {
            throw RawPixelFileError.mappingFailed
        }
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: UnsafeRawPointer(mappedBytes),
            size: byteCount,
            releaseData: { _, data, size in
                munmap(UnsafeMutableRawPointer(mutating: data), size)
            }
        ) else {
            munmap(mappedBytes, byteCount)
            throw RawPixelFileError.creationFailed
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.byteOrder32Big)
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw RawPixelFileError.creationFailed
        }
        return image
    }
}
