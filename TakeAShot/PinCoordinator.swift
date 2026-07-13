import Combine
import CoreGraphics
import Foundation

protocol PinCoordinatorLibraryServing: Sendable {
    func record(id: UUID) async throws -> CaptureRecord?
    func changes() async -> AsyncStream<CaptureLibraryChange>
}

struct AppLibraryPinCoordinatorLibrary: PinCoordinatorLibraryServing {
    let library: any AppLibraryServing

    func record(id: UUID) async throws -> CaptureRecord? {
        try await library.load(matching: "").first { $0.id == id }
    }

    func changes() async -> AsyncStream<CaptureLibraryChange> {
        await library.changes()
    }
}

enum PinPresentationState: Equatable, Sendable {
    case ready
    case missingSource(UUID)
}

enum PinCoordinatorError: LocalizedError, Equatable {
    case unsupportedCaptureKind(CaptureKind)
    case pinNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .unsupportedCaptureKind:
            "Only image captures can be pinned."
        case .pinNotFound:
            "The pin is no longer available."
        }
    }
}

struct PinLayoutUpdate: Sendable {
    var frame: PersistedPinFrame?
    var zoom: Double?
    var normalizedPan: NormalizedPoint?
    var opacity: Double?
    var isClickThrough: Bool?
    var collapsedEdge: PinEdge??

    init(
        frame: PersistedPinFrame? = nil,
        zoom: Double? = nil,
        normalizedPan: NormalizedPoint? = nil,
        opacity: Double? = nil,
        isClickThrough: Bool? = nil,
        collapsedEdge: PinEdge?? = nil
    ) {
        self.frame = frame
        self.zoom = zoom
        self.normalizedPan = normalizedPan
        self.opacity = opacity
        self.isClickThrough = isClickThrough
        self.collapsedEdge = collapsedEdge
    }
}

struct PinVisibilitySnapshot: Equatable, Sendable {
    let visiblePinIDs: Set<UUID>
}

struct PinDeletionReservation: Sendable {
    let captureID: UUID
    let removedPins: [PinnedReference]
}

enum PinChange: Equatable, Sendable {
    case updated(PinnedReference)
    case removed(UUID)
    case renderInvalidated(UUID)
    case metadataChanged(UUID)
    case presentationChanged(UUID, PinPresentationState)
}

@MainActor
final class PinCoordinator: ObservableObject {
    @Published private(set) var pins: [PinnedReference] = []
    @Published private(set) var presentedError: PresentedError?

    var activePinIDs: Set<UUID> { Set(pins.map(\.id)) }
    var visiblePinIDs: Set<UUID> {
        Set(pins.lazy.map(\.id).filter { self.windows.isVisible(pinID: $0) })
    }

    private let store: any PinStoring
    private let library: any PinCoordinatorLibraryServing
    private let windows: any PinWindowCoordinating
    private let flushActiveAnnotations: @MainActor () async throws -> Void
    private var states: [UUID: PinPresentationState] = [:]
    private let pinChangeStream: AsyncStream<PinChange>
    private let pinChangeContinuation: AsyncStream<PinChange>.Continuation
    private var libraryChangeTask: Task<Void, Never>?

    init(
        store: any PinStoring,
        library: any PinCoordinatorLibraryServing,
        windows: any PinWindowCoordinating,
        flushActiveAnnotations: @escaping @MainActor () async throws -> Void = {}
    ) {
        self.store = store
        self.library = library
        self.windows = windows
        self.flushActiveAnnotations = flushActiveAnnotations
        var continuation: AsyncStream<PinChange>.Continuation?
        pinChangeStream = AsyncStream { continuation = $0 }
        pinChangeContinuation = continuation!
        libraryChangeTask = Task { [weak self, library] in
            let changes = await library.changes()
            for await change in changes {
                guard !Task.isCancelled else { return }
                self?.handleLibraryChange(change)
            }
        }
    }

    convenience init(
        store: any PinStoring,
        library: any PinCoordinatorLibraryServing,
        flushActiveAnnotations: @escaping @MainActor () async throws -> Void = {}
    ) {
        self.init(
            store: store,
            library: library,
            windows: PinWindowCoordinator(),
            flushActiveAnnotations: flushActiveAnnotations
        )
    }

    deinit {
        libraryChangeTask?.cancel()
        pinChangeContinuation.finish()
    }

    func changes() -> AsyncStream<PinChange> { pinChangeStream }

    func state(for pinID: UUID) -> PinPresentationState? { states[pinID] }

    func pin(captureID: UUID) async throws -> UUID {
        if let existing = pins.first(where: { $0.captureID == captureID }) {
            windows.focus(pinID: existing.id)
            return existing.id
        }
        guard let record = try await library.record(id: captureID) else {
            throw PinCoordinatorError.pinNotFound(captureID)
        }
        guard ![CaptureKind.video, .gif].contains(record.kind) else {
            throw PinCoordinatorError.unsupportedCaptureKind(record.kind)
        }

        try await flushActiveAnnotations()
        let reference = makePinnedReference(captureID: captureID)
        try await windows.open(reference)
        pins.append(reference)
        states[reference.id] = .ready
        await store.scheduleUpsert(reference)
        pinChangeContinuation.yield(.updated(reference))
        return reference.id
    }

    func focus(pinID: UUID) {
        windows.focus(pinID: pinID)
    }

    func close(pinID: UUID) async throws {
        guard let reference = pins.first(where: { $0.id == pinID }) else {
            throw PinCoordinatorError.pinNotFound(pinID)
        }
        if reference.restoresAfterRelaunch {
            var noLongerPersistent = reference
            noLongerPersistent.restoresAfterRelaunch = false
            noLongerPersistent.updatedAt = .now
            replace(noLongerPersistent)
            await store.scheduleUpsert(noLongerPersistent)
            try await store.flush()
            pinChangeContinuation.yield(.updated(noLongerPersistent))
        } else {
            try await store.remove(id: pinID)
        }
        pins.removeAll { $0.id == pinID }
        states.removeValue(forKey: pinID)
        pinChangeContinuation.yield(.removed(pinID))
        await windows.close(pinID: pinID)
    }

    func setPersistent(_ persistent: Bool, pinID: UUID) async throws {
        guard var reference = pins.first(where: { $0.id == pinID }) else {
            throw PinCoordinatorError.pinNotFound(pinID)
        }
        reference.restoresAfterRelaunch = persistent
        reference.updatedAt = .now
        replace(reference)
        await store.scheduleUpsert(reference)
        pinChangeContinuation.yield(.updated(reference))
    }

    func updateLayout(_ update: PinLayoutUpdate, pinID: UUID) {
        guard var reference = pins.first(where: { $0.id == pinID }) else { return }
        if let frame = update.frame { reference.frame = frame }
        if let zoom = update.zoom { reference.zoom = zoom }
        if let normalizedPan = update.normalizedPan { reference.normalizedPan = normalizedPan }
        if let opacity = update.opacity { reference.opacity = opacity }
        if let isClickThrough = update.isClickThrough { reference.isClickThrough = isClickThrough }
        if let collapsedEdge = update.collapsedEdge { reference.collapsedEdge = collapsedEdge }
        reference.updatedAt = .now
        reference.normalize()
        replace(reference)
        Task { await store.scheduleUpsert(reference) }
        pinChangeContinuation.yield(.updated(reference))
    }

    func restorePersistentPins() async throws {
        let storedPins = try await store.load()
        for reference in storedPins where reference.restoresAfterRelaunch {
            guard !activePinIDs.contains(reference.id) else { continue }
            guard let record = try await library.record(id: reference.captureID) else {
                try await openMissingReference(reference)
                continue
            }
            guard ![CaptureKind.video, .gif].contains(record.kind) else { continue }
            try await windows.open(reference)
            pins.append(reference)
            states[reference.id] = .ready
            pinChangeContinuation.yield(.updated(reference))
        }
    }

    func setVisible(_ visible: Bool, pinID: UUID) async throws {
        guard activePinIDs.contains(pinID) else { throw PinCoordinatorError.pinNotFound(pinID) }
        try await windows.setVisible(visible, pinID: pinID)
    }

    func hideAll() async throws -> PinVisibilitySnapshot {
        let snapshot = PinVisibilitySnapshot(visiblePinIDs: visiblePinIDs)
        for pinID in snapshot.visiblePinIDs {
            try await windows.setVisible(false, pinID: pinID)
        }
        return snapshot
    }

    func showAll(from snapshot: PinVisibilitySnapshot) async throws {
        for pinID in snapshot.visiblePinIDs where activePinIDs.contains(pinID) {
            try await windows.setVisible(true, pinID: pinID)
        }
    }

    func flush() async throws {
        try await store.flush()
    }

    func activeWindowIDs() -> Set<CGWindowID> {
        windows.activeWindowIDs()
    }

    private func handleLibraryChange(_ change: CaptureLibraryChange) {
        switch change {
        case let .deleted(captureID):
            for reference in pins where reference.captureID == captureID {
                states[reference.id] = .missingSource(captureID)
                pinChangeContinuation.yield(.presentationChanged(reference.id, .missingSource(captureID)))
            }
        case let .imageOrAnnotationsChanged(captureID):
            for reference in pins where reference.captureID == captureID {
                states[reference.id] = .ready
                pinChangeContinuation.yield(.renderInvalidated(reference.id))
            }
        case let .metadataChanged(captureID):
            for reference in pins where reference.captureID == captureID {
                pinChangeContinuation.yield(.metadataChanged(reference.id))
            }
        }
    }

    private func openMissingReference(_ reference: PinnedReference) async throws {
        guard !activePinIDs.contains(reference.id) else { return }
        try await windows.open(reference)
        pins.append(reference)
        let state = PinPresentationState.missingSource(reference.captureID)
        states[reference.id] = state
        pinChangeContinuation.yield(.presentationChanged(reference.id, state))
    }

    private func replace(_ reference: PinnedReference) {
        guard let index = pins.firstIndex(where: { $0.id == reference.id }) else { return }
        pins[index] = reference
    }

    private func makePinnedReference(captureID: UUID) -> PinnedReference {
        PinnedReference(
            id: UUID(),
            captureID: captureID,
            frame: PersistedPinFrame(
                displayID: "",
                panelFrame: CGRect(x: 80, y: 80, width: 480, height: 270),
                previousVisibleFrame: .zero
            ),
            zoom: 1,
            normalizedPan: NormalizedPoint(x: 0.5, y: 0.5),
            opacity: 1,
            isClickThrough: false,
            collapsedEdge: nil,
            restoresAfterRelaunch: true,
            createdAt: .now,
            updatedAt: .now
        )
    }
}
