import CoreGraphics
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum CaptureMode: String, CaseIterable, Identifiable {
    case area = "Area"
    case window = "Window"
    case fullScreen = "Fullscreen"
    case scrolling = "Scrolling"
    case record = "Record"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .area: "selection.pin.in.out"
        case .window: "macwindow"
        case .fullScreen: "viewfinder"
        case .scrolling: "arrow.up.and.down.and.arrow.left.and.right"
        case .record: "video"
        }
    }
}

enum CaptureIntent: Equatable, Sendable {
    case areaSelection
    case windowPicker
    case display
    case scrollingWindowPicker
    case recordingPicker

    init(mode: CaptureMode) {
        switch mode {
        case .area:
            self = .areaSelection
        case .window:
            self = .windowPicker
        case .fullScreen:
            self = .display
        case .scrolling:
            self = .scrollingWindowPicker
        case .record:
            self = .recordingPicker
        }
    }

    var isAvailable: Bool {
        switch self {
        case .areaSelection, .windowPicker, .display:
            true
        case .scrollingWindowPicker, .recordingPicker:
            false
        }
    }

    var captureButtonTitle: String {
        switch self {
        case .areaSelection:
            "Capture Area"
        case .windowPicker:
            "Capture Window"
        case .display:
            "Capture Fullscreen"
        case .scrollingWindowPicker:
            "Scrolling — Coming later"
        case .recordingPicker:
            "Record — Coming later"
        }
    }
}

struct CaptureSource: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case display(DisplayGeometry)
        case window(CGWindowID, CGRect)
    }

    let id: String
    let title: String
    let kind: Kind
}

struct CaptureSources: Equatable, Sendable {
    let displays: [CaptureSource]
    let windows: [CaptureSource]
}

struct AreaSelection: Equatable, Sendable {
    let rect: CGRect
    let display: DisplayGeometry

    var displayID: CGDirectDisplayID { display.id }

    init(localRect: CGRect, display: DisplayGeometry) {
        rect = localRect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
        self.display = display
    }
}

enum CaptureError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case sourceUnavailable
    case invalidSelection
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen recording permission is required."
        case .sourceUnavailable:
            "The selected capture source is no longer available."
        case .invalidSelection:
            "The selected area is not valid."
        case .captureFailed(let message):
            message
        }
    }
}

protocol ScreenshotCapturing: Sendable {
    func sources() async throws -> CaptureSources
    func captureArea(
        _ rect: CGRect,
        display: DisplayGeometry,
        options: CaptureOptions
    ) async throws -> CapturedImage
    func captureDisplay(
        _ displayID: CGDirectDisplayID,
        options: CaptureOptions
    ) async throws -> CapturedImage
    func captureWindow(
        _ windowID: CGWindowID,
        options: CaptureOptions
    ) async throws -> CapturedImage
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case arrow = "Arrow"
    case text = "Text"
    case highlight = "Highlight"
    case blur = "Blur"
    case crop = "Crop"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .text: "text.cursor"
        case .highlight: "highlighter"
        case .blur: "drop.degreesign"
        case .crop: "crop"
        }
    }
}

struct RecentCapture: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let status: String
    let symbol: String
}

let recentCaptures: [RecentCapture] = [
    RecentCapture(title: "billing-flow.png", subtitle: "Area capture - 2 min ago", status: "Uploaded", symbol: "photo"),
    RecentCapture(title: "settings-tour.gif", subtitle: "GIF recording - 18 min ago", status: "Local", symbol: "film"),
    RecentCapture(title: "release-notes.png", subtitle: "Scrolling capture - 1 hr ago", status: "Uploaded", symbol: "doc.richtext")
]

#if os(macOS)
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var capturedImage: NSImage?
    @Published var capturedTitle = "No capture yet"

    private init() {}

    func setCapturedImage(_ image: NSImage, title: String = "Screen capture") {
        capturedImage = image
        capturedTitle = title
    }
}
#endif
