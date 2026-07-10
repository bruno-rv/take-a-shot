import CoreGraphics
import Foundation

enum CaptureKind: String, Codable, Sendable {
    case area, window, display, scrolling, video, gif
}

enum ExportFormat: String, CaseIterable, Sendable {
    case png, jpeg
}

struct PixelSize: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
}

struct DisplayGeometry: Equatable, Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
}

struct CaptureOptions: Equatable, Sendable {
    var showsCursor = true
    var excludesDesktopWindows = false
    var delay: Duration = .zero
}

struct CapturedImage: @unchecked Sendable {
    let id: UUID
    let kind: CaptureKind
    let title: String
    let createdAt: Date
    let image: CGImage
    let pixelSize: PixelSize
}
