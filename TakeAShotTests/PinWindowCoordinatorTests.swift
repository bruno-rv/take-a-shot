import AppKit
import XCTest
@testable import TakeAShot

@MainActor
final class PinWindowCoordinatorTests: XCTestCase {
    func testRestorationClampsRecoveryControlsOntoNearestDisplay() {
        let displays = [
            PinDisplayGeometry(
                id: "main",
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                backingScale: 2
            )
        ]
        let offscreen = PersistedPinFrame(
            displayID: "removed",
            panelFrame: CGRect(x: 2_000, y: 1_200, width: 400, height: 300),
            previousVisibleFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        )

        let restored = PinFrameRestorer.restore(offscreen, displays: displays)

        XCTAssertTrue(displays[0].visibleFrame.contains(restored.origin))
        XCTAssertGreaterThanOrEqual(
            restored.intersection(displays[0].visibleFrame).width,
            PinFrameRestorer.minimumRecoverableWidth
        )
    }

    func testRestorationUsesStoredDisplayAndRelativePosition() {
        let displays = [
            PinDisplayGeometry(
                id: "stored",
                visibleFrame: CGRect(x: 100, y: 200, width: 1_000, height: 500),
                backingScale: 2
            ),
            PinDisplayGeometry(
                id: "nearer",
                visibleFrame: CGRect(x: 2_000, y: 0, width: 1_000, height: 500),
                backingScale: 2
            )
        ]
        let persisted = PersistedPinFrame(
            displayID: "stored",
            panelFrame: CGRect(x: 250, y: 100, width: 200, height: 100),
            previousVisibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )

        let restored = PinFrameRestorer.restore(persisted, displays: displays)

        XCTAssertEqual(restored, CGRect(x: 350, y: 300, width: 200, height: 100))
    }

    func testRestorationDoesNotEnlargePersistedPanel() {
        let display = PinDisplayGeometry(
            id: "main",
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            backingScale: 2
        )
        let persisted = PersistedPinFrame(
            displayID: "main",
            panelFrame: CGRect(x: 10, y: 20, width: 40, height: 20),
            previousVisibleFrame: display.visibleFrame
        )

        let restored = PinFrameRestorer.restore(persisted, displays: [display])

        XCTAssertEqual(restored.size, persisted.panelFrame.size)
    }

    func testDuplicateOpenFocusesExistingPanel() async throws {
        let panels = RecordingPinPanelFactory()
        let coordinator = PinWindowCoordinator(panelFactory: panels)
        let pin = PinnedReference.fixture(captureID: UUID())

        try await coordinator.open(pin)
        try await coordinator.open(pin)

        XCTAssertEqual(panels.created.count, 1)
        XCTAssertEqual(panels.created[0].focusCount, 1)
    }

    func testCloseAwaitsPanelOnceAndAllowsReopen() async throws {
        let panels = RecordingPinPanelFactory()
        let coordinator = PinWindowCoordinator(panelFactory: panels)
        let pin = PinnedReference.fixture(captureID: UUID())

        try await coordinator.open(pin)
        let firstPanel = try XCTUnwrap(coordinator.panel(for: pin.id) as? RecordingPinPanel)
        await coordinator.close(pinID: pin.id)
        try await coordinator.open(pin)

        XCTAssertEqual(firstPanel.closeCount, 1)
        XCTAssertEqual(panels.created.count, 2)
        XCTAssertEqual(coordinator.activeWindowIDs().count, 1)
    }

    func testVisibleStateAwaitsHideAndThenShowsPanel() async throws {
        let panels = RecordingPinPanelFactory()
        let coordinator = PinWindowCoordinator(panelFactory: panels)
        let pin = PinnedReference.fixture(captureID: UUID())
        try await coordinator.open(pin)
        let panel = try XCTUnwrap(coordinator.panel(for: pin.id) as? RecordingPinPanel)

        try await coordinator.setVisible(false, pinID: pin.id)
        try await coordinator.setVisible(true, pinID: pin.id)

        XCTAssertEqual(panel.hideCount, 1)
        XCTAssertEqual(panel.showCount, 2)
    }

    func testClickThroughRequiresRegisteredRecoveryShortcut() async throws {
        let shortcut = StubPinShortcutRegistrar(result: .failure(.alreadyInUse))
        let coordinator = PinWindowCoordinator(shortcutRegistrar: shortcut)
        let pin = PinnedReference.fixture(captureID: UUID())
        try await coordinator.open(pin)

        await XCTAssertThrowsErrorAsync {
            try await coordinator.setClickThrough(true, pinID: pin.id)
        }

        XCTAssertFalse(coordinator.panel(for: pin.id)?.ignoresMouseEvents ?? true)
    }

    func testClickThroughRegistersOnceAndUnregistersAfterLastPanelRestoresInput() async throws {
        let panels = RecordingPinPanelFactory()
        let shortcut = StubPinShortcutRegistrar(result: .success(()))
        let coordinator = PinWindowCoordinator(panelFactory: panels, shortcutRegistrar: shortcut)
        let first = PinnedReference.fixture(captureID: UUID())
        let second = PinnedReference.fixture(captureID: UUID())
        try await coordinator.open(first)
        try await coordinator.open(second)

        try await coordinator.setClickThrough(true, pinID: first.id)
        try await coordinator.setClickThrough(true, pinID: second.id)
        try await coordinator.setClickThrough(false, pinID: first.id)
        try await coordinator.setClickThrough(false, pinID: second.id)

        XCTAssertEqual(shortcut.registerCount, 1)
        XCTAssertEqual(shortcut.unregisterCount, 1)
    }

    func testPanelExposesCollapseBoundary() async throws {
        let panels = RecordingPinPanelFactory()
        let coordinator = PinWindowCoordinator(panelFactory: panels)
        let pin = PinnedReference.fixture(captureID: UUID())
        try await coordinator.open(pin)
        let panel = try XCTUnwrap(coordinator.panel(for: pin.id) as? RecordingPinPanel)

        panel.collapse(to: .right)
        panel.restoreFromCollapse()

        XCTAssertEqual(panel.collapsedEdges, [.right])
        XCTAssertEqual(panel.restoreFromCollapseCount, 1)
    }
}

@MainActor
private final class RecordingPinPanelFactory: PinPanelCreating {
    private(set) var created: [RecordingPinPanel] = []

    func makePanel(for pin: PinnedReference) -> any PinPanelControlling {
        let panel = RecordingPinPanel(pinID: pin.id, windowNumber: CGWindowID(created.count + 1))
        created.append(panel)
        return panel
    }
}

@MainActor
private final class RecordingPinPanel: PinPanelControlling {
    let pinID: UUID
    let windowNumber: CGWindowID
    var frame = CGRect(x: 10, y: 20, width: 320, height: 180)
    var ignoresMouseEvents = false
    private(set) var isVisible = false
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var focusCount = 0
    private(set) var closeCount = 0
    private(set) var collapsedEdges: [PinEdge] = []
    private(set) var restoreFromCollapseCount = 0

    init(pinID: UUID, windowNumber: CGWindowID) {
        self.pinID = pinID
        self.windowNumber = windowNumber
    }

    func show() {
        isVisible = true
        showCount += 1
    }

    func hide() async {
        isVisible = false
        hideCount += 1
    }

    func focus() {
        focusCount += 1
    }

    func close() async {
        isVisible = false
        closeCount += 1
    }

    func collapse(to edge: PinEdge) {
        collapsedEdges.append(edge)
    }

    func restoreFromCollapse() {
        restoreFromCollapseCount += 1
    }
}

private final class StubPinShortcutRegistrar: PinShortcutRegistering, @unchecked Sendable {
    private let result: Result<Void, PinShortcutError>
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(result: Result<Void, PinShortcutError>) {
        self.result = result
    }

    func register(
        _ shortcut: PinRecoveryShortcut,
        handler: @escaping @Sendable () -> Void
    ) throws {
        registerCount += 1
        try result.get()
    }

    func unregister() {
        unregisterCount += 1
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {}
}
