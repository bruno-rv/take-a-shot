import AppKit
import XCTest
@testable import TakeAShot

@MainActor
final class PinCoordinatorTests: XCTestCase {
    func testPinningSameCaptureFocusesExistingPin() async throws {
        let captureID = UUID()
        let windows = RecordingCoordinatorWindows()
        let coordinator = makeCoordinator(
            library: StubCoordinatorLibrary(records: [.image(id: captureID)]),
            windows: windows
        )

        let first = try await coordinator.pin(captureID: captureID)
        let second = try await coordinator.pin(captureID: captureID)

        XCTAssertEqual(first, second)
        XCTAssertEqual(windows.opened, [first])
        XCTAssertEqual(windows.focused, [first])
    }

    func testRestoreOpensOnlyPersistentImagePins() async throws {
        let persistent = pin(captureID: UUID(), restoresAfterRelaunch: true)
        let transient = pin(captureID: UUID(), restoresAfterRelaunch: false)
        let windows = RecordingCoordinatorWindows()
        let coordinator = makeCoordinator(
            store: StubCoordinatorStore(pins: [persistent, transient]),
            library: StubCoordinatorLibrary(records: [
                .image(id: persistent.captureID),
                .image(id: transient.captureID),
            ]),
            windows: windows
        )

        try await coordinator.restorePersistentPins()

        XCTAssertEqual(coordinator.activePinIDs, [persistent.id])
        XCTAssertEqual(windows.opened, [persistent.id])
    }

    func testMissingCaptureProducesPlaceholderWithoutClosingPin() async throws {
        let reference = pin(captureID: UUID(), restoresAfterRelaunch: true)
        let windows = RecordingCoordinatorWindows()
        let coordinator = makeCoordinator(
            store: StubCoordinatorStore(pins: [reference]),
            library: StubCoordinatorLibrary(records: []),
            windows: windows
        )

        try await coordinator.restorePersistentPins()

        XCTAssertEqual(coordinator.state(for: reference.id), .missingSource(reference.captureID))
        XCTAssertEqual(windows.opened, [reference.id])
    }

    func testHideAndShowAllRestoresOnlyPreviouslyVisiblePins() async throws {
        let captureIDs = [UUID(), UUID(), UUID()]
        let windows = RecordingCoordinatorWindows()
        let coordinator = makeCoordinator(
            library: StubCoordinatorLibrary(records: captureIDs.map(CaptureRecord.image)) ,
            windows: windows
        )
        for captureID in captureIDs {
            _ = try await coordinator.pin(captureID: captureID)
        }
        let hiddenBeforeAction = coordinator.pins[1].id
        try await coordinator.setVisible(false, pinID: hiddenBeforeAction)

        let snapshot = try await coordinator.hideAll()
        try await coordinator.close(pinID: coordinator.pins[2].id)
        try await coordinator.showAll(from: snapshot)

        XCTAssertEqual(coordinator.visiblePinIDs, [coordinator.pins[0].id])
    }

    func testRejectsVideoAndGIFPinsBeforeOpeningAPanel() async throws {
        let videoID = UUID()
        let gifID = UUID()
        let windows = RecordingCoordinatorWindows()
        let coordinator = makeCoordinator(
            library: StubCoordinatorLibrary(records: [.video(id: videoID), .gif(id: gifID)]),
            windows: windows
        )

        await XCTAssertThrowsErrorAsync { _ = try await coordinator.pin(captureID: videoID) }
        await XCTAssertThrowsErrorAsync { _ = try await coordinator.pin(captureID: gifID) }

        XCTAssertTrue(windows.opened.isEmpty)
    }

    func testLibraryImageChangeInvalidatesRenderAndMetadataChangeRefreshesActions() async throws {
        let captureID = UUID()
        let library = StubCoordinatorLibrary(records: [.image(id: captureID)])
        let coordinator = makeCoordinator(library: library)
        let changes = coordinator.changes()
        var iterator = changes.makeAsyncIterator()
        await library.waitUntilObservingChanges()
        let pinID = try await coordinator.pin(captureID: captureID)

        let initialChange = await iterator.next()
        XCTAssertEqual(initialChange, .updated(coordinator.pins[0]))
        await library.send(.metadataChanged(captureID))
        let metadataChange = await iterator.next()
        XCTAssertEqual(metadataChange, .metadataChanged(pinID))

        await library.send(.imageOrAnnotationsChanged(captureID))
        let imageChange = await iterator.next()
        XCTAssertEqual(imageChange, .renderInvalidated(pinID))
    }

    func testDeletionTransitionsPinToMissingSource() async throws {
        let captureID = UUID()
        let library = StubCoordinatorLibrary(records: [.image(id: captureID)])
        let coordinator = makeCoordinator(library: library)
        let changes = coordinator.changes()
        var iterator = changes.makeAsyncIterator()
        await library.waitUntilObservingChanges()
        let pinID = try await coordinator.pin(captureID: captureID)
        _ = await iterator.next()

        await library.send(.deleted(captureID))
        let deletionChange = await iterator.next()
        XCTAssertEqual(
            deletionChange,
            .presentationChanged(pinID, .missingSource(captureID))
        )
        XCTAssertEqual(coordinator.state(for: pinID), .missingSource(captureID))
    }
}

@MainActor
private func makeCoordinator(
    store: (any PinStoring)? = nil,
    library: (any PinCoordinatorLibraryServing)? = nil,
    windows: (any PinWindowCoordinating)? = nil
) -> PinCoordinator {
    PinCoordinator(
        store: store ?? StubCoordinatorStore(),
        library: library ?? StubCoordinatorLibrary(records: []),
        windows: windows ?? RecordingCoordinatorWindows()
    )
}

private actor StubCoordinatorStore: PinStoring {
    private var storedPins: [PinnedReference]

    init(pins: [PinnedReference] = []) {
        storedPins = pins
    }

    func load() throws -> [PinnedReference] { storedPins }
    func scheduleUpsert(_ pin: PinnedReference) {
        storedPins.removeAll { $0.id == pin.id || $0.captureID == pin.captureID }
        storedPins.append(pin)
    }
    func remove(id: UUID) throws { storedPins.removeAll { $0.id == id } }
    func flush() async throws {}
}

private actor StubCoordinatorLibrary: PinCoordinatorLibraryServing {
    private let records: [CaptureRecord]
    private var continuations: [AsyncStream<CaptureLibraryChange>.Continuation] = []
    private var isObservingChanges = false
    private var observationContinuation: CheckedContinuation<Void, Never>?

    init(records: [CaptureRecord]) {
        self.records = records
    }

    func record(id: UUID) async throws -> CaptureRecord? {
        records.first { $0.id == id }
    }

    func changes() async -> AsyncStream<CaptureLibraryChange> {
        AsyncStream { continuation in
            continuations.append(continuation)
            isObservingChanges = true
            observationContinuation?.resume()
            observationContinuation = nil
        }
    }

    func waitUntilObservingChanges() async {
        guard !isObservingChanges else { return }
        await withCheckedContinuation { observationContinuation = $0 }
    }

    func send(_ change: CaptureLibraryChange) {
        continuations.forEach { $0.yield(change) }
    }
}

@MainActor
private final class RecordingCoordinatorWindows: PinWindowCoordinating {
    private(set) var opened: [UUID] = []
    private(set) var focused: [UUID] = []
    private var visible: Set<UUID> = []

    func open(_ pin: PinnedReference) async throws {
        opened.append(pin.id)
        visible.insert(pin.id)
    }

    func close(pinID: UUID) async {
        visible.remove(pinID)
    }

    func focus(pinID: UUID) {
        focused.append(pinID)
    }

    func setVisible(_ visible: Bool, pinID: UUID) async throws {
        if visible { self.visible.insert(pinID) } else { self.visible.remove(pinID) }
    }

    func isVisible(pinID: UUID) -> Bool { visible.contains(pinID) }
    func activeWindowIDs() -> Set<CGWindowID> { [] }
    func snapshotFrames() -> [UUID: PersistedPinFrame] { [:] }
}

private func pin(captureID: UUID, restoresAfterRelaunch: Bool) -> PinnedReference {
    PinnedReference(
        id: UUID(), captureID: captureID,
        frame: .init(displayID: "test", panelFrame: .zero, previousVisibleFrame: .zero),
        zoom: 1, normalizedPan: .init(x: 0.5, y: 0.5), opacity: 1,
        isClickThrough: false, collapsedEdge: nil,
        restoresAfterRelaunch: restoresAfterRelaunch,
        createdAt: .now, updatedAt: .now
    )
}

private extension CaptureRecord {
    static func image(id: UUID) -> CaptureRecord { fixture(id: id, kind: .area) }
    static func video(id: UUID) -> CaptureRecord { fixture(id: id, kind: .video) }
    static func gif(id: UUID) -> CaptureRecord { fixture(id: id, kind: .gif) }

    private static func fixture(id: UUID, kind: CaptureKind) -> CaptureRecord {
        .init(
            id: id, kind: kind, title: "Capture", createdAt: .now, lastEditedAt: .now,
            pixelSize: .init(width: 10, height: 10), duration: nil,
            originalFilename: "originals/\(id.uuidString).png", editedFilename: nil,
            thumbnailFilename: "thumbnails/\(id.uuidString).png", annotationFilename: nil,
            ocrText: "", tags: []
        )
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
