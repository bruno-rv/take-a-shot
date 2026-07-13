import CoreGraphics
import Foundation

enum PinSurfacePriority: Int, Sendable {
    case collapsed
    case hidden
    case visible
}

struct PinSurface: @unchecked Sendable {
    let image: CGImage
    let logicalSize: CGSize
    let byteCost: Int
}

struct PinSurfaceCacheKey: Hashable, Sendable {
    let pinID: UUID
    let logicalSize: CGSize
    let backingScale: CGFloat
    let compositionRevision: UInt64

    init(
        pinID: UUID,
        logicalSize: CGSize = .zero,
        backingScale: CGFloat = 1,
        compositionRevision: UInt64 = 0
    ) {
        self.pinID = pinID
        self.logicalSize = logicalSize
        self.backingScale = backingScale
        self.compositionRevision = compositionRevision
    }
}

actor PinSurfaceCache {
    private struct Entry {
        var surface: PinSurface
        var priority: PinSurfacePriority
        var lastUsed: UInt64
    }

    let byteLimit: Int
    private let beforeSurfaceLookup: (@Sendable () async -> Void)?
    private let beforeRemove: (@Sendable () async -> Void)?
    private var entries: [PinSurfaceCacheKey: Entry] = [:]
    private var usageCounter: UInt64 = 0
    private(set) var totalBytes = 0

    init(
        byteLimit: Int = 256 * 1_024 * 1_024,
        beforeSurfaceLookup: (@Sendable () async -> Void)? = nil,
        beforeRemove: (@Sendable () async -> Void)? = nil
    ) {
        self.byteLimit = max(0, byteLimit)
        self.beforeSurfaceLookup = beforeSurfaceLookup
        self.beforeRemove = beforeRemove
    }

    func surface(for key: PinSurfaceCacheKey) async -> PinSurface? {
        await beforeSurfaceLookup?()
        guard var entry = entries[key] else { return nil }
        entry.lastUsed = nextUsage()
        entries[key] = entry
        return entry.surface
    }

    func surface(for pinID: UUID) async -> PinSurface? {
        await surface(for: .init(pinID: pinID))
    }

    func insert(
        _ surface: PinSurface,
        for key: PinSurfaceCacheKey,
        priority: PinSurfacePriority
    ) {
        remove(key: key)
        guard surface.byteCost <= byteLimit else { return }
        entries[key] = Entry(
            surface: surface,
            priority: priority,
            lastUsed: nextUsage()
        )
        totalBytes += surface.byteCost
        evictIfNeeded()
    }

    func insert(
        _ surface: PinSurface,
        for pinID: UUID,
        priority: PinSurfacePriority
    ) {
        insert(surface, for: .init(pinID: pinID), priority: priority)
    }

    func updatePriority(_ priority: PinSurfacePriority, for pinID: UUID) {
        for key in entries.keys where key.pinID == pinID {
            guard var entry = entries[key] else { continue }
            entry.priority = priority
            entries[key] = entry
        }
        evictIfNeeded()
    }

    func remove(pinID: UUID) async {
        await beforeRemove?()
        for key in entries.keys.filter({ $0.pinID == pinID }) {
            remove(key: key)
        }
    }

    private func remove(key: PinSurfaceCacheKey) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalBytes -= removed.surface.byteCost
    }

    func handleMemoryPressure() {
        entries.removeAll()
        totalBytes = 0
    }

    private func evictIfNeeded() {
        while totalBytes > byteLimit,
              let candidate = entries.min(by: { lhs, rhs in
                  if lhs.value.priority != rhs.value.priority {
                      return lhs.value.priority.rawValue < rhs.value.priority.rawValue
                  }
                  return lhs.value.lastUsed < rhs.value.lastUsed
              }) {
            remove(key: candidate.key)
        }
    }

    private func nextUsage() -> UInt64 {
        usageCounter &+= 1
        return usageCounter
    }
}
