import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
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
    case targetUnavailable
    case noScrollProgress
    case invalidFrame
    case imageCreation
    case widthLimit
    case byteLimit
    case temporaryStorage

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
        case .targetUnavailable:
            "The selected window could not be raised and verified for safe scrolling."
        case .noScrollProgress:
            "The selected window did not scroll beyond its initial viewport."
        case .invalidFrame:
            "The selected window changed size during scrolling capture."
        case .imageCreation:
            "Take a Shot could not create the stitched image."
        case .widthLimit:
            "The selected window is too wide for safe scrolling capture."
        case .byteLimit:
            "Scrolling capture reached its temporary-storage safety limit."
        case .temporaryStorage:
            "Take a Shot could not use temporary storage for scrolling capture."
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
        maximumSampleHeight: Int = 400
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
        guard
            let previousSample = LuminanceSample(
                image: previous,
                width: targetWidth,
                height: targetHeight
            ),
            let nextSample = LuminanceSample(
                image: next,
                width: targetWidth,
                height: targetHeight
            )
        else {
            throw ScrollingCaptureError.imageCreation
        }
        let wholeFrameConfidence = LuminanceCorrelation.confidence(
            lhs: previousSample,
            lhsStartRow: 0,
            rhs: nextSample,
            rhsStartRow: 0,
            rowCount: targetHeight
        )
        if wholeFrameConfidence >= 0.999 {
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
        let maximumOverlap = max(
            minimumOverlap,
            min(contentHeight - 1, Int((Double(contentHeight) * 0.995).rounded(.down)))
        )

        var candidates: [(overlap: Int, confidence: Double)] = []
        for overlap in minimumOverlap...maximumOverlap {
            let candidateConfidence = LuminanceCorrelation.confidence(
                lhs: previousSample,
                lhsStartRow: stableTopRows + contentHeight - overlap,
                rhs: nextSample,
                rhsStartRow: stableTopRows,
                rowCount: overlap
            )
            if candidateConfidence >= confidenceThreshold {
                candidates.append((overlap, candidateConfidence))
            }
        }

        guard !candidates.isEmpty else {
            throw ScrollingCaptureError.lowConfidence
        }
        let clusterGap = max(2, contentHeight / 100)
        var peaks: [(overlap: Int, confidence: Double)] = []
        var cluster: [(overlap: Int, confidence: Double)] = []
        for candidate in candidates {
            if let previous = cluster.last,
               candidate.overlap - previous.overlap > clusterGap {
                peaks.append(Self.strongestCandidate(in: cluster))
                cluster.removeAll(keepingCapacity: true)
            }
            cluster.append(candidate)
        }
        if !cluster.isEmpty {
            peaks.append(Self.strongestCandidate(in: cluster))
        }
        peaks.sort { lhs, rhs in
            if lhs.confidence == rhs.confidence {
                return lhs.overlap > rhs.overlap
            }
            return lhs.confidence > rhs.confidence
        }
        guard let accepted = peaks.first else {
            throw ScrollingCaptureError.lowConfidence
        }
        if peaks.dropFirst().contains(where: { competingPeak in
            accepted.confidence - competingPeak.confidence <= 0.015
        }) {
            throw ScrollingCaptureError.lowConfidence
        }

        let rowScale = Double(previous.height) / Double(targetHeight)
        let overlapRows = Int((Double(accepted.overlap) * rowScale).rounded())
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
            confidence: accepted.confidence,
            novelRowRange: novelStart..<novelEnd,
            replacedBottomRows: stableBottomSourceRows
        )
    }

    private static func strongestCandidate(
        in cluster: [(overlap: Int, confidence: Double)]
    ) -> (overlap: Int, confidence: Double) {
        cluster.max { lhs, rhs in
            if lhs.confidence == rhs.confidence {
                return lhs.overlap < rhs.overlap
            }
            return lhs.confidence < rhs.confidence
        }!
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
            let rowConfidence = LuminanceCorrelation.confidence(
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

}

final class IncrementalImageStitcher {
    static let defaultMaximumOutputBytes = 128 * 1_024 * 1_024
    static let defaultMaximumPixelWidth = 8_192

    let temporaryArtifactDirectory: URL
    private let rawFileURL: URL
    private let width: Int
    private let bytesPerRow: Int
    private let maximumPixelHeight: Int
    private let maximumOutputBytes: Int
    private var fileHandle: FileHandle?
    private var isFinished = false
    private(set) var pixelHeight: Int
    private(set) var peakWorkingAllocationBytes = 0

    var outputByteCount: Int { pixelHeight * bytesPerRow }

    init(
        firstFrame: CGImage,
        maximumPixelHeight: Int = 30_000,
        maximumPixelWidth: Int = IncrementalImageStitcher.defaultMaximumPixelWidth,
        maximumOutputBytes: Int = IncrementalImageStitcher.defaultMaximumOutputBytes,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        guard firstFrame.width > 0, firstFrame.height > 0 else {
            throw ScrollingCaptureError.invalidFrame
        }
        guard firstFrame.width <= maximumPixelWidth else {
            throw ScrollingCaptureError.widthLimit
        }
        guard firstFrame.height <= maximumPixelHeight else {
            throw ScrollingCaptureError.pixelLimit
        }
        guard
            firstFrame.width <= Int.max / 4,
            firstFrame.height <= maximumOutputBytes / (firstFrame.width * 4)
        else {
            throw ScrollingCaptureError.byteLimit
        }

        width = firstFrame.width
        bytesPerRow = firstFrame.width * 4
        self.maximumPixelHeight = maximumPixelHeight
        self.maximumOutputBytes = maximumOutputBytes
        pixelHeight = firstFrame.height
        temporaryArtifactDirectory = temporaryDirectory.appendingPathComponent(
            "TakeAShotScrolling-\(UUID().uuidString)",
            isDirectory: true
        )
        rawFileURL = temporaryArtifactDirectory.appendingPathComponent("pixels.rgba")

        let firstFrameData = try Self.rgbaData(for: firstFrame)
        peakWorkingAllocationBytes = firstFrameData.count
        do {
            try FileManager.default.createDirectory(
                at: temporaryArtifactDirectory,
                withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(
                atPath: rawFileURL.path,
                contents: nil
            ) else {
                throw ScrollingCaptureError.temporaryStorage
            }
            let handle = try FileHandle(forUpdating: rawFileURL)
            try handle.write(contentsOf: firstFrameData)
            fileHandle = handle
        } catch {
            try? FileManager.default.removeItem(at: temporaryArtifactDirectory)
            if let captureError = error as? ScrollingCaptureError {
                throw captureError
            }
            throw ScrollingCaptureError.temporaryStorage
        }
    }

    deinit {
        cleanupTemporaryArtifact()
    }

    func append(_ frame: CGImage, match: OverlapMatch) throws {
        guard !isFinished, frame.width == width else {
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
        guard requiredPixelHeight <= maximumOutputBytes / bytesPerRow else {
            throw ScrollingCaptureError.byteLimit
        }
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

        let novelData = try Self.rgbaData(for: novelStrip)
        peakWorkingAllocationBytes = max(peakWorkingAllocationBytes, novelData.count)
        guard let fileHandle else {
            throw ScrollingCaptureError.temporaryStorage
        }
        do {
            let retainedHeight = pixelHeight - match.replacedBottomRows
            let retainedBytes = retainedHeight * bytesPerRow
            try fileHandle.truncate(atOffset: UInt64(retainedBytes))
            try fileHandle.seek(toOffset: UInt64(retainedBytes))
            try fileHandle.write(contentsOf: novelData)
            pixelHeight = requiredPixelHeight
        } catch {
            throw ScrollingCaptureError.temporaryStorage
        }
    }

    func finish() throws -> CGImage {
        guard !isFinished, let fileHandle else {
            throw ScrollingCaptureError.temporaryStorage
        }
        do {
            try fileHandle.synchronize()
            try fileHandle.close()
        } catch {
            throw ScrollingCaptureError.temporaryStorage
        }
        self.fileHandle = nil

        let image: CGImage
        do {
            image = try RawPixelFile.cgImage(
                mappingFileAt: rawFileURL,
                width: width,
                height: pixelHeight,
                bytesPerRow: bytesPerRow
            )
        } catch RawPixelFileError.mappingFailed {
            throw ScrollingCaptureError.temporaryStorage
        } catch {
            throw ScrollingCaptureError.imageCreation
        }

        isFinished = true
        cleanupTemporaryArtifact()
        return image
    }

    private func cleanupTemporaryArtifact() {
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager.default.removeItem(at: temporaryArtifactDirectory)
    }

    private static func rgbaData(for image: CGImage) throws -> Data {
        do {
            return try RawPixelFile.rgbaData(for: image)
        } catch RawPixelFileError.dimensionsTooLarge {
            throw ScrollingCaptureError.byteLimit
        } catch {
            throw ScrollingCaptureError.imageCreation
        }
    }
}

struct ScrollingWindowTarget: Equatable, Sendable {
    let windowID: CGWindowID
    let title: String
    let frame: CGRect

    func updating(frame: CGRect) -> ScrollingWindowTarget {
        ScrollingWindowTarget(windowID: windowID, title: title, frame: frame)
    }
}

struct ScrollEventRequest: Equatable, Sendable {
    let location: CGPoint
    let deltaY: Int
}

protocol WindowTargeting: Sendable {
    func raiseAndResolveFrame(for target: ScrollingWindowTarget) throws -> CGRect
    func isTopmost(windowID: CGWindowID, at point: CGPoint) -> Bool
}

protocol ScrollEventPosting: Sendable {
    func post(_ request: ScrollEventRequest) throws
}

protocol WindowScrolling: Sendable {
    func isTrusted(prompt: Bool) -> Bool
    func prepare(target: ScrollingWindowTarget) throws -> ScrollingWindowTarget
    func scroll(
        target: ScrollingWindowTarget,
        deltaY: Int
    ) throws -> ScrollingWindowTarget
}

struct AccessibilityWindowScroller: WindowScrolling {
    private let targeting: any WindowTargeting
    private let eventPoster: any ScrollEventPosting

    init(
        targeting: any WindowTargeting = SystemWindowTargeting(),
        eventPoster: any ScrollEventPosting = CGScrollEventPoster()
    ) {
        self.targeting = targeting
        self.eventPoster = eventPoster
    }

    func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(
            [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt,
            ] as CFDictionary
        )
    }

    func prepare(target: ScrollingWindowTarget) throws -> ScrollingWindowTarget {
        let refreshedFrame = try targeting.raiseAndResolveFrame(for: target)
        let point = CGPoint(x: refreshedFrame.midX, y: refreshedFrame.midY)
        guard targeting.isTopmost(windowID: target.windowID, at: point) else {
            throw ScrollingCaptureError.targetUnavailable
        }
        return target.updating(frame: refreshedFrame)
    }

    func scroll(
        target: ScrollingWindowTarget,
        deltaY: Int
    ) throws -> ScrollingWindowTarget {
        let refreshedTarget = try prepare(target: target)
        try eventPoster.post(
            ScrollEventRequest(
                location: CGPoint(
                    x: refreshedTarget.frame.midX,
                    y: refreshedTarget.frame.midY
                ),
                deltaY: deltaY
            )
        )
        return refreshedTarget
    }
}

private struct CGScrollEventPoster: ScrollEventPosting {
    func post(_ request: ScrollEventRequest) throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(request.deltaY),
            wheel2: 0,
            wheel3: 0
        ) else {
            throw ScrollingCaptureError.eventCreation
        }
        event.location = request.location
        event.post(tap: .cghidEventTap)
    }
}

private struct SystemWindowTargeting: WindowTargeting {
    func raiseAndResolveFrame(for target: ScrollingWindowTarget) throws -> CGRect {
        guard let snapshot = Self.windowSnapshot(for: target.windowID) else {
            throw ScrollingCaptureError.targetUnavailable
        }
        let application = AXUIElementCreateApplication(snapshot.processID)
        var windowsValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application,
                kAXWindowsAttribute as CFString,
                &windowsValue
            ) == .success,
            let accessibilityWindows = windowsValue as? [AXUIElement],
            let accessibilityWindow = accessibilityWindows.first(where: { window in
                Self.matches(window, snapshot: snapshot)
            })
        else {
            throw ScrollingCaptureError.targetUnavailable
        }

        NSRunningApplication(processIdentifier: snapshot.processID)?.activate(
            options: []
        )
        guard AXUIElementPerformAction(
            accessibilityWindow,
            kAXRaiseAction as CFString
        ) == .success else {
            throw ScrollingCaptureError.targetUnavailable
        }
        guard let refreshedSnapshot = Self.windowSnapshot(for: target.windowID) else {
            throw ScrollingCaptureError.targetUnavailable
        }
        return refreshedSnapshot.frame
    }

    func isTopmost(windowID: CGWindowID, at point: CGPoint) -> Bool {
        guard let windows = Self.onScreenWindowInfo() else { return false }
        for window in windows {
            guard
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds),
                frame.contains(point)
            else { continue }
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01 else { continue }
            guard let number = window[kCGWindowNumber as String] as? NSNumber else {
                return false
            }
            return CGWindowID(number.uint32Value) == windowID
        }
        return false
    }

    private static func matches(
        _ accessibilityWindow: AXUIElement,
        snapshot: SystemWindowSnapshot
    ) -> Bool {
        guard let frame = accessibilityFrame(of: accessibilityWindow) else {
            return false
        }
        let frameMatches = abs(frame.minX - snapshot.frame.minX) <= 8
            && abs(frame.minY - snapshot.frame.minY) <= 8
            && abs(frame.width - snapshot.frame.width) <= 8
            && abs(frame.height - snapshot.frame.height) <= 8
        guard frameMatches else { return false }
        guard
            !snapshot.title.isEmpty,
            let title = accessibilityString(
                accessibilityWindow,
                attribute: kAXTitleAttribute as CFString
            ),
            !title.isEmpty
        else {
            return true
        }
        return title == snapshot.title
    }

    private static func accessibilityFrame(of window: AXUIElement) -> CGRect? {
        guard
            let position = accessibilityPoint(
                window,
                attribute: kAXPositionAttribute as CFString
            ),
            let size = accessibilitySize(
                window,
                attribute: kAXSizeAttribute as CFString
            )
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func accessibilityPoint(
        _ element: AXUIElement,
        attribute: CFString
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func accessibilitySize(
        _ element: AXUIElement,
        attribute: CFString
    ) -> CGSize? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func accessibilityString(
        _ element: AXUIElement,
        attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func windowSnapshot(for windowID: CGWindowID) -> SystemWindowSnapshot? {
        guard let windows = onScreenWindowInfo() else { return nil }
        return windows.compactMap { window -> SystemWindowSnapshot? in
            guard
                let number = window[kCGWindowNumber as String] as? NSNumber,
                CGWindowID(number.uint32Value) == windowID,
                let processID = window[kCGWindowOwnerPID as String] as? NSNumber,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return SystemWindowSnapshot(
                processID: pid_t(processID.int32Value),
                title: window[kCGWindowName as String] as? String ?? "",
                frame: frame
            )
        }.first
    }

    private static func onScreenWindowInfo() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]]
    }
}

private struct SystemWindowSnapshot {
    let processID: pid_t
    let title: String
    let frame: CGRect
}

struct ScrollingCaptureLimits: Equatable, Sendable {
    var maximumFrames: Int
    var maximumPixelHeight: Int
    var maximumDuration: TimeInterval
    var maximumPixelWidth: Int
    var maximumOutputBytes: Int

    init(
        maximumFrames: Int = 100,
        maximumPixelHeight: Int = 30_000,
        maximumDuration: TimeInterval = 60,
        maximumPixelWidth: Int = IncrementalImageStitcher.defaultMaximumPixelWidth,
        maximumOutputBytes: Int = IncrementalImageStitcher.defaultMaximumOutputBytes
    ) {
        self.maximumFrames = maximumFrames
        self.maximumPixelHeight = maximumPixelHeight
        self.maximumDuration = maximumDuration
        self.maximumPixelWidth = maximumPixelWidth
        self.maximumOutputBytes = maximumOutputBytes
    }
}

struct ScrollingCaptureProgress: Equatable, Sendable {
    let capturedFrames: Int
    let pixelHeight: Int
}

enum ScrollingCaptureResult: @unchecked Sendable {
    case completed(CapturedImage)
    case partial(CapturedImage, reason: ScrollingCaptureError)

    var requiresPersistenceConfirmation: Bool {
        if case .partial = self { return true }
        return false
    }
}

final class ScrollingCaptureEngine: @unchecked Sendable {
    typealias Settle = @Sendable () async throws -> Void
    typealias Elapsed = @Sendable () -> TimeInterval
    typealias Progress = @Sendable (ScrollingCaptureProgress) async -> Void

    private let capturer: any ScreenshotCapturing
    private let scroller: any WindowScrolling
    private let limits: ScrollingCaptureLimits
    private let matcher: FrameStitcher
    private let temporaryDirectory: URL
    private let settle: Settle
    private let elapsedOverride: Elapsed?

    init(
        capturer: any ScreenshotCapturing,
        scroller: any WindowScrolling,
        limits: ScrollingCaptureLimits = ScrollingCaptureLimits(),
        matcher: FrameStitcher = FrameStitcher(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        settle: @escaping Settle = {
            try await Task.sleep(for: .milliseconds(350))
        },
        elapsed: Elapsed? = nil
    ) {
        self.capturer = capturer
        self.scroller = scroller
        self.limits = limits
        self.matcher = matcher
        self.temporaryDirectory = temporaryDirectory
        self.settle = settle
        self.elapsedOverride = elapsed
    }

    func capture(
        target: ScrollingWindowTarget,
        options: CaptureOptions,
        progress: @escaping Progress
    ) async throws -> ScrollingCaptureResult {
        guard scroller.isTrusted(prompt: true) else {
            throw ScrollingCaptureError.accessibilityDenied
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        var currentTarget = try scroller.prepare(target: target)
        let firstCapture = try await capturer.captureWindow(
            currentTarget.windowID,
            options: options
        )
        var previousFrame = firstCapture.image
        let imageStitcher = try IncrementalImageStitcher(
            firstFrame: previousFrame,
            maximumPixelHeight: limits.maximumPixelHeight,
            maximumPixelWidth: limits.maximumPixelWidth,
            maximumOutputBytes: limits.maximumOutputBytes,
            temporaryDirectory: temporaryDirectory
        )
        var capturedFrames = 1
        var acceptedNovelStrips = 0
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
                let delta = -max(1, Int((currentTarget.frame.height * 0.65).rounded()))
                currentTarget = try scroller.scroll(
                    target: currentTarget,
                    deltaY: delta
                )
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

            let nextCapture: CapturedImage
            do {
                nextCapture = try await capturer.captureWindow(
                    currentTarget.windowID,
                    options: options
                )
            } catch is CancellationError {
                return try result(reason: .cancelled)
            }
            capturedFrames += 1
            let match: OverlapMatch
            do {
                match = try matcher.match(previous: previousFrame, next: nextCapture.image)
            } catch let error as ScrollingCaptureError {
                return try result(reason: error)
            }
            if match.novelRows == 0 {
                return try result(
                    reason: acceptedNovelStrips == 0 ? .noScrollProgress : nil
                )
            }

            do {
                try imageStitcher.append(nextCapture.image, match: match)
            } catch let error as ScrollingCaptureError
                where error == .pixelLimit || error == .byteLimit {
                return try result(reason: error)
            }
            acceptedNovelStrips += 1
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
