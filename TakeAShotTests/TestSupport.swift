import AppKit
import XCTest
@testable import TakeAShot

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

actor StubScreenCaptureKitProvider: ScreenCaptureKitProviding {
    let snapshot: ScreenCaptureSourceSnapshot
    let image: CGImage
    private(set) var displayRequests: [ScreenCaptureDisplayRequest] = []
    private(set) var windowRequests: [ScreenCaptureWindowRequest] = []

    init(snapshot: ScreenCaptureSourceSnapshot, image: CGImage) {
        self.snapshot = snapshot
        self.image = image
    }

    func sourceSnapshot() async throws -> ScreenCaptureSourceSnapshot {
        snapshot
    }

    func captureDisplay(_ request: ScreenCaptureDisplayRequest) async throws -> CGImage {
        displayRequests.append(request)
        return image
    }

    func captureWindow(_ request: ScreenCaptureWindowRequest) async throws -> CGImage {
        windowRequests.append(request)
        return image
    }
}

/// Fake `ScreenCaptureKitProviding` overriding `supportsWindowExclusion()` — exercises Manual
/// Scroll Capture's fail-fast probe (PLAN.md §5), which every other fake defaults to `true`.
actor ExclusionProbeStubProvider: ScreenCaptureKitProviding {
    let snapshot: ScreenCaptureSourceSnapshot
    let image: CGImage
    private let supportsWindowExclusionOverride: Bool

    init(snapshot: ScreenCaptureSourceSnapshot, image: CGImage, supportsWindowExclusion: Bool) {
        self.snapshot = snapshot
        self.image = image
        supportsWindowExclusionOverride = supportsWindowExclusion
    }

    func sourceSnapshot() async throws -> ScreenCaptureSourceSnapshot { snapshot }
    func captureDisplay(_ request: ScreenCaptureDisplayRequest) async throws -> CGImage { image }
    func captureWindow(_ request: ScreenCaptureWindowRequest) async throws -> CGImage { image }
    nonisolated func supportsWindowExclusion() -> Bool { supportsWindowExclusionOverride }
}

@MainActor
final class RecordingCaptureIntentHandler: CaptureIntentHandling {
    private(set) var intents: [CaptureIntent] = []
    var onIntent: ((CaptureIntent) -> Void)?

    func beginAreaSelection(options: CaptureOptions) {
        record(.areaSelection)
    }

    func beginWindowPicker(options: CaptureOptions) {
        record(.windowPicker)
    }

    func beginDisplayCapture(options: CaptureOptions) {
        record(.display)
    }

    func beginScrollingWindowPicker(options: CaptureOptions) {
        record(.scrollingWindowPicker)
    }

    func beginManualScrollCapture(options: CaptureOptions) {
        record(.scrollingAreaSelection)
    }

    func beginRecordingPicker(options: CaptureOptions) {
        record(.recordingPicker)
    }

    private func record(_ intent: CaptureIntent) {
        intents.append(intent)
        onIntent?(intent)
    }
}

final class CaptureEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    var events: [String] {
        lock.withLock { storedEvents }
    }

    func append(_ event: String) {
        lock.withLock { storedEvents.append(event) }
    }
}

struct StubScreenshotCapturer: ScreenshotCapturing {
    let capturedImage: CapturedImage

    func sources() async throws -> CaptureSources {
        CaptureSources(displays: [], windows: [])
    }

    func captureArea(
        _ rect: CGRect,
        display: DisplayGeometry,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        capturedImage
    }

    func captureDisplay(
        _ displayID: CGDirectDisplayID,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        capturedImage
    }

    func captureWindow(
        _ windowID: CGWindowID,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        capturedImage
    }
}

actor StubCapturePersistence: CapturePersisting {
    let recorder: CaptureEventRecorder
    let error: Error?

    init(recorder: CaptureEventRecorder, error: Error? = nil) {
        self.recorder = recorder
        self.error = error
    }

    func persistCapture(_ image: CapturedImage) async throws {
        recorder.append("persist")
        if let error { throw error }
    }
}

@MainActor
final class StubCapturePublisher: CapturePublishing {
    let recorder: CaptureEventRecorder
    private(set) var publications: [CapturePublication] = []

    init(recorder: CaptureEventRecorder) {
        self.recorder = recorder
    }

    func publish(_ publication: CapturePublication) {
        publications.append(publication)
        recorder.append("publish")
    }
}

enum TestCaptureError: Error, Equatable {
    case persistence
}

/// Records every `persistCapture` call, including the annotations/renderedImage variant, so tests
/// can assert what `CapturePipeline.captureArea` threaded through for Quick Annotation captures
/// (PLAN.md §9).
actor RecordingAnnotationPersistence: CapturePersisting {
    struct Call {
        let imageID: UUID
        let annotations: AnnotationDocument?
        let renderedImage: CGImage?
    }

    private(set) var calls: [Call] = []

    func persistCapture(_ image: CapturedImage) async throws {
        calls.append(Call(imageID: image.id, annotations: nil, renderedImage: nil))
    }

    func persistCapture(
        _ image: CapturedImage,
        annotations: AnnotationDocument?,
        renderedImage: CGImage?
    ) async throws {
        calls.append(Call(imageID: image.id, annotations: annotations, renderedImage: renderedImage))
    }

    func rollbackPersistedCapture(_ outcome: CapturePersistenceOutcome) async throws {}
}

struct StubAnnotationRenderService: AnnotationRenderServicing {
    let renderedImage: CGImage

    func render(capture: CapturedImage, document: AnnotationDocument) async throws -> CGImage {
        renderedImage
    }
}
