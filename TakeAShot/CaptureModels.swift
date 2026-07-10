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

struct CaptureRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: CaptureKind
    let title: String
    let createdAt: Date
    var lastEditedAt: Date
    let pixelSize: PixelSize
    var duration: TimeInterval?
    let originalFilename: String
    var editedFilename: String?
    let thumbnailFilename: String
    var annotationFilename: String?
    var ocrText: String
    var tags: [String]
}

struct NormalizedPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }
}

struct NormalizedRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
        self.width = min(1 - self.x, max(0, width))
        self.height = min(1 - self.y, max(0, height))
    }
}

struct RGBAColor: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
}

struct ArrowAnnotation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var start: NormalizedPoint
    var end: NormalizedPoint
    var color: RGBAColor
    var strokeWidth: Double
}

struct TextAnnotation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var bounds: NormalizedRect
    var text: String
    var fontSize: Double
    var color: RGBAColor
}

struct RectAnnotation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var rect: NormalizedRect
    var color: RGBAColor
    var amount: Double
}

enum AnnotationItem: Codable, Equatable, Identifiable, Sendable {
    case arrow(ArrowAnnotation)
    case text(TextAnnotation)
    case highlight(RectAnnotation)
    case blur(RectAnnotation)

    var id: UUID {
        switch self {
        case .arrow(let value): value.id
        case .text(let value): value.id
        case .highlight(let value): value.id
        case .blur(let value): value.id
        }
    }
}

struct AnnotationDocument: Codable, Equatable, Sendable {
    let captureID: UUID
    var items: [AnnotationItem] = []
    var cropRect: NormalizedRect?
}

struct AnnotationHistory: Sendable {
    private(set) var document: AnnotationDocument
    private var undoStack: [AnnotationDocument] = []
    private var redoStack: [AnnotationDocument] = []
    let limit: Int

    init(initial: AnnotationDocument, limit: Int) {
        document = initial
        self.limit = limit
    }

    mutating func commit(_ mutation: (inout AnnotationDocument) -> Void) {
        undoStack.append(document)
        if undoStack.count > limit {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        mutation(&document)
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
    }
}
