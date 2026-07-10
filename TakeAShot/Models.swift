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
