import AppKit
import SwiftUI

enum PostCapturePanelPlacement {
    static func frame(
        captureRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        spacing: CGFloat = 8
    ) -> CGRect {
        let centeredX = captureRect.midX - panelSize.width / 2
        let belowY = captureRect.minY - spacing - panelSize.height
        let aboveY = captureRect.maxY + spacing
        let preferredY = belowY >= visibleFrame.minY ? belowY : aboveY
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)

        return CGRect(
            x: min(max(centeredX, visibleFrame.minX), maximumX),
            y: min(max(preferredY, visibleFrame.minY), maximumY),
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

struct PostCaptureActions {
    let copy: @MainActor () async -> Bool
    let save: @MainActor () async -> Bool
    let edit: @MainActor () async -> Bool
    /// The image shown in the panel's thumbnail — the Baked render when the capture has
    /// annotations, otherwise the raw capture (see `AppRuntime.presentPostCapture`).
    let previewImage: CGImage
}

enum PostCaptureScreenSelection {
    struct Candidate {
        let displayID: CGDirectDisplayID?
        let frame: CGRect
    }

    static func index(
        displayID: CGDirectDisplayID,
        selectionRect: CGRect,
        candidates: [Candidate],
        mainIndex: Int?
    ) -> Int? {
        if let exact = candidates.firstIndex(where: { $0.displayID == displayID }) {
            return exact
        }

        let intersecting = candidates.indices.max { lhs, rhs in
            intersectionArea(selectionRect, candidates[lhs].frame)
                < intersectionArea(selectionRect, candidates[rhs].frame)
        }
        if let intersecting,
           intersectionArea(selectionRect, candidates[intersecting].frame) > 0 {
            return intersecting
        }

        if let mainIndex, candidates.indices.contains(mainIndex) {
            return mainIndex
        }
        return candidates.indices.first
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

final class PostCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PostCaptureActionDispatcher {
    private var isPerforming = false
    private var didComplete = false
    private let dismiss: () -> Void

    init(dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
    }

    func perform(_ action: @escaping @MainActor () async -> Bool) async {
        guard !isPerforming, !didComplete else { return }
        isPerforming = true
        let succeeded = await action()
        isPerforming = false
        guard succeeded else { return }
        didComplete = true
        dismiss()
    }
}

@MainActor
final class PostCapturePanelCoordinator {
    fileprivate static let panelSize = CGSize(width: 400, height: 84)

    private var panel: NSPanel?
    private var dispatcher: PostCaptureActionDispatcher?
    private var escapeMonitor: Any?
    private var outsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?

    func present(
        capture: CapturedImage,
        selection: AreaSelection,
        actions: PostCaptureActions
    ) {
        dismiss()

        guard let screen = screen(
            displayID: selection.displayID,
            selectionRect: selection.rect
        ) else { return }
        let panel = Self.makePanel()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let dispatcher = PostCaptureActionDispatcher { [weak self, weak panel] in
            guard let self,
                  Self.shouldDismiss(completing: panel, current: self.panel) else { return }
            self.dismiss()
        }
        let content = PostCapturePanelView(
            image: actions.previewImage,
            copy: { await dispatcher.perform(actions.copy) },
            save: { await dispatcher.perform(actions.save) },
            edit: { await dispatcher.perform(actions.edit) }
        )
        panel.contentView = NSHostingView(rootView: content)
        panel.setFrame(
            PostCapturePanelPlacement.frame(
                captureRect: selection.rect,
                panelSize: Self.panelSize,
                visibleFrame: screen.visibleFrame
            ),
            display: false
        )

        self.panel = panel
        self.dispatcher = dispatcher
        installEventMonitors(for: panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
        }
        escapeMonitor = nil
        outsideClickMonitor = nil
        localOutsideClickMonitor = nil

        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        dispatcher = nil
    }

    static func shouldDismiss(completing: NSPanel?, current: NSPanel?) -> Bool {
        guard let completing else { return false }
        return current === completing
    }

    static func makePanel() -> PostCapturePanel {
        PostCapturePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    private func screen(
        displayID: CGDirectDisplayID,
        selectionRect: CGRect
    ) -> NSScreen? {
        let screens = NSScreen.screens
        let candidates = screens.map { screen in
            PostCaptureScreenSelection.Candidate(
                displayID: (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value,
                frame: screen.frame
            )
        }
        let mainIndex = NSScreen.main.flatMap { main in
            screens.firstIndex { $0 === main }
        }
        guard let index = PostCaptureScreenSelection.index(
            displayID: displayID,
            selectionRect: selectionRect,
            candidates: candidates,
            mainIndex: mainIndex
        ) else { return nil }
        return screens[index]
    }

    private func installEventMonitors(for panel: NSPanel) {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.dismiss()
            return nil
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self, weak panel] _ in
            guard let panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
            self?.dismiss()
        }

        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self, weak panel] event in
            if let panel, !panel.frame.contains(NSEvent.mouseLocation) {
                self?.dismiss()
            }
            return event
        }
    }
}

@MainActor
private struct PostCapturePanelView: View {
    let image: CGImage
    let copy: () async -> Void
    let save: () async -> Void
    let edit: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            actionButton("Copy", action: copy)
            actionButton("Save", action: save)
            actionButton("Editor", action: edit)
        }
        .padding(12)
        .frame(width: PostCapturePanelCoordinator.panelSize.width,
               height: PostCapturePanelCoordinator.panelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func actionButton(_ title: String, action: @escaping () async -> Void) -> some View {
        Button(title) {
            Task { await action() }
        }
        .buttonStyle(.bordered)
    }
}
