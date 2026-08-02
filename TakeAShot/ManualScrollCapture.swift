import CoreGraphics
import Foundation

enum ManualScrollCaptureError: LocalizedError, Equatable, Sendable {
    case invalidFrame
    case imageCreation
    case temporaryStorage
    case pixelLimit
    case widthLimit
    case byteLimit
    case durationLimit(TimeInterval)
    case lowConfidence
    case frameCaptureFailed

    var errorDescription: String? {
        switch self {
        case .invalidFrame:
            "Manual Scroll Capture received a frame that did not match the selected region."
        case .imageCreation:
            "Take a Shot could not create the stitched image."
        case .temporaryStorage:
            "Take a Shot could not use temporary storage for Manual Scroll Capture."
        case .pixelLimit:
            "Manual Scroll Capture reached the 30,000-pixel safety limit."
        case .widthLimit:
            "The selected region is too wide for safe Manual Scroll Capture."
        case .byteLimit:
            "Manual Scroll Capture reached its temporary-storage safety limit."
        case .durationLimit(let seconds):
            "Manual Scroll Capture reached its \(Int((seconds / 60).rounded()))-minute safety limit."
        case .lowConfidence:
            "The captured frames could not be matched reliably."
        case .frameCaptureFailed:
            "Take a Shot stopped receiving screen frames — check Screen Recording permission."
        }
    }
}

/// Signed vertical-shift matcher between two consecutive Manual Scroll Capture frames, wrapping
/// the shared correlation primitives (`LuminanceSample`/`LuminanceCorrelation`) that
/// `FrameStitcher` also uses (PLAN.md §4). Everything here is top-down: row 0 is the visual top
/// of a frame, rows grow downward — the same convention `StitchedRowConversion` and
/// `ManualScrollViewport` use for the session's stitched coordinate space.
///
/// Deliberately does not delegate to `FrameStitcher.match`: that API is one-directional (previous
/// frame's bottom against next frame's top) and its fast identical-frame path requires ≥0.999
/// confidence — a noisy-but-stationary spinner/video/cursor would clear neither that fast path nor
/// its (deliberately full-overlap-excluding) directional search, so it would report "no match"
/// instead of the `shift == 0` in-place case this matcher needs. `FrameShiftMatcher` runs one
/// unified search across signed shifts (including zero) using the same shared sampling and
/// single-clear-peak clustering approach as `FrameStitcher`, generalized to both directions.
struct FrameShiftMatcher: Sendable {
    private let confidenceThreshold: Double
    private let sampleWidth: Int
    private let maximumSampleHeight: Int
    private let ambiguityMargin: Double

    init(
        confidenceThreshold: Double = 0.92,
        sampleWidth: Int = 32,
        maximumSampleHeight: Int = 400,
        ambiguityMargin: Double = 0.015
    ) {
        self.confidenceThreshold = confidenceThreshold
        self.sampleWidth = sampleWidth
        self.maximumSampleHeight = maximumSampleHeight
        self.ambiguityMargin = ambiguityMargin
    }

    /// Signed vertical shift from `previous` to `next`, in `previous`/`next`'s own full-resolution
    /// pixels — positive means content scrolled down (the viewport moved down), negative means it
    /// scrolled up, `0` means the frame changed but its content did not move (an in-place change:
    /// PLAN.md §4 — spinner, video, cursor). Returns `nil` when no candidate shift clears
    /// `confidenceThreshold`, or when two candidate shifts land within `ambiguityMargin` of each
    /// other (single-clear-peak rule — no tie-breaking, reject).
    func shift(from previous: CGImage, to next: CGImage) throws -> Int? {
        guard
            previous.width == next.width,
            previous.height == next.height,
            previous.width > 0,
            previous.height > 1
        else {
            throw ManualScrollCaptureError.invalidFrame
        }

        let targetWidth = min(sampleWidth, previous.width)
        let targetHeight = min(maximumSampleHeight, previous.height)
        guard
            let previousSample = LuminanceSample(image: previous, width: targetWidth, height: targetHeight),
            let nextSample = LuminanceSample(image: next, width: targetWidth, height: targetHeight)
        else {
            throw ManualScrollCaptureError.imageCreation
        }

        let minimumOverlap = max(8, Int((Double(targetHeight) * 0.1).rounded(.up)))
        let maximumShift = targetHeight - minimumOverlap
        guard maximumShift >= 0 else { return nil }

        var candidates: [(shift: Int, confidence: Double)] = []
        for candidateShift in -maximumShift...maximumShift {
            let overlapHeight = targetHeight - abs(candidateShift)
            guard overlapHeight >= minimumOverlap else { continue }
            let nextStart = max(0, -candidateShift)
            let previousStart = max(0, candidateShift)
            let candidateConfidence = LuminanceCorrelation.confidence(
                lhs: previousSample,
                lhsStartRow: previousStart,
                rhs: nextSample,
                rhsStartRow: nextStart,
                rowCount: overlapHeight
            )
            if candidateConfidence >= confidenceThreshold {
                candidates.append((candidateShift, candidateConfidence))
            }
        }
        guard !candidates.isEmpty else { return nil }

        let clusterGap = max(2, targetHeight / 100)
        var peaks: [(shift: Int, confidence: Double)] = []
        var cluster: [(shift: Int, confidence: Double)] = []
        for candidate in candidates {
            if let previousCandidate = cluster.last,
               candidate.shift - previousCandidate.shift > clusterGap {
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
                return abs(lhs.shift) < abs(rhs.shift)
            }
            return lhs.confidence > rhs.confidence
        }
        guard let accepted = peaks.first else { return nil }
        if peaks.dropFirst().contains(where: { competing in
            accepted.confidence - competing.confidence <= ambiguityMargin
        }) {
            return nil
        }

        let rowScale = Double(previous.height) / Double(targetHeight)
        return Int((Double(accepted.shift) * rowScale).rounded())
    }

    private static func strongestCandidate(
        in cluster: [(shift: Int, confidence: Double)]
    ) -> (shift: Int, confidence: Double) {
        cluster.max { lhs, rhs in
            if lhs.confidence == rhs.confidence {
                return abs(lhs.shift) > abs(rhs.shift)
            }
            return lhs.confidence < rhs.confidence
        }!
    }
}

/// Tracks a Manual Scroll Capture session's position in its own stitched coordinate space —
/// top-down, row 0 is the visual top of the eventual output, rows grow downward (PLAN.md §4).
/// This convention governs all matcher/viewport/extent/strip/budget math; the only place Core
/// Graphics pixel data is actually touched is `StitchedRowConversion`, at the single tested
/// crop boundary.
///
/// The seed occupies `[0, seedHeight)`. `viewportOffset` is the stitched-space row of the current
/// viewport's top edge; `extent` is the union of stitched rows captured so far.
struct ManualScrollViewport: Equatable {
    private(set) var viewportOffset: Int
    private(set) var extentTop: Int
    private(set) var extentBottom: Int
    let frameHeight: Int

    init(seedHeight: Int, frameHeight: Int) {
        viewportOffset = 0
        extentTop = 0
        extentBottom = seedHeight
        self.frameHeight = frameHeight
    }

    var extent: Range<Int> { extentTop..<extentBottom }

    /// Applies an accepted nonzero shift and returns the stitched-space row ranges newly revealed
    /// below (`down`) and/or above (`up`) the existing extent. Rows already inside the extent —
    /// including a return over the seed or previously captured content — are never re-returned:
    /// reversal and "already captured" dedupe fall out of this comparison alone, no clamping rules
    /// needed (PLAN.md §4).
    mutating func apply(shift: Int) -> (down: Range<Int>?, up: Range<Int>?) {
        viewportOffset += shift
        let viewportRange = viewportOffset..<(viewportOffset + frameHeight)
        var down: Range<Int>?
        var up: Range<Int>?
        if viewportRange.upperBound > extentBottom {
            down = extentBottom..<viewportRange.upperBound
            extentBottom = viewportRange.upperBound
        }
        if viewportRange.lowerBound < extentTop {
            up = viewportRange.lowerBound..<extentTop
            extentTop = viewportRange.lowerBound
        }
        return (down, up)
    }
}

/// Single tested seam between the session's top-down stitched coordinate space and a captured
/// frame's own `CGImage` cropping rect. `CGImage.cropping(to:)` is documented as taking its rect's
/// origin at the image's upper-left — the same row-0-is-top orientation stitched space already
/// uses — so the only real arithmetic here is the offset subtraction; it stays one seam (instead
/// of being re-derived at every call site) so a genuine CG-orientation surprise would only need
/// fixing in one place, and so it is independently testable.
enum StitchedRowConversion {
    static func frameCropRect(
        stitchedRange: Range<Int>,
        frameStitchedTop: Int,
        frameWidth: Int
    ) -> CGRect {
        let localTop = stitchedRange.lowerBound - frameStitchedTop
        return CGRect(x: 0, y: localTop, width: frameWidth, height: stitchedRange.count)
    }
}

/// Single global accounting object for a Manual Scroll Capture session (PLAN.md §6): tracks total
/// pixel height, width, and byte usage across the seed and both `StripStore`s combined, with the
/// same numeric safety caps as Auto Scrolling Capture. The seed is reserved exactly once, at
/// session start; every other row range goes through `reserve(additionalHeight:)`.
struct ManualScrollBudget: Sendable {
    static let defaultMaximumPixelHeight = 30_000
    static let defaultMaximumPixelWidth = 8_192
    static let defaultMaximumOutputBytes = 128 * 1_024 * 1_024

    let maximumPixelHeight: Int
    let maximumPixelWidth: Int
    let maximumOutputBytes: Int
    private(set) var totalPixelHeight = 0
    private(set) var width: Int?

    init(
        maximumPixelHeight: Int = ManualScrollBudget.defaultMaximumPixelHeight,
        maximumPixelWidth: Int = ManualScrollBudget.defaultMaximumPixelWidth,
        maximumOutputBytes: Int = ManualScrollBudget.defaultMaximumOutputBytes
    ) {
        self.maximumPixelHeight = maximumPixelHeight
        self.maximumPixelWidth = maximumPixelWidth
        self.maximumOutputBytes = maximumOutputBytes
    }

    mutating func reserveSeed(width: Int, height: Int) throws {
        guard width <= maximumPixelWidth else { throw ManualScrollCaptureError.widthLimit }
        self.width = width
        try reserve(additionalHeight: height)
    }

    mutating func reserve(additionalHeight: Int) throws {
        guard additionalHeight > 0 else { return }
        guard let width else { throw ManualScrollCaptureError.invalidFrame }
        let requiredHeight = totalPixelHeight + additionalHeight
        guard requiredHeight <= maximumPixelHeight else { throw ManualScrollCaptureError.pixelLimit }
        guard requiredHeight <= maximumOutputBytes / (width * 4) else { throw ManualScrollCaptureError.byteLimit }
        totalPixelHeight = requiredHeight
    }
}

/// One strip appended to a `StripStore`: where it sits in the session's stitched coordinate space,
/// and where its bytes live in the store's backing file.
struct ManualScrollStrip: Equatable, Sendable {
    let stitchedRange: Range<Int>
    let byteOffset: Int
    let byteCount: Int
}

/// Append-only temp-file-backed store for one direction segment ("up" or "down") of a Manual
/// Scroll Capture session (PLAN.md §6): a single backing file plus in-memory strip metadata
/// (stitched-space range, byte offset, discovery order). `IncrementalImageStitcher` is not used by
/// Manual Scroll Capture — only the `RawPixelFile` primitives it also extracts from.
final class StripStore {
    private(set) var strips: [ManualScrollStrip] = []
    let width: Int
    let temporaryArtifactDirectory: URL
    private let fileURL: URL
    private var fileHandle: FileHandle?
    private var nextByteOffset = 0
    private var isCleanedUp = false

    init(width: Int, temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws {
        self.width = width
        temporaryArtifactDirectory = temporaryDirectory.appendingPathComponent(
            "TakeAShotManualScroll-\(UUID().uuidString)",
            isDirectory: true
        )
        fileURL = temporaryArtifactDirectory.appendingPathComponent("strip.rgba")
        do {
            try FileManager.default.createDirectory(
                at: temporaryArtifactDirectory,
                withIntermediateDirectories: true
            )
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw ManualScrollCaptureError.temporaryStorage
            }
            fileHandle = try FileHandle(forWritingTo: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryArtifactDirectory)
            if let captureError = error as? ManualScrollCaptureError { throw captureError }
            throw ManualScrollCaptureError.temporaryStorage
        }
    }

    deinit {
        cleanup()
    }

    func append(_ image: CGImage, stitchedRange: Range<Int>) throws {
        guard image.width == width, image.height == stitchedRange.count else {
            throw ManualScrollCaptureError.invalidFrame
        }
        guard let fileHandle else { throw ManualScrollCaptureError.temporaryStorage }
        let data: Data
        do {
            data = try RawPixelFile.rgbaData(for: image)
        } catch RawPixelFileError.dimensionsTooLarge {
            throw ManualScrollCaptureError.byteLimit
        } catch {
            throw ManualScrollCaptureError.imageCreation
        }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            throw ManualScrollCaptureError.temporaryStorage
        }
        strips.append(
            ManualScrollStrip(stitchedRange: stitchedRange, byteOffset: nextByteOffset, byteCount: data.count)
        )
        nextByteOffset += data.count
    }

    func data(for strip: ManualScrollStrip) throws -> Data {
        guard let readHandle = try? FileHandle(forReadingFrom: fileURL) else {
            throw ManualScrollCaptureError.temporaryStorage
        }
        defer { try? readHandle.close() }
        do {
            try readHandle.seek(toOffset: UInt64(strip.byteOffset))
            guard
                let data = try readHandle.read(upToCount: strip.byteCount),
                data.count == strip.byteCount
            else {
                throw ManualScrollCaptureError.temporaryStorage
            }
            return data
        } catch let error as ManualScrollCaptureError {
            throw error
        } catch {
            throw ManualScrollCaptureError.temporaryStorage
        }
    }

    var isBackingFilePresent: Bool {
        FileManager.default.fileExists(atPath: temporaryArtifactDirectory.path)
    }

    func cleanup() {
        guard !isCleanedUp else { return }
        isCleanedUp = true
        try? fileHandle?.close()
        fileHandle = nil
        try? FileManager.default.removeItem(at: temporaryArtifactDirectory)
    }
}

/// Compute/storage worker for one Manual Scroll Capture session: owns the matcher,
/// viewport/extent, both `StripStore`s, and the shared budget, and composes the final image at
/// Done (PLAN.md §4/§6). Session lifecycle/ownership — the `@MainActor` controller that owns the
/// HUD, border window, Carbon hotkey, and generation token, and the actor boundary wrapping this
/// worker — is session/UI wiring for a later phase; this type is deliberately just the tested
/// compute/storage core it will delegate to.
final class ManualScrollCaptureWorker {
    static let unmatchedDegradedThreshold = 20

    private(set) var previousFrame: CGImage
    private(set) var viewport: ManualScrollViewport
    private(set) var budget: ManualScrollBudget
    private(set) var consecutiveUnmatchedCount = 0
    private(set) var isDegraded = false

    private let seed: CGImage
    private let matcher: FrameShiftMatcher
    private let upStore: StripStore
    private let downStore: StripStore
    private let temporaryDirectory: URL

    init(
        seed: CGImage,
        matcher: FrameShiftMatcher = FrameShiftMatcher(),
        budget: ManualScrollBudget = ManualScrollBudget(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        guard seed.width > 0, seed.height > 0 else {
            throw ManualScrollCaptureError.invalidFrame
        }
        self.seed = seed
        previousFrame = seed
        self.matcher = matcher
        self.temporaryDirectory = temporaryDirectory
        viewport = ManualScrollViewport(seedHeight: seed.height, frameHeight: seed.height)
        var seededBudget = budget
        try seededBudget.reserveSeed(width: seed.width, height: seed.height)
        self.budget = seededBudget
        upStore = try StripStore(width: seed.width, temporaryDirectory: temporaryDirectory)
        downStore = try StripStore(width: seed.width, temporaryDirectory: temporaryDirectory)
    }

    var upStripCount: Int { upStore.strips.count }
    var downStripCount: Int { downStore.strips.count }
    var areStoresCleanedUp: Bool { !upStore.isBackingFilePresent && !downStore.isBackingFilePresent }

    /// Processes one changed frame (PLAN.md §4): returns the accepted signed shift, `0` for an
    /// in-place content change (no stitch; `previousFrame` retained so animated content cannot
    /// poison later comparisons), or `nil` for an unmatched frame (increments the
    /// consecutive-unmatched counter toward `unmatchedDegradedThreshold`). Unchanged frames should
    /// never reach this method — that cheap skip happens upstream, in the capture loop.
    ///
    /// `viewport`/`budget`/`previousFrame` are only committed after every append this shift
    /// requires has actually succeeded — budget is reserved (against a working copy) for both the
    /// `down` and `up` ranges before either strip is written, and nothing is committed if a cap or
    /// an append failure is hit partway through. Without this, a rejected shift could still leave
    /// the extent claiming rows no store actually holds, and a later `compose()` would map past
    /// the end of a short file (PLAN.md §6 — the cap path must stay composable, matching
    /// `IncrementalImageStitcher.append`'s check-before-mutate contract).
    @discardableResult
    func process(frame: CGImage) throws -> Int? {
        guard let shift = try matcher.shift(from: previousFrame, to: frame) else {
            consecutiveUnmatchedCount += 1
            if consecutiveUnmatchedCount >= Self.unmatchedDegradedThreshold {
                isDegraded = true
            }
            return nil
        }
        consecutiveUnmatchedCount = 0
        guard shift != 0 else { return 0 }

        var nextViewport = viewport
        let (down, up) = nextViewport.apply(shift: shift)

        var nextBudget = budget
        if let down { try nextBudget.reserve(additionalHeight: down.count) }
        if let up { try nextBudget.reserve(additionalHeight: up.count) }

        if let down {
            try appendStrip(down, from: frame, frameStitchedTop: nextViewport.viewportOffset, to: downStore)
        }
        if let up {
            try appendStrip(up, from: frame, frameStitchedTop: nextViewport.viewportOffset, to: upStore)
        }

        viewport = nextViewport
        budget = nextBudget
        previousFrame = frame
        return shift
    }

    private func appendStrip(
        _ stitchedRange: Range<Int>,
        from frame: CGImage,
        frameStitchedTop: Int,
        to store: StripStore
    ) throws {
        let rect = StitchedRowConversion.frameCropRect(
            stitchedRange: stitchedRange,
            frameStitchedTop: frameStitchedTop,
            frameWidth: frame.width
        )
        guard rect.minY >= 0, rect.maxY <= CGFloat(frame.height), let strip = frame.cropping(to: rect) else {
            throw ManualScrollCaptureError.imageCreation
        }
        try store.append(strip, stitchedRange: stitchedRange)
    }

    /// Composes the final image — up-store strips in reverse discovery order, then the seed, then
    /// down-store strips in discovery order — streamed file-to-file, then mmap→`CGImage` wrapped
    /// (PLAN.md §6). Store temp files are deleted only after the final image file exists.
    func compose() throws -> CGImage {
        let outputDirectory = temporaryDirectory.appendingPathComponent(
            "TakeAShotManualScrollComposite-\(UUID().uuidString)",
            isDirectory: true
        )
        let outputURL = outputDirectory.appendingPathComponent("composite.rgba")
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
                throw ManualScrollCaptureError.temporaryStorage
            }
            let writeHandle = try FileHandle(forWritingTo: outputURL)
            for strip in upStore.strips.reversed() {
                try writeHandle.write(contentsOf: try upStore.data(for: strip))
            }
            try writeHandle.write(contentsOf: try rgbaData(for: seed))
            for strip in downStore.strips {
                try writeHandle.write(contentsOf: try downStore.data(for: strip))
            }
            try writeHandle.synchronize()
            try writeHandle.close()
        } catch {
            try? FileManager.default.removeItem(at: outputDirectory)
            if let captureError = error as? ManualScrollCaptureError { throw captureError }
            throw ManualScrollCaptureError.temporaryStorage
        }

        let totalHeight = viewport.extent.count
        let image: CGImage
        do {
            image = try RawPixelFile.cgImage(
                mappingFileAt: outputURL,
                width: seed.width,
                height: totalHeight,
                bytesPerRow: seed.width * 4
            )
        } catch RawPixelFileError.mappingFailed {
            try? FileManager.default.removeItem(at: outputDirectory)
            throw ManualScrollCaptureError.temporaryStorage
        } catch {
            try? FileManager.default.removeItem(at: outputDirectory)
            throw ManualScrollCaptureError.imageCreation
        }

        try? FileManager.default.removeItem(at: outputDirectory)
        upStore.cleanup()
        downStore.cleanup()
        return image
    }

    /// Deletes every temp-file artifact without composing — the cancel/failure path (PLAN.md §6).
    func cancelAndCleanUp() {
        upStore.cleanup()
        downStore.cleanup()
    }

    private func rgbaData(for image: CGImage) throws -> Data {
        do {
            return try RawPixelFile.rgbaData(for: image)
        } catch RawPixelFileError.dimensionsTooLarge {
            throw ManualScrollCaptureError.byteLimit
        } catch {
            throw ManualScrollCaptureError.imageCreation
        }
    }
}
