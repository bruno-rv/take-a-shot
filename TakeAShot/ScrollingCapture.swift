import ApplicationServices
import CoreGraphics
import Foundation

struct OverlapMatch: Equatable, Sendable {
    let overlapRows: Int
    let novelRows: Int
    let confidence: Double
    let novelRowRange: Range<Int>
    let replacedBottomRows: Int
}

enum ScrollingCaptureError: LocalizedError, Equatable, Sendable {
    case accessibilityDenied
    case eventCreation
    case lowConfidence
    case pixelLimit
    case frameLimit
    case durationLimit
    case cancelled
    case invalidFrame
    case imageCreation

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            "Accessibility permission is required for automatic scrolling."
        case .eventCreation:
            "Take a Shot could not send a scroll event to the selected window."
        case .lowConfidence:
            "The captured frames could not be matched reliably."
        case .pixelLimit:
            "Scrolling capture reached the 30,000-pixel safety limit."
        case .frameLimit:
            "Scrolling capture reached the 100-frame safety limit."
        case .durationLimit:
            "Scrolling capture reached the 60-second safety limit."
        case .cancelled:
            "Scrolling capture was cancelled."
        case .invalidFrame:
            "The selected window changed size during scrolling capture."
        case .imageCreation:
            "Take a Shot could not create the stitched image."
        }
    }
}

struct FrameStitcher: Sendable {
    private let confidenceThreshold: Double
    private let sampleWidth: Int
    private let maximumSampleHeight: Int

    init(
        confidenceThreshold: Double = 0.92,
        sampleWidth: Int = 32,
        maximumSampleHeight: Int = 1_000
    ) {
        self.confidenceThreshold = confidenceThreshold
        self.sampleWidth = sampleWidth
        self.maximumSampleHeight = maximumSampleHeight
    }

    func match(previous: CGImage, next: CGImage) throws -> OverlapMatch {
        guard
            previous.width == next.width,
            previous.height == next.height,
            previous.width > 0,
            previous.height > 1
        else {
            throw ScrollingCaptureError.invalidFrame
        }

        let targetWidth = min(sampleWidth, previous.width)
        let targetHeight = min(maximumSampleHeight, previous.height)
        let previousSample = try LuminanceSample(
            image: previous,
            width: targetWidth,
            height: targetHeight
        )
        let nextSample = try LuminanceSample(
            image: next,
            width: targetWidth,
            height: targetHeight
        )
        let wholeFrameConfidence = Self.confidence(
            lhs: previousSample,
            lhsStartRow: 0,
            rhs: nextSample,
            rhsStartRow: 0,
            rowCount: targetHeight
        )
        if wholeFrameConfidence > 0.99 {
            return OverlapMatch(
                overlapRows: previous.height,
                novelRows: 0,
                confidence: wholeFrameConfidence,
                novelRowRange: previous.height..<previous.height,
                replacedBottomRows: 0
            )
        }

        let maximumChromeRows = max(0, targetHeight / 5)
        let stableTopRows = Self.stableEdgeRows(
            lhs: previousSample,
            rhs: nextSample,
            fromTop: true,
            maximumRows: maximumChromeRows
        )
        let stableBottomRows = Self.stableEdgeRows(
            lhs: previousSample,
            rhs: nextSample,
            fromTop: false,
            maximumRows: maximumChromeRows
        )
        let contentHeight = targetHeight - stableTopRows - stableBottomRows
        guard contentHeight > 8 else {
            throw ScrollingCaptureError.lowConfidence
        }

        let minimumOverlap = max(8, Int((Double(contentHeight) * 0.1).rounded(.up)))
        // A deliberate scroll advances at least 15% of the viewport. Capping the
        // search prevents fixed chrome and repeating page patterns from winning
        // with implausibly large overlaps.
        let maximumOverlap = max(
            minimumOverlap,
            min(contentHeight - 1, Int((Double(contentHeight) * 0.85).rounded(.down)))
        )

        var acceptedOverlap: Int?
        var acceptedConfidence = 0.0
        for overlap in stride(from: maximumOverlap, through: minimumOverlap, by: -1) {
            let candidateConfidence = Self.confidence(
                lhs: previousSample,
                lhsStartRow: stableTopRows + contentHeight - overlap,
                rhs: nextSample,
                rhsStartRow: stableTopRows,
                rowCount: overlap
            )
            if candidateConfidence >= confidenceThreshold {
                acceptedOverlap = overlap
                acceptedConfidence = candidateConfidence
                break
            }
        }

        guard let acceptedOverlap else {
            throw ScrollingCaptureError.lowConfidence
        }

        let rowScale = Double(previous.height) / Double(targetHeight)
        let overlapRows = Int((Double(acceptedOverlap) * rowScale).rounded())
        let stableTopSourceRows = Int((Double(stableTopRows) * rowScale).rounded())
        let stableBottomSourceRows = Int((Double(stableBottomRows) * rowScale).rounded())
        let novelStart = min(
            previous.height - stableBottomSourceRows,
            stableTopSourceRows + overlapRows
        )
        let novelEnd = previous.height

        return OverlapMatch(
            overlapRows: overlapRows,
            novelRows: novelEnd - novelStart,
            confidence: acceptedConfidence,
            novelRowRange: novelStart..<novelEnd,
            replacedBottomRows: stableBottomSourceRows
        )
    }

    private static func stableEdgeRows(
        lhs: LuminanceSample,
        rhs: LuminanceSample,
        fromTop: Bool,
        maximumRows: Int
    ) -> Int {
        guard maximumRows > 0 else { return 0 }
        var stableRows = 0
        for offset in 0..<maximumRows {
            let row = fromTop ? offset : lhs.height - offset - 1
            let rowConfidence = confidence(
                lhs: lhs,
                lhsStartRow: row,
                rhs: rhs,
                rhsStartRow: row,
                rowCount: 1
            )
            guard rowConfidence > 0.99 else { break }
            stableRows += 1
        }
        return stableRows
    }

    private static func confidence(
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

private struct LuminanceSample {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(image: CGImage, width: Int, height: Int) throws {
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
        guard created else { throw ScrollingCaptureError.imageCreation }
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

struct IncrementalImageStitcher {
    private var context: CGContext
    private let maximumPixelHeight: Int
    private(set) var pixelHeight: Int

    var allocatedPixelHeight: Int { context.height }

    init(firstFrame: CGImage, maximumPixelHeight: Int = 30_000) throws {
        guard
            firstFrame.width > 0,
            firstFrame.height > 0,
            firstFrame.height <= maximumPixelHeight
        else {
            throw ScrollingCaptureError.pixelLimit
        }
        let context = try Self.makeContext(
            width: firstFrame.width,
            height: firstFrame.height
        )
        self.context = context
        self.maximumPixelHeight = maximumPixelHeight
        self.pixelHeight = firstFrame.height
        context.draw(
            firstFrame,
            in: CGRect(
                x: 0,
                y: 0,
                width: firstFrame.width,
                height: firstFrame.height
            )
        )
    }

    mutating func append(_ frame: CGImage, match: OverlapMatch) throws {
        guard frame.width == context.width else {
            throw ScrollingCaptureError.invalidFrame
        }
        guard match.novelRows > 0 else { return }
        guard match.replacedBottomRows <= pixelHeight else {
            throw ScrollingCaptureError.invalidFrame
        }
        let addedPixelHeight = match.novelRows - match.replacedBottomRows
        let requiredPixelHeight = pixelHeight + addedPixelHeight
        guard requiredPixelHeight <= maximumPixelHeight else {
            throw ScrollingCaptureError.pixelLimit
        }
        try growIfNeeded(toFit: requiredPixelHeight)
        guard let novelStrip = frame.cropping(
            to: CGRect(
                x: 0,
                y: match.novelRowRange.lowerBound,
                width: frame.width,
                height: match.novelRows
            )
        ) else {
            throw ScrollingCaptureError.imageCreation
        }

        pixelHeight -= match.replacedBottomRows
        context.draw(
            novelStrip,
            in: CGRect(
                x: 0,
                y: context.height - pixelHeight - match.novelRows,
                width: frame.width,
                height: match.novelRows
            )
        )
        pixelHeight += match.novelRows
    }

    func finish() throws -> CGImage {
        guard
            let fullImage = context.makeImage(),
            let result = fullImage.cropping(
                to: CGRect(
                    x: 0,
                    y: 0,
                    width: context.width,
                    height: pixelHeight
                )
            )
        else {
            throw ScrollingCaptureError.imageCreation
        }
        return result
    }

    private mutating func growIfNeeded(toFit requiredPixelHeight: Int) throws {
        guard requiredPixelHeight > context.height else { return }
        let doubledHeight = context.height > maximumPixelHeight / 2
            ? maximumPixelHeight
            : context.height * 2
        let nextHeight = min(
            maximumPixelHeight,
            max(requiredPixelHeight, doubledHeight)
        )
        let existingImage = try finish()
        let nextContext = try Self.makeContext(
            width: context.width,
            height: nextHeight
        )
        nextContext.draw(
            existingImage,
            in: CGRect(
                x: 0,
                y: nextHeight - pixelHeight,
                width: context.width,
                height: pixelHeight
            )
        )
        context = nextContext
    }

    private static func makeContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScrollingCaptureError.imageCreation
        }
        return context
    }
}

protocol WindowScrolling: Sendable {
    func isTrusted(prompt: Bool) -> Bool
    func scroll(windowFrame: CGRect, deltaY: Int) throws
}

struct AccessibilityWindowScroller: WindowScrolling {
    func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(
            [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt,
            ] as CFDictionary
        )
    }

    func scroll(windowFrame: CGRect, deltaY: Int) throws {
        let point = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(deltaY),
            wheel2: 0,
            wheel3: 0
        ) else {
            throw ScrollingCaptureError.eventCreation
        }
        event.location = point
        event.post(tap: .cghidEventTap)
    }
}

struct ScrollingCaptureLimits: Equatable, Sendable {
    var maximumFrames = 100
    var maximumPixelHeight = 30_000
    var maximumDuration: TimeInterval = 60
}

struct ScrollingCaptureProgress: Equatable, Sendable {
    let capturedFrames: Int
    let pixelHeight: Int
}

enum ScrollingCaptureResult: @unchecked Sendable {
    case completed(CapturedImage)
    case partial(CapturedImage, reason: ScrollingCaptureError)
}

final class ScrollingCaptureEngine: @unchecked Sendable {
    typealias Settle = @Sendable () async throws -> Void
    typealias Elapsed = @Sendable () -> TimeInterval
    typealias Progress = @Sendable (ScrollingCaptureProgress) async -> Void

    private let capturer: any ScreenshotCapturing
    private let scroller: any WindowScrolling
    private let limits: ScrollingCaptureLimits
    private let matcher: FrameStitcher
    private let settle: Settle
    private let elapsedOverride: Elapsed?

    init(
        capturer: any ScreenshotCapturing,
        scroller: any WindowScrolling,
        limits: ScrollingCaptureLimits = ScrollingCaptureLimits(),
        matcher: FrameStitcher = FrameStitcher(),
        settle: @escaping Settle = {
            try await Task.sleep(for: .milliseconds(350))
        },
        elapsed: Elapsed? = nil
    ) {
        self.capturer = capturer
        self.scroller = scroller
        self.limits = limits
        self.matcher = matcher
        self.settle = settle
        self.elapsedOverride = elapsed
    }

    func capture(
        windowID: CGWindowID,
        windowFrame: CGRect,
        options: CaptureOptions,
        progress: @escaping Progress
    ) async throws -> ScrollingCaptureResult {
        guard scroller.isTrusted(prompt: true) else {
            throw ScrollingCaptureError.accessibilityDenied
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        let firstCapture = try await capturer.captureWindow(windowID, options: options)
        var previousFrame = firstCapture.image
        var imageStitcher = try IncrementalImageStitcher(
            firstFrame: previousFrame,
            maximumPixelHeight: limits.maximumPixelHeight
        )
        var capturedFrames = 1
        await progress(
            ScrollingCaptureProgress(
                capturedFrames: capturedFrames,
                pixelHeight: imageStitcher.pixelHeight
            )
        )

        func currentElapsed() -> TimeInterval {
            elapsedOverride?() ?? (ProcessInfo.processInfo.systemUptime - startTime)
        }

        func result(reason: ScrollingCaptureError?) throws -> ScrollingCaptureResult {
            let image = try imageStitcher.finish()
            let capture = CapturedImage(
                id: UUID(),
                kind: .scrolling,
                title: "Scrolling capture",
                createdAt: .now,
                image: image,
                pixelSize: PixelSize(width: image.width, height: image.height)
            )
            if let reason {
                return .partial(capture, reason: reason)
            }
            return .completed(capture)
        }

        while true {
            if Task.isCancelled {
                return try result(reason: .cancelled)
            }
            if currentElapsed() >= limits.maximumDuration {
                return try result(reason: .durationLimit)
            }
            if capturedFrames >= limits.maximumFrames {
                return try result(reason: .frameLimit)
            }

            do {
                let delta = -max(1, Int((windowFrame.height * 0.65).rounded()))
                try scroller.scroll(windowFrame: windowFrame, deltaY: delta)
                try await settle()
                try Task.checkCancellation()
            } catch is CancellationError {
                return try result(reason: .cancelled)
            } catch let error as ScrollingCaptureError {
                return try result(reason: error)
            }
            if currentElapsed() >= limits.maximumDuration {
                return try result(reason: .durationLimit)
            }

            let nextCapture = try await capturer.captureWindow(windowID, options: options)
            capturedFrames += 1
            let match: OverlapMatch
            do {
                match = try matcher.match(previous: previousFrame, next: nextCapture.image)
            } catch ScrollingCaptureError.lowConfidence {
                return try result(reason: .lowConfidence)
            }
            if match.novelRows == 0 {
                return try result(reason: nil)
            }

            do {
                try imageStitcher.append(nextCapture.image, match: match)
            } catch ScrollingCaptureError.pixelLimit {
                return try result(reason: .pixelLimit)
            }
            previousFrame = nextCapture.image
            await progress(
                ScrollingCaptureProgress(
                    capturedFrames: capturedFrames,
                    pixelHeight: imageStitcher.pixelHeight
                )
            )
        }
    }
}
