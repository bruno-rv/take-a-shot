import CoreGraphics
import Foundation
import ScreenCaptureKit

struct ScreenCaptureWindowSnapshot: Equatable, Sendable {
    let id: CGWindowID
    let frame: CGRect
    let title: String
    let ownerBundleIdentifier: String?
}

struct DisplayCaptureFilterWindow: Equatable, Sendable {
    let id: CGWindowID
    let ownerBundleIdentifier: String?
    let windowLevel: Int

    var isDesktopIconWindow: Bool {
        ownerBundleIdentifier == "com.apple.finder"
            && windowLevel == Int(CGWindowLevelForKey(.desktopIconWindow))
    }
}

enum DisplayCaptureFilterPlan: Equatable, Sendable {
    case excludingWindows([CGWindowID])
}

enum DisplayCaptureFilterPlanner {
    static func plan(
        windows: [DisplayCaptureFilterWindow],
        hidesDesktopIcons: Bool,
        ownBundleIdentifier: String?
    ) -> DisplayCaptureFilterPlan {
        let excludedWindowIDs = windows.compactMap { window -> CGWindowID? in
            let isOwnWindow = ownBundleIdentifier != nil
                && window.ownerBundleIdentifier == ownBundleIdentifier
            let isHiddenDesktopIconWindow = hidesDesktopIcons && window.isDesktopIconWindow
            return isOwnWindow || isHiddenDesktopIconWindow ? window.id : nil
        }
        return .excludingWindows(excludedWindowIDs)
    }
}

struct ScreenCaptureSourceSnapshot: Equatable, Sendable {
    let displays: [DisplayGeometry]
    let windows: [ScreenCaptureWindowSnapshot]
}

struct ScreenCaptureDisplayRequest: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let pixelSize: PixelSize
    let options: CaptureOptions
    let excludedBundleIdentifier: String?
}

struct ScreenCaptureWindowRequest: Equatable, Sendable {
    let windowID: CGWindowID
    let options: CaptureOptions
}

protocol ScreenCaptureKitProviding: Sendable {
    func sourceSnapshot() async throws -> ScreenCaptureSourceSnapshot
    func captureDisplay(_ request: ScreenCaptureDisplayRequest) async throws -> CGImage
    func captureWindow(_ request: ScreenCaptureWindowRequest) async throws -> CGImage
}

enum CaptureSourceSelector {
    static func display(
        _ displayID: CGDirectDisplayID,
        in sources: CaptureSources
    ) throws -> CaptureSource {
        guard let source = sources.displays.first(where: { source in
            guard case .display(let display) = source.kind else { return false }
            return display.id == displayID
        }) else {
            throw CaptureError.sourceUnavailable
        }
        return source
    }

    static func window(
        _ windowID: CGWindowID,
        in sources: CaptureSources
    ) throws -> CaptureSource {
        guard let source = sources.windows.first(where: { source in
            guard case .window(let candidateID, _) = source.kind else { return false }
            return candidateID == windowID
        }) else {
            throw CaptureError.sourceUnavailable
        }
        return source
    }
}

enum WindowSourceFilter {
    static func shouldInclude(
        ownerBundleIdentifier: String?,
        ownBundleIdentifier: String?
    ) -> Bool {
        guard let ownerBundleIdentifier, let ownBundleIdentifier else { return true }
        return ownerBundleIdentifier != ownBundleIdentifier
    }
}

final class ScreenCaptureEngine: ScreenshotCapturing, @unchecked Sendable {
    private let provider: any ScreenCaptureKitProviding
    private let ownBundleIdentifier: String?

    convenience init() {
        self.init(
            provider: ScreenCaptureKitProvider(),
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    init(
        provider: any ScreenCaptureKitProviding,
        ownBundleIdentifier: String?
    ) {
        self.provider = provider
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    func sources() async throws -> CaptureSources {
        let snapshot = try await captureResult {
            try await provider.sourceSnapshot()
        }
        return captureSources(from: snapshot)
    }

    func captureArea(
        _ rect: CGRect,
        display: DisplayGeometry,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        guard rect.width > 0, rect.height > 0, display.frame.contains(rect) else {
            throw CaptureError.invalidSelection
        }

        let sourceRect = CaptureGeometry.sourceRect(selection: rect, display: display)
        let pixelSize = CaptureGeometry.pixelSize(rect: sourceRect, scale: display.scale)
        let request = ScreenCaptureDisplayRequest(
            displayID: display.id,
            sourceRect: sourceRect,
            pixelSize: pixelSize,
            options: options,
            excludedBundleIdentifier: ownBundleIdentifier
        )
        let image = try await captureResult {
            try await provider.captureDisplay(request)
        }
        return capturedImage(image, kind: .area, title: "Area capture")
    }

    func captureDisplay(
        _ displayID: CGDirectDisplayID,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        let availableSources = try await sources()
        let source = try CaptureSourceSelector.display(displayID, in: availableSources)
        guard case .display(let display) = source.kind else {
            throw CaptureError.sourceUnavailable
        }

        let sourceRect = CGRect(origin: .zero, size: display.frame.size)
        let request = ScreenCaptureDisplayRequest(
            displayID: display.id,
            sourceRect: sourceRect,
            pixelSize: CaptureGeometry.pixelSize(rect: sourceRect, scale: display.scale),
            options: options,
            excludedBundleIdentifier: ownBundleIdentifier
        )
        let image = try await captureResult {
            try await provider.captureDisplay(request)
        }
        return capturedImage(image, kind: .display, title: source.title)
    }

    func captureWindow(
        _ windowID: CGWindowID,
        options: CaptureOptions
    ) async throws -> CapturedImage {
        let availableSources = try await sources()
        let source = try CaptureSourceSelector.window(windowID, in: availableSources)
        let request = ScreenCaptureWindowRequest(windowID: windowID, options: options)
        let image = try await captureResult {
            try await provider.captureWindow(request)
        }
        return capturedImage(image, kind: .window, title: source.title)
    }

    private func captureSources(from snapshot: ScreenCaptureSourceSnapshot) -> CaptureSources {
        CaptureSources(
            displays: snapshot.displays.map { display in
                CaptureSource(
                    id: "display:\(display.id)",
                    title: "Display \(display.id)",
                    kind: .display(display)
                )
            },
            windows: snapshot.windows.compactMap { window in
                guard WindowSourceFilter.shouldInclude(
                    ownerBundleIdentifier: window.ownerBundleIdentifier,
                    ownBundleIdentifier: ownBundleIdentifier
                ) else {
                    return nil
                }
                return CaptureSource(
                    id: "window:\(window.id)",
                    title: window.title,
                    kind: .window(window.id, window.frame)
                )
            }
        )
    }

    private func capturedImage(
        _ image: CGImage,
        kind: CaptureKind,
        title: String
    ) -> CapturedImage {
        CapturedImage(
            id: UUID(),
            kind: kind,
            title: title,
            createdAt: .now,
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height)
        )
    }

    private func captureResult<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let captureError as CaptureError {
            throw captureError
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }
}

private final class ScreenCaptureKitProvider: ScreenCaptureKitProviding, @unchecked Sendable {
    func sourceSnapshot() async throws -> ScreenCaptureSourceSnapshot {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let displays = content.displays.map { display in
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return DisplayGeometry(
                id: display.displayID,
                frame: display.frame,
                scale: CGFloat(filter.pointPixelScale)
            )
        }
        let windows = content.windows.map { window in
            ScreenCaptureWindowSnapshot(
                id: window.windowID,
                frame: window.frame,
                title: window.title?.nonEmpty
                    ?? window.owningApplication?.applicationName
                    ?? "Window \(window.windowID)",
                ownerBundleIdentifier: window.owningApplication?.bundleIdentifier
            )
        }
        return ScreenCaptureSourceSnapshot(displays: displays, windows: windows)
    }

    func captureDisplay(_ request: ScreenCaptureDisplayRequest) async throws -> CGImage {
        let content = try await shareableContent(excludingDesktopWindows: false)
        guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else {
            throw CaptureError.sourceUnavailable
        }

        let windows = content.windows.map { window in
            DisplayCaptureFilterWindow(
                id: window.windowID,
                ownerBundleIdentifier: window.owningApplication?.bundleIdentifier,
                windowLevel: window.windowLayer
            )
        }
        let plan = DisplayCaptureFilterPlanner.plan(
            windows: windows,
            hidesDesktopIcons: request.options.excludesDesktopWindows,
            ownBundleIdentifier: request.excludedBundleIdentifier
        )
        let excludedWindowIDs: Set<CGWindowID>
        switch plan {
        case .excludingWindows(let windowIDs):
            excludedWindowIDs = Set(windowIDs)
        }
        let excludedWindows = content.windows.filter {
            excludedWindowIDs.contains($0.windowID)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = request.options.showsCursor
        configuration.sourceRect = request.sourceRect
        configuration.width = max(1, request.pixelSize.width)
        configuration.height = max(1, request.pixelSize.height)
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    func captureWindow(_ request: ScreenCaptureWindowRequest) async throws -> CGImage {
        let content = try await shareableContent(excludingDesktopWindows: false)
        guard let window = content.windows.first(where: { $0.windowID == request.windowID }) else {
            throw CaptureError.sourceUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = request.options.showsCursor
        configuration.width = max(
            1,
            Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        )
        configuration.height = max(
            1,
            Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        )
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    private func shareableContent(
        excludingDesktopWindows: Bool
    ) async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        return try await SCShareableContent.excludingDesktopWindows(
            excludingDesktopWindows,
            onScreenWindowsOnly: true
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
