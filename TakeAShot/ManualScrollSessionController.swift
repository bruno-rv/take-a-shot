#if os(macOS)
import AppKit
import SwiftUI
import os

/// Terminal outcome of a Manual Scroll Capture session, returned by `ManualScrollSessionController
/// .run()` once Done, Cancel, or an auto-finish transition (duration/budget cap) resolves it
/// (PLAN.md §7/§8).
enum ManualScrollSessionOutcome: @unchecked Sendable {
    case completed(CGImage)
    case partial(CGImage, reason: ManualScrollCaptureError)
    case cancelled
    case failed(Error)
}

/// Register/unregister exactly one session-scoped Carbon hotkey, without exposing
/// `HotKeyRegistering`'s associated `Token` type to `ManualScrollSessionController` (PLAN.md §3:
/// "same registration mechanism as the global capture shortcut").
@MainActor
protocol ManualScrollHotKeyRegistering: AnyObject {
    func registerFinishHotKey(_ shortcut: ShortcutPreference, action: @escaping @MainActor () -> Void) throws
    func unregisterFinishHotKey()
}

@MainActor
final class HotKeySessionSlot<Registrar: HotKeyRegistering>: ManualScrollHotKeyRegistering {
    private let registrar: Registrar
    private var token: Registrar.Token?

    init(registrar: Registrar) {
        self.registrar = registrar
    }

    func registerFinishHotKey(
        _ shortcut: ShortcutPreference,
        action: @escaping @MainActor () -> Void
    ) throws {
        token = try registrar.register(shortcut, action: action)
    }

    func unregisterFinishHotKey() {
        guard let token else { return }
        self.token = nil
        registrar.unregister(token)
    }
}

struct ManualScrollHUDState: Equatable {
    var stitchedHeight: Int = 0
    var isDegraded = false
    var isPaused = false
    var notice: String?

    static let contentChangedNotice = "Content changed — Resume or Cancel"
    static let captureFailureNotice = "Not receiving frames — Done keeps what was stitched"

    /// Notice a tick leaves on the HUD. The capture-failure notice clears itself once frames flow
    /// again; notices set outside the tick loop (target focus, hot key) survive it untouched.
    static func notice(after outcome: ManualScrollTickOutcome, current: String?) -> String? {
        switch outcome {
        case .invalidated:
            return contentChangedNotice
        case .captureFailed:
            // Only while it's still recoverable — sustained failure arrives as
            // `.captureFailureLimitReached` and ends the session. Do not replace unrelated
            // notices (target focus, shortcut unavailable) — a transient failure would otherwise
            // erase them and the next good tick would clear the replacement notice permanently.
            guard current == nil || current == captureFailureNotice else { return current }
            return captureFailureNotice
        case .unchanged, .inPlace, .matched, .droppedUnmatched:
            return current == captureFailureNotice ? nil : current
        case .paused, .durationExceeded, .budgetExceeded, .captureFailureLimitReached:
            return current
        }
    }
}

/// The Scroll HUD (CONTEXT.md): a small floating, non-activating control showing the stitched
/// height with Done/Cancel (and Resume, while paused).
struct ManualScrollHUDView: View {
    let state: ManualScrollHUDState
    let onDone: () -> Void
    let onCancel: () -> Void
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = state.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if state.isDegraded {
                Text("Content not matching reliably")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
            HStack(spacing: 10) {
                Text("\(state.stitchedHeight) px")
                    .font(.body.monospacedDigit())
                if state.isPaused {
                    Button("Resume", action: onResume).buttonStyle(.borderedProminent)
                }
                Button("Cancel", action: onCancel).buttonStyle(.bordered)
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isPaused)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .fixedSize()
    }
}

final class ManualScrollHUDPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hasShadow = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
}

/// Just-outside-the-selection outline shown for the life of a Manual Scroll Capture session —
/// fully click-through and excluded from capture like every other TakeAShot window (PLAN.md §3.3).
final class ManualScrollBorderWindow: NSWindow {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hasShadow = false
        ignoresMouseEvents = true
        contentView = ManualScrollBorderView(frame: CGRect(origin: .zero, size: frame.size))
    }

    override var canBecomeKey: Bool { false }
}

private final class ManualScrollBorderView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.systemBlue.setStroke()
        path.stroke()
    }
}

/// `@MainActor` owner of a Manual Scroll Capture session's UI/system state (PLAN.md §7): the HUD
/// panel, border window, session-scoped Carbon hotkey, target reference, and the single terminal
/// transition. Each session gets its own instance — a stale instance can never touch a newer
/// session's windows or hotkey token because it never holds a reference to them. Compute + storage
/// (`FrameShiftMatcher`, both `StripStore`s, the budget) live entirely behind `ManualScrollCaptureEngine`,
/// a separate actor this controller drives on a ~150 ms timer loop.
@MainActor
final class ManualScrollSessionController {
    typealias ClockSleep = @Sendable () async throws -> Void

    private let engine: ManualScrollCaptureEngine
    private let selection: AreaSelection
    private let targetResolver: (any ManualScrollTargetResolving)?
    private let resolvedTarget: ManualScrollTarget?
    private let fallbackApplication: NSRunningApplication?
    private let hotKeySlot: any ManualScrollHotKeyRegistering
    private let shortcut: ShortcutPreference
    private let clockSleep: ClockSleep
    private let quartzCaptureCenter: CGPoint

    private var borderWindow: ManualScrollBorderWindow?
    private var hudPanel: ManualScrollHUDPanel?
    private var hudHost: NSHostingView<ManualScrollHUDView>?
    private var hudState = ManualScrollHUDState()

    private var tickTask: Task<Void, Never>?
    private var isTerminal = false
    private var continuation: CheckedContinuation<ManualScrollSessionOutcome, Never>?

    init(
        engine: ManualScrollCaptureEngine,
        selection: AreaSelection,
        targetResolver: (any ManualScrollTargetResolving)?,
        resolvedTarget: ManualScrollTarget?,
        fallbackApplication: NSRunningApplication?,
        hotKeySlot: any ManualScrollHotKeyRegistering,
        shortcut: ShortcutPreference,
        clockSleep: @escaping ClockSleep = { try await Task.sleep(for: .milliseconds(150)) }
    ) {
        self.engine = engine
        self.selection = selection
        self.targetResolver = targetResolver
        self.resolvedTarget = resolvedTarget
        self.fallbackApplication = fallbackApplication
        self.hotKeySlot = hotKeySlot
        self.shortcut = shortcut
        self.clockSleep = clockSleep
        quartzCaptureCenter = ManualScrollCoordinateConversion.quartzPoint(
            fromAppKitPoint: CGPoint(x: selection.rect.midX, y: selection.rect.midY),
            primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0
        )
    }

    /// Runs the session to completion (Done, Cancel, or an auto-finish transition) and returns its
    /// outcome. Suspends the caller until then; `cancel()` may be called concurrently (e.g. the app
    /// starting a different capture) to resolve it early.
    func run() async -> ManualScrollSessionOutcome {
        showBorder()
        showHUD()
        revalidateAndActivate()
        registerHotKey()
        startTickLoop()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        guard !isTerminal else { return }
        isTerminal = true
        let task = tickTask
        tickTask = nil
        task?.cancel()
        Task { @MainActor [engine] in
            _ = await task?.value
            await engine.cancelAndCleanUp()
            self.finishTeardown(.cancelled)
        }
    }

    private func finish() {
        guard !isTerminal else { return }
        isTerminal = true
        let task = tickTask
        tickTask = nil
        task?.cancel()
        let wasDegraded = hudState.isDegraded
        Task { @MainActor [engine] in
            _ = await task?.value
            do {
                let image = try await engine.compose()
                if wasDegraded {
                    self.finishTeardown(.partial(image, reason: .lowConfidence))
                } else {
                    self.finishTeardown(.completed(image))
                }
            } catch {
                await engine.cancelAndCleanUp()
                self.finishTeardown(.failed(error))
            }
        }
    }

    private func autoFinish(reason: ManualScrollCaptureError) {
        guard !isTerminal else { return }
        isTerminal = true
        let task = tickTask
        tickTask = nil
        task?.cancel()
        Task { @MainActor [engine] in
            _ = await task?.value
            do {
                let image = try await engine.compose()
                self.finishTeardown(.partial(image, reason: reason))
            } catch {
                await engine.cancelAndCleanUp()
                self.finishTeardown(.failed(error))
            }
        }
    }

    private func resume() {
        Task { @MainActor [engine, quartzCaptureCenter] in
            let succeeded = await engine.resume(reresolvingAt: quartzCaptureCenter)
            guard succeeded else { return }
            self.hudState.isPaused = false
            self.hudState.notice = nil
            self.refreshHUD()
        }
    }

    private func finishTeardown(_ outcome: ManualScrollSessionOutcome) {
        borderWindow?.orderOut(nil)
        borderWindow = nil
        hudPanel?.orderOut(nil)
        hudPanel = nil
        hudHost = nil
        hotKeySlot.unregisterFinishHotKey()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
    }

    private func startTickLoop() {
        tickTask = Task { @MainActor [weak self, clockSleep] in
            while !Task.isCancelled {
                try? await clockSleep()
                guard !Task.isCancelled, let self else { return }
                let result = await self.engine.tick()
                guard !Task.isCancelled else { return }
                self.handle(result)
            }
        }
    }

    private func handle(_ result: ManualScrollTickResult) {
        guard !isTerminal else { return }
        log(result.outcome)
        hudState.stitchedHeight = result.stitchedHeight
        hudState.isDegraded = result.isDegraded
        hudState.notice = ManualScrollHUDState.notice(after: result.outcome, current: hudState.notice)
        switch result.outcome {
        case .invalidated:
            hudState.isPaused = true
        case .durationExceeded:
            autoFinish(reason: .durationLimit(ManualScrollCaptureEngine.maximumDuration))
        case .budgetExceeded(let error):
            autoFinish(reason: error)
        case .captureFailureLimitReached:
            autoFinish(reason: .frameCaptureFailed)
        case .unchanged, .inPlace, .matched, .droppedUnmatched, .paused, .captureFailed:
            // Nothing beyond the HUD fields already set above — a capture failure only ends the
            // session once it comes back as `.captureFailureLimitReached`.
            break
        }
        refreshHUD()
    }

    private func log(_ outcome: ManualScrollTickOutcome) {
        switch outcome {
        case .unchanged:
            Logger.manualScrollCapture.debug("tick: unchanged")
        case .inPlace:
            Logger.manualScrollCapture.debug("tick: in-place content change")
        case .matched(let shift):
            Logger.manualScrollCapture.debug("tick: matched shift=\(shift, privacy: .public)")
        case .droppedUnmatched:
            Logger.manualScrollCapture.notice("tick: dropped unmatched frame")
        case .paused:
            Logger.manualScrollCapture.debug("tick: paused")
        case .invalidated:
            Logger.manualScrollCapture.notice("tick: target invalidated — pausing")
        case .durationExceeded:
            Logger.manualScrollCapture.notice("tick: duration limit reached")
        case .budgetExceeded(let error):
            Logger.manualScrollCapture.notice("tick: budget exceeded (\(String(describing: error), privacy: .public))")
        case .captureFailed:
            Logger.manualScrollCapture.error("tick: capture failed")
        case .captureFailureLimitReached:
            Logger.manualScrollCapture.error("tick: capture failing repeatedly — finishing as partial")
        }
    }

    private func showBorder() {
        let outset = selection.rect.insetBy(dx: -4, dy: -4)
        let frame = CaptureGeometry.clamp(outset, to: selection.display.frame)
        let window = ManualScrollBorderWindow(frame: frame)
        borderWindow = window
        window.orderFrontRegardless()
    }

    private func showHUD() {
        let content = ManualScrollHUDView(
            state: hudState,
            onDone: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() },
            onResume: { [weak self] in self?.resume() }
        )
        let host = NSHostingView(rootView: content)
        hudHost = host
        host.layoutSubtreeIfNeeded()
        let measuredSize = host.fittingSize
        let frame = SelectionToolbarPlacement.toolbarFrame(
            selection: selection.rect,
            toolbarSize: measuredSize,
            visibleBounds: selection.display.frame
        )
        let panel = ManualScrollHUDPanel(contentRect: frame)
        panel.contentView = host
        hudPanel = panel
        panel.orderFrontRegardless()
    }

    private func refreshHUD() {
        guard let host = hudHost else { return }
        host.rootView = ManualScrollHUDView(
            state: hudState,
            onDone: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() },
            onResume: { [weak self] in self?.resume() }
        )
    }

    /// PLAN.md §3.5: revalidate the resolved target immediately before activation. A window target
    /// that no longer exists skips activation and surfaces an explicit HUD notice — never silent. A
    /// pure application fallback (no resolved window) is activated directly; no target at all skips
    /// activation without a notice (nothing was ever resolved, so nothing "changed").
    private func revalidateAndActivate() {
        if let resolvedTarget {
            guard let targetResolver, targetResolver.windowExists(resolvedTarget.windowID, intersecting: nil) else {
                hudState.notice = "Target changed — click the content to focus"
                refreshHUD()
                return
            }
            NSRunningApplication(processIdentifier: resolvedTarget.ownerProcessIdentifier)?.activate(options: [])
        } else {
            fallbackApplication?.activate(options: [])
        }
    }

    private func registerHotKey() {
        do {
            try hotKeySlot.registerFinishHotKey(shortcut) { [weak self] in
                self?.finish()
            }
        } catch {
            hudState.notice = "Shortcut unavailable — use the HUD buttons"
            refreshHUD()
        }
    }
}
#endif
