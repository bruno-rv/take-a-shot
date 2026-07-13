import AppKit
import CoreGraphics
import Foundation
import SwiftUI

struct PinDisplayGeometry: Equatable, Sendable {
    let id: String
    let visibleFrame: CGRect
    let backingScale: CGFloat

    @MainActor
    static func live() -> [PinDisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return PinDisplayGeometry(
                id: String(number.uint32Value),
                visibleFrame: screen.visibleFrame,
                backingScale: screen.backingScaleFactor
            )
        }
    }
}

enum PinFrameRestorer {
    static let minimumRecoverableWidth: CGFloat = 64
    static let minimumRecoverableHeight: CGFloat = 36

    static func restore(
        _ persisted: PersistedPinFrame,
        displays: [PinDisplayGeometry]
    ) -> CGRect {
        guard let destination = destination(for: persisted, displays: displays) else {
            return persisted.panelFrame
        }

        let previous = persisted.previousVisibleFrame
        let xFraction = previous.width > 0
            ? (persisted.panelFrame.minX - previous.minX) / previous.width
            : 0
        let yFraction = previous.height > 0
            ? (persisted.panelFrame.minY - previous.minY) / previous.height
            : 0
        let visible = destination.visibleFrame
        let size = CGSize(
            width: min(max(persisted.panelFrame.width, minimumRecoverableWidth), visible.width),
            height: min(max(persisted.panelFrame.height, minimumRecoverableHeight), visible.height)
        )
        let mappedOrigin = CGPoint(
            x: visible.minX + xFraction * visible.width,
            y: visible.minY + yFraction * visible.height
        )
        let origin = CGPoint(
            x: min(max(mappedOrigin.x, visible.minX), visible.maxX - size.width),
            y: min(max(mappedOrigin.y, visible.minY), visible.maxY - size.height)
        )
        return CGRect(origin: origin, size: size)
    }

    static func destination(
        for persisted: PersistedPinFrame,
        displays: [PinDisplayGeometry]
    ) -> PinDisplayGeometry? {
        if let stored = displays.first(where: { $0.id == persisted.displayID }) {
            return stored
        }
        let center = CGPoint(x: persisted.panelFrame.midX, y: persisted.panelFrame.midY)
        return displays.min { distance(from: center, to: $0.visibleFrame) < distance(from: center, to: $1.visibleFrame) }
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let horizontal = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let vertical = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return horizontal * horizontal + vertical * vertical
    }
}

@MainActor
protocol PinPanelControlling: AnyObject {
    var pinID: UUID { get }
    var windowNumber: CGWindowID { get }
    var frame: CGRect { get set }
    var ignoresMouseEvents: Bool { get set }
    var isVisible: Bool { get }
    func show()
    func hide() async
    func focus()
    func close() async
    func collapse(to edge: PinEdge)
    func restoreFromCollapse()
}

@MainActor
protocol PinPanelCreating: AnyObject {
    func makePanel(for pin: PinnedReference) -> any PinPanelControlling
}

@MainActor
protocol PinWindowCoordinating: AnyObject {
    func open(_ pin: PinnedReference) async throws
    func close(pinID: UUID) async
    func focus(pinID: UUID)
    func setVisible(_ visible: Bool, pinID: UUID) async throws
    func isVisible(pinID: UUID) -> Bool
    func activeWindowIDs() -> Set<CGWindowID>
    func snapshotFrames() -> [UUID: PersistedPinFrame]
}

enum PinWindowCoordinatorError: Error, Equatable {
    case panelNotFound(UUID)
}

@MainActor
final class PinWindowCoordinator: PinWindowCoordinating {
    private let panelFactory: any PinPanelCreating
    private let shortcutRegistrar: any PinShortcutRegistering
    private let displayProvider: @MainActor () -> [PinDisplayGeometry]
    private var panels: [UUID: any PinPanelControlling] = [:]
    private var persistedFrames: [UUID: PersistedPinFrame] = [:]
    private var hideTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var clickThroughPinIDs: Set<UUID> = []
    private var isRecoveryShortcutRegistered = false

    init(
        panelFactory: (any PinPanelCreating)? = nil,
        shortcutRegistrar: any PinShortcutRegistering = PinShortcutController(),
        displayProvider: @escaping @MainActor () -> [PinDisplayGeometry] = PinDisplayGeometry.live
    ) {
        self.panelFactory = panelFactory ?? LivePinPanelFactory()
        self.shortcutRegistrar = shortcutRegistrar
        self.displayProvider = displayProvider
    }

    func open(_ pin: PinnedReference) async throws {
        if let existing = panels[pin.id] {
            existing.focus()
            return
        }

        let panel = panelFactory.makePanel(for: pin)
        panel.frame = PinFrameRestorer.restore(pin.frame, displays: displayProvider())
        panels[pin.id] = panel
        persistedFrames[pin.id] = pin.frame
        if let edge = pin.collapsedEdge {
            panel.collapse(to: edge)
        }
        if pin.isClickThrough {
            try? await setClickThrough(true, pinID: pin.id)
        }
        panel.show()
    }

    func close(pinID: UUID) async {
        guard let panel = panels.removeValue(forKey: pinID) else { return }
        persistedFrames.removeValue(forKey: pinID)
        hideTasks.removeValue(forKey: pinID)
        clickThroughPinIDs.remove(pinID)
        panel.ignoresMouseEvents = false
        unregisterRecoveryShortcutIfUnused()
        await panel.close()
    }

    func focus(pinID: UUID) {
        panels[pinID]?.focus()
    }

    func isVisible(pinID: UUID) -> Bool {
        panels[pinID]?.isVisible ?? false
    }

    func setVisible(_ visible: Bool, pinID: UUID) async throws {
        guard let panel = panels[pinID] else { throw PinWindowCoordinatorError.panelNotFound(pinID) }
        if visible {
            if let hideTask = hideTasks[pinID] {
                await hideTask.task.value
            }
            guard let currentPanel = panels[pinID], currentPanel === panel else { return }
            panel.show()
        } else {
            if let hideTask = hideTasks[pinID] {
                await hideTask.task.value
                return
            }

            let token = UUID()
            let task = Task { @MainActor in
                await panel.hide()
            }
            hideTasks[pinID] = (token, task)
            await task.value
            if hideTasks[pinID]?.token == token {
                hideTasks.removeValue(forKey: pinID)
            }
        }
    }

    func setClickThrough(_ enabled: Bool, pinID: UUID) async throws {
        guard let panel = panels[pinID] else { throw PinWindowCoordinatorError.panelNotFound(pinID) }
        if enabled && !clickThroughPinIDs.contains(pinID) && !isRecoveryShortcutRegistered {
            try shortcutRegistrar.register(.defaultShortcut) { [weak self] in
                Task { @MainActor in
                    self?.restoreMouseEvents()
                }
            }
            isRecoveryShortcutRegistered = true
        }
        panel.ignoresMouseEvents = enabled
        if enabled {
            clickThroughPinIDs.insert(pinID)
        } else {
            clickThroughPinIDs.remove(pinID)
            unregisterRecoveryShortcutIfUnused()
        }
    }

    func activeWindowIDs() -> Set<CGWindowID> {
        Set(panels.values.map(\.windowNumber))
    }

    func snapshotFrames() -> [UUID: PersistedPinFrame] {
        let displays = displayProvider()
        return panels.reduce(into: [:]) { snapshots, entry in
            let (pinID, panel) = entry
            let prior = persistedFrames[pinID]
            let display = displays.first { $0.visibleFrame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) }
            snapshots[pinID] = PersistedPinFrame(
                displayID: display?.id ?? prior?.displayID ?? "",
                panelFrame: panel.frame,
                previousVisibleFrame: display?.visibleFrame ?? prior?.previousVisibleFrame ?? .zero
            )
        }
    }

    func panel(for pinID: UUID) -> (any PinPanelControlling)? {
        panels[pinID]
    }

    private func restoreMouseEvents() {
        for pinID in clickThroughPinIDs {
            panels[pinID]?.ignoresMouseEvents = false
        }
        clickThroughPinIDs.removeAll()
        unregisterRecoveryShortcutIfUnused()
    }

    private func unregisterRecoveryShortcutIfUnused() {
        guard clickThroughPinIDs.isEmpty, isRecoveryShortcutRegistered else { return }
        shortcutRegistrar.unregister()
        isRecoveryShortcutRegistered = false
    }
}

@MainActor
private final class LivePinPanelFactory: PinPanelCreating {
    func makePanel(for pin: PinnedReference) -> any PinPanelControlling {
        LivePinPanel(pinID: pin.id)
    }
}

@MainActor
private final class LivePinPanel: PinPanelControlling {
    let pinID: UUID
    private let panel: NSPanel
    private var collapsedFrame: CGRect?

    var windowNumber: CGWindowID { CGWindowID(panel.windowNumber) }
    var frame: CGRect {
        get { panel.frame }
        set { panel.setFrame(newValue, display: true) }
    }
    var ignoresMouseEvents: Bool {
        get { panel.ignoresMouseEvents }
        set { panel.ignoresMouseEvents = newValue }
    }
    var isVisible: Bool { panel.isVisible }

    init(pinID: UUID) {
        self.pinID = pinID
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentViewController = NSHostingController(rootView: EmptyView())
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() async {
        panel.orderOut(nil)
    }

    func focus() {
        panel.makeKeyAndOrderFront(nil)
    }

    func close() async {
        panel.close()
    }

    func collapse(to edge: PinEdge) {
        guard collapsedFrame == nil else { return }
        collapsedFrame = panel.frame
        let frame = panel.frame
        let collapsedSize = CGSize(width: min(frame.width, 64), height: min(frame.height, 36))
        switch edge {
        case .top:
            panel.setFrame(CGRect(x: frame.minX, y: frame.maxY - collapsedSize.height, width: frame.width, height: collapsedSize.height), display: true)
        case .right:
            panel.setFrame(CGRect(x: frame.maxX - collapsedSize.width, y: frame.minY, width: collapsedSize.width, height: frame.height), display: true)
        case .bottom:
            panel.setFrame(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: collapsedSize.height), display: true)
        case .left:
            panel.setFrame(CGRect(x: frame.minX, y: frame.minY, width: collapsedSize.width, height: frame.height), display: true)
        }
    }

    func restoreFromCollapse() {
        guard let collapsedFrame else { return }
        panel.setFrame(collapsedFrame, display: true)
        self.collapsedFrame = nil
    }
}
