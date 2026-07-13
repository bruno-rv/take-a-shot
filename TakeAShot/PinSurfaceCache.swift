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

actor PinSurfaceCache {
    private struct Entry {
        var surface: PinSurface
        var priority: PinSurfacePriority
        var lastUsed: UInt64
    }

    let byteLimit: Int
    private var entries: [UUID: Entry] = [:]
    private var usageCounter: UInt64 = 0
    private(set) var totalBytes = 0

    init(byteLimit: Int = 256 * 1_024 * 1_024) {
        self.byteLimit = max(0, byteLimit)
    }

    func surface(for pinID: UUID) -> PinSurface? {
        guard var entry = entries[pinID] else { return nil }
        entry.lastUsed = nextUsage()
        entries[pinID] = entry
        return entry.surface
    }

    func insert(
        _ surface: PinSurface,
        for pinID: UUID,
        priority: PinSurfacePriority
    ) {
        remove(pinID: pinID)
        guard surface.byteCost <= byteLimit else { return }
        entries[pinID] = Entry(
            surface: surface,
            priority: priority,
            lastUsed: nextUsage()
        )
        totalBytes += surface.byteCost
        evictIfNeeded()
    }

    func updatePriority(_ priority: PinSurfacePriority, for pinID: UUID) {
        guard var entry = entries[pinID] else { return }
        entry.priority = priority
        entries[pinID] = entry
        evictIfNeeded()
    }

    func remove(pinID: UUID) {
        guard let removed = entries.removeValue(forKey: pinID) else { return }
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
            remove(pinID: candidate.key)
        }
    }

    private func nextUsage() -> UInt64 {
        usageCounter &+= 1
        return usageCounter
    }
}
