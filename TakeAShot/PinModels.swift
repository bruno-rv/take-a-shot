import CoreGraphics
import Foundation

enum PinEdge: String, Codable, CaseIterable, Sendable {
    case top, right, bottom, left
}

struct PersistedPinFrame: Codable, Equatable, Sendable {
    var displayID: String
    var panelFrame: CGRect
    var previousVisibleFrame: CGRect
}

struct PinnedReference: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let captureID: UUID
    var frame: PersistedPinFrame
    var zoom: Double
    var normalizedPan: NormalizedPoint
    var opacity: Double
    var isClickThrough: Bool
    var collapsedEdge: PinEdge?
    var restoresAfterRelaunch: Bool
    var createdAt: Date
    var updatedAt: Date

    mutating func normalize() {
        zoom = min(max(zoom, 0.25), 8)
        opacity = min(max(opacity, 0.2), 1)
        normalizedPan = NormalizedPoint(
            x: min(max(normalizedPan.x, 0), 1),
            y: min(max(normalizedPan.y, 0), 1)
        )
    }
}

struct PinStoreDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    var pins: [PinnedReference]
}

struct PinLoadIssue: Equatable, Sendable {
    let recordIndex: Int
    let reason: String
}

enum PinStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case malformedDocument
    case atomicPublishFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Pin metadata uses unsupported schema version \(version)."
        case .malformedDocument:
            return "Pin metadata could not be read."
        case let .atomicPublishFailed(message):
            return "Pin metadata could not be saved: \(message)"
        }
    }
}
