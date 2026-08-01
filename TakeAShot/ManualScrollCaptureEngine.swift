import AppKit
import CoreGraphics
import Foundation
import os

/// Converts between AppKit's global coordinate space (origin at the bottom-left of the primary
/// display, y-up) and Quartz's global coordinate space (origin at the top-left of the primary
/// display, y-down — the space `CGWindowListCopyWindowInfo` reports window bounds in). Extracted
/// as a single pure, unit-tested seam (PLAN.md §3.1) rather than re-derived at every call site.
enum ManualScrollCoordinateConversion {
    static func quartzPoint(fromAppKitPoint point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Same y-flip as `quartzPoint(fromAppKitPoint:primaryScreenHeight:)`, applied to a rect: the
    /// AppKit rect's top edge (`maxY`, y-up) becomes the Quartz rect's origin (y-down).
    static func quartzRect(fromAppKitRect rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

/// A window resolved as the Manual Scroll Capture target: topmost on-screen window (excluding
/// TakeAShot's own) under the confirmed selection's center (PLAN.md §3.1). `frame` is in Quartz
/// coordinates (top-down), matching `CGWindowListCopyWindowInfo`.
struct ManualScrollTarget: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerProcessIdentifier: pid_t
    let ownerBundleIdentifier: String?
    let frame: CGRect
}

/// Window-list queries Manual Scroll Capture's target resolution/revalidation/monitoring need —
/// deliberately narrower than `WindowTargeting` (no Accessibility, no raise/activate): manual scroll
/// never needs to move or focus the window it captures, only to know whether one is there
/// (PLAN.md §3.1, §4).
protocol ManualScrollTargetResolving: Sendable {
    /// Topmost on-screen window whose bounds contain `quartzPoint`, excluding any window owned by
    /// `excludingBundleIdentifier` — `nil` if none (PLAN.md §3.1: "center-only targeting").
    func topmostWindow(at quartzPoint: CGPoint, excludingBundleIdentifier: String?) -> ManualScrollTarget?
    /// Existence check used both for the pre-activation revalidation ("PID still running, window
    /// still present") and, with `intersecting`, the mid-session monitor gate — deliberately NOT a
    /// topmost check, so a transient overlay above the target never trips it (PLAN.md §3.5, §4).
    func windowExists(_ windowID: CGWindowID, intersecting quartzRect: CGRect?) -> Bool
}

struct SystemManualScrollTargetResolver: ManualScrollTargetResolving {
    func topmostWindow(
        at quartzPoint: CGPoint,
        excludingBundleIdentifier: String?
    ) -> ManualScrollTarget? {
        for window in Self.onScreenWindows() {
            guard window.alpha > 0.01, window.frame.contains(quartzPoint) else { continue }
            if let excludingBundleIdentifier, window.ownerBundleIdentifier == excludingBundleIdentifier {
                continue
            }
            return ManualScrollTarget(
                windowID: window.windowID,
                ownerProcessIdentifier: window.ownerProcessIdentifier,
                ownerBundleIdentifier: window.ownerBundleIdentifier,
                frame: window.frame
            )
        }
        return nil
    }

    func windowExists(_ windowID: CGWindowID, intersecting quartzRect: CGRect?) -> Bool {
        guard let window = Self.onScreenWindows().first(where: { $0.windowID == windowID }) else {
            return false
        }
        guard let quartzRect else { return true }
        return window.frame.intersects(quartzRect)
    }

    private struct Window {
        let windowID: CGWindowID
        let ownerProcessIdentifier: pid_t
        let ownerBundleIdentifier: String?
        let frame: CGRect
        let alpha: Double
    }

    private static func onScreenWindows() -> [Window] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard
                let number = entry[kCGWindowNumber as String] as? NSNumber,
                let processID = entry[kCGWindowOwnerPID as String] as? NSNumber,
                let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            let pid = pid_t(processID.int32Value)
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return Window(
                windowID: CGWindowID(number.uint32Value),
                ownerProcessIdentifier: pid,
                ownerBundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                frame: frame,
                alpha: alpha
            )
        }
    }
}

/// Per-tick outcome the engine reports back to the session controller — logged via `os.Logger`
/// (PLAN.md §9) and used to drive HUD state and auto-finish transitions.
enum ManualScrollTickOutcome: Equatable, Sendable {
    case unchanged
    case inPlace
    case matched(shift: Int)
    case droppedUnmatched
    case paused
    case invalidated
    case durationExceeded
    case budgetExceeded(ManualScrollCaptureError)
    case captureFailed
}

struct ManualScrollTickResult: Equatable, Sendable {
    let outcome: ManualScrollTickOutcome
    let stitchedHeight: Int
    let isDegraded: Bool
}

/// Compute/storage actor for one Manual Scroll Capture session (PLAN.md §7): owns the phase-1
/// `ManualScrollCaptureWorker`, the ~150 ms tick's frame capture + cheap unchanged-skip + mid-session
/// target monitoring, and composition. Everything crossing into/out of this actor is a Sendable
/// value type; the `@MainActor` `ManualScrollSessionController` owns all AppKit/Carbon state and
/// drives this actor's `tick()` on its own timer loop.
actor ManualScrollCaptureEngine {
    typealias FrameProvider = @Sendable () async throws -> CGImage
    typealias Elapsed = @Sendable () -> TimeInterval

    static let maximumDuration: TimeInterval = 300
    static let monitorTickInterval = 7
    private static let unchangedConfidenceThreshold = 0.999
    private static let unchangedSampleWidth = 32
    private static let unchangedSampleHeight = 64

    private let worker: ManualScrollCaptureWorker
    private let frameProvider: FrameProvider
    private let targetResolver: (any ManualScrollTargetResolving)?
    private let quartzCaptureRect: CGRect?
    private let elapsed: Elapsed
    private let startTime: TimeInterval

    /// `monitoringWindowID` is `nil` whenever monitoring is disabled — either no target window was
    /// resolvable at Confirm, or `targetResolver`/`quartzCaptureRect` weren't supplied at all.
    private(set) var monitoringWindowID: CGWindowID?
    private var tickCount = 0
    private var isPaused = false

    init(
        seed: CGImage,
        frameProvider: @escaping FrameProvider,
        targetResolver: (any ManualScrollTargetResolving)? = nil,
        monitoringWindowID: CGWindowID? = nil,
        quartzCaptureRect: CGRect? = nil,
        matcher: FrameShiftMatcher = FrameShiftMatcher(),
        budget: ManualScrollBudget = ManualScrollBudget(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        elapsed: @escaping Elapsed = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        worker = try ManualScrollCaptureWorker(
            seed: seed,
            matcher: matcher,
            budget: budget,
            temporaryDirectory: temporaryDirectory
        )
        self.frameProvider = frameProvider
        self.targetResolver = targetResolver
        self.monitoringWindowID = targetResolver != nil ? monitoringWindowID : nil
        self.quartzCaptureRect = quartzCaptureRect
        self.elapsed = elapsed
        startTime = elapsed()
    }

    func tick() async -> ManualScrollTickResult {
        tickCount += 1

        if isPaused {
            return result(.paused)
        }
        if elapsed() - startTime >= Self.maximumDuration {
            return result(.durationExceeded)
        }
        if let targetResolver, let monitoringWindowID, tickCount % Self.monitorTickInterval == 0,
           !targetResolver.windowExists(monitoringWindowID, intersecting: quartzCaptureRect) {
            isPaused = true
            return result(.invalidated)
        }

        let frame: CGImage
        do {
            frame = try await frameProvider()
        } catch {
            return result(.captureFailed)
        }

        if isUnchanged(frame, comparedTo: worker.previousFrame) {
            return result(.unchanged)
        }

        do {
            if let shift = try worker.process(frame: frame) {
                return result(shift == 0 ? .inPlace : .matched(shift: shift))
            }
            return result(.droppedUnmatched)
        } catch let error as ManualScrollCaptureError {
            return result(.budgetExceeded(error))
        } catch {
            return result(.captureFailed)
        }
    }

    /// User-initiated Resume after a pause (PLAN.md §4): re-resolves the target under the same
    /// capture-rect center and, on success, updates `monitoringWindowID` and un-pauses. A failed
    /// resolution leaves the session paused — the caller may retry.
    func resume(reresolvingAt quartzPoint: CGPoint) -> Bool {
        guard isPaused else { return true }
        guard let targetResolver else { return false }
        guard let target = targetResolver.topmostWindow(at: quartzPoint, excludingBundleIdentifier: nil)
        else { return false }
        monitoringWindowID = target.windowID
        isPaused = false
        return true
    }

    func compose() throws -> CGImage {
        try worker.compose()
    }

    func cancelAndCleanUp() {
        worker.cancelAndCleanUp()
    }

    private func result(_ outcome: ManualScrollTickOutcome) -> ManualScrollTickResult {
        ManualScrollTickResult(
            outcome: outcome,
            stitchedHeight: worker.viewport.extent.count,
            isDegraded: worker.isDegraded
        )
    }

    /// Cheap pre-filter ahead of the full `FrameShiftMatcher` search (PLAN.md §4): a downsampled
    /// luminance compare at zero shift. A true no-op tick (nothing scrolled, nothing repainted)
    /// always clears this near-1.0 confidence threshold, so the far more expensive shift search
    /// only ever runs for frames that actually changed.
    private func isUnchanged(_ frame: CGImage, comparedTo previous: CGImage) -> Bool {
        guard frame.width == previous.width, frame.height == previous.height else { return false }
        let width = min(Self.unchangedSampleWidth, frame.width)
        let height = min(Self.unchangedSampleHeight, frame.height)
        guard height > 0,
              let frameSample = LuminanceSample(image: frame, width: width, height: height),
              let previousSample = LuminanceSample(image: previous, width: width, height: height)
        else { return false }
        let confidence = LuminanceCorrelation.confidence(
            lhs: previousSample, lhsStartRow: 0,
            rhs: frameSample, rhsStartRow: 0,
            rowCount: height
        )
        return confidence >= Self.unchangedConfidenceThreshold
    }
}

extension Logger {
    static let manualScrollCapture = Logger(subsystem: "com.bruno.takeashot", category: "ManualScrollCapture")
}
