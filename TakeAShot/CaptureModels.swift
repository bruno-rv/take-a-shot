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

enum RecordingFormat: Equatable, Sendable {
    case mp4
    case gif
}

enum RecordingTarget: Equatable, Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

struct RecordingRequest: Equatable, Sendable {
    let target: RecordingTarget
    let format: RecordingFormat
    let includesSystemAudio: Bool
    let includesMicrophone: Bool
    let framesPerSecond: Int
}

enum RecordingState: Equatable, Sendable {
    case idle
    case preparing
    case recording(startedAt: Date)
    case stopping
    case completed(URL)
    case failed(String)
}

enum RecordingStateKind: Equatable, Sendable {
    case idle
    case preparing
    case recording
    case stopping
    case completed
    case failed
}

enum RecordingOperation: Equatable, Sendable {
    case start
    case stop
}

enum RecordingError: Error, Equatable, LocalizedError, Sendable {
    case invalidTransition(RecordingOperation, RecordingStateKind)
    case invalidFrameRate(Int)
    case invalidGIFFrameRate(Int)
    case gifAudioUnsupported
    case unsupportedFormat(RecordingFormat)
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case sourceUnavailable
    case writerSetupFailed(String)
    case recordingFailed(String)
    case audioBackpressureOverflow(limit: Int)
    case audioBackpressureTimeout
    case audioWriterFailed(String)
    case gifEncodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTransition(let operation, let state):
            return "Cannot \(operation.description) while recording is \(state.description)."
        case .invalidFrameRate(let value):
            return "Recording frame rate must be between 1 and 30 fps (received \(value))."
        case .invalidGIFFrameRate(let value):
            return "GIF frame rate must be between 1 and 10 fps (received \(value))."
        case .gifAudioUnsupported:
            return "GIF recording does not support system or microphone audio."
        case .unsupportedFormat(let format):
            return "\(format.description) recording is not available yet."
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is required. Enable Take a Shot in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .microphonePermissionDenied:
            return "Microphone access was denied. Enable Take a Shot in System Settings > Privacy & Security > Microphone, or record without microphone audio."
        case .sourceUnavailable:
            return "The selected recording source is no longer available."
        case .writerSetupFailed(let message):
            return "Could not prepare the recording: \(message)"
        case .recordingFailed(let message):
            return "Recording failed: \(message)"
        case .audioBackpressureOverflow(let limit):
            return "Recording audio could not keep up and exceeded its \(limit)-buffer limit."
        case .audioBackpressureTimeout:
            return "Recording audio did not become writable before finalization timed out."
        case .audioWriterFailed(let message):
            return "Recording audio could not be written: \(message)"
        case .gifEncodingFailed(let message):
            return "GIF recording could not be encoded: \(message)"
        }
    }
}

private extension RecordingOperation {
    var description: String {
        switch self {
        case .start: "start"
        case .stop: "stop"
        }
    }
}

private extension RecordingStateKind {
    var description: String {
        switch self {
        case .idle: "idle"
        case .preparing: "preparing"
        case .recording: "recording"
        case .stopping: "stopping"
        case .completed: "completed"
        case .failed: "failed"
        }
    }
}

private extension RecordingFormat {
    var description: String {
        switch self {
        case .mp4: "MP4"
        case .gif: "GIF"
        }
    }
}

extension RecordingState {
    var kind: RecordingStateKind {
        switch self {
        case .idle: .idle
        case .preparing: .preparing
        case .recording: .recording
        case .stopping: .stopping
        case .completed: .completed
        case .failed: .failed
        }
    }
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
