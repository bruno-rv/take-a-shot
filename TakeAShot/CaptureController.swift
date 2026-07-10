#if os(macOS)
import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyController.shared.register()
    }
}

final class HotKeyController {
    static let shared = HotKeyController()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, _, _ in
            Task { @MainActor in
                ScreenCaptureController.shared.startSelectionCapture()
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: "TAS1".fourCharCode, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_5),
            UInt32(shiftKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

@MainActor
final class ScreenCaptureController {
    static let shared = ScreenCaptureController()

    private var overlayWindow: SelectionOverlayWindow?
    private let thumbnailController = FloatingThumbnailController()

    private init() {}

    func startSelectionCapture() {
        guard ensureScreenCaptureAccess() else { return }
        guard let screen = NSScreen.main else { return }

        let window = SelectionOverlayWindow(screen: screen) { [weak self] rect in
            self?.overlayWindow = nil
            self?.capture(rect: rect, on: screen)
        } onCancel: { [weak self] in
            self?.overlayWindow = nil
        } onFullScreen: { [weak self] in
            self?.overlayWindow = nil
            self?.captureFullScreen(on: screen)
        }

        overlayWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func captureFullScreen() {
        guard ensureScreenCaptureAccess(), let screen = NSScreen.main else { return }
        captureFullScreen(on: screen)
    }

    func copyCurrentCapture() {
        guard let image = AppState.shared.capturedImage else { return }
        copy(image)
    }

    func saveCurrentCapture() {
        guard let image = AppState.shared.capturedImage else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "TakeAShot-\(Self.timestamp()).png"

        if panel.runModal() == .OK, let url = panel.url {
            save(image, to: url)
        }
    }

    private func captureFullScreen(on screen: NSScreen) {
        guard let cgImage = CGDisplayCreateImage(CGMainDisplayID()) else { return }
        let image = NSImage(cgImage: cgImage, size: screen.frame.size)
        publish(image, title: "Full screen capture")
    }

    private func capture(rect: CGRect, on screen: NSScreen) {
        guard rect.width > 8, rect.height > 8 else { return }
        guard let fullImage = CGDisplayCreateImage(CGMainDisplayID()) else { return }

        let scale = screen.backingScaleFactor
        let pixelRect = CGRect(
            x: (rect.minX - screen.frame.minX) * scale,
            y: (screen.frame.maxY - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral

        guard let cropped = fullImage.cropping(to: pixelRect) else { return }
        let image = NSImage(cgImage: cropped, size: rect.size)
        publish(image, title: "Area capture")
    }

    private func publish(_ image: NSImage, title: String) {
        AppState.shared.setCapturedImage(image, title: title)
        thumbnailController.show(image: image)
    }

    private func copy(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func save(_ image: NSImage, to url: URL) {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return
        }

        try? pngData.write(to: url)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: Date())
    }

    private func ensureScreenCaptureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return granted
    }
}

final class SelectionOverlayWindow: NSWindow {
    init(
        screen: NSScreen,
        onSelection: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void,
        onFullScreen: @escaping () -> Void
    ) {
        let view = SelectionOverlayView(frame: screen.frame)
        view.onSelection = onSelection
        view.onCancel = onCancel
        view.onFullScreen = onFullScreen

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.contentView = view
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true
        self.makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionOverlayView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onFullScreen: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let overlayPath = NSBezierPath(rect: bounds)

        if let selection = selectionRect {
            overlayPath.append(NSBezierPath(rect: selection))
            overlayPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.46).setFill()
            overlayPath.fill()

            let path = NSBezierPath(rect: selection)
            path.lineWidth = 2.5
            NSColor.systemBlue.setStroke()
            path.stroke()

            drawHandles(for: selection)
            drawSelectionBadge(for: selection)
            drawDoneBadge(for: selection)
        } else {
            NSColor.black.withAlphaComponent(0.46).setFill()
            bounds.fill()
        }

        drawInstructions()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        if let selection = selectionRect, selection.width > 8, selection.height > 8 {
            window?.orderOut(nil)
            onSelection?(selection)
        } else {
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            window?.orderOut(nil)
            onCancel?()
        case 36:
            window?.orderOut(nil)
            onFullScreen?()
        default:
            super.keyDown(with: event)
        }
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        )
    }

    private func drawInstructions() {
        let message = "Drag to capture a slice   |   Return: whole screen   |   Esc: cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = message.size(withAttributes: attributes)
        let rect = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.maxY - 88,
            width: size.width,
            height: size.height
        )
        message.draw(in: rect, withAttributes: attributes)
    }

    private func drawHandles(for selection: CGRect) {
        let points = [
            CGPoint(x: selection.minX, y: selection.minY),
            CGPoint(x: selection.midX, y: selection.minY),
            CGPoint(x: selection.maxX, y: selection.minY),
            CGPoint(x: selection.minX, y: selection.midY),
            CGPoint(x: selection.maxX, y: selection.midY),
            CGPoint(x: selection.minX, y: selection.maxY),
            CGPoint(x: selection.midX, y: selection.maxY),
            CGPoint(x: selection.maxX, y: selection.maxY)
        ]

        NSColor.systemBlue.setFill()
        for point in points {
            NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }
    }

    private func drawSelectionBadge(for selection: CGRect) {
        let message = "\(Int(selection.width)) x \(Int(selection.height))"
        drawBadge(
            message,
            at: CGPoint(x: selection.midX, y: min(selection.maxY + 18, bounds.maxY - 36)),
            background: NSColor.black.withAlphaComponent(0.72),
            foreground: .white
        )
    }

    private func drawDoneBadge(for selection: CGRect) {
        drawBadge(
            "Release to capture",
            at: CGPoint(x: selection.midX, y: max(selection.minY - 28, bounds.minY + 28)),
            background: NSColor.systemBlue,
            foreground: .white
        )
    }

    private func drawBadge(
        _ message: String,
        at center: CGPoint,
        background: NSColor,
        foreground: NSColor
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: foreground
        ]
        let textSize = message.size(withAttributes: attributes)
        let rect = CGRect(
            x: center.x - (textSize.width + 24) / 2,
            y: center.y - (textSize.height + 10) / 2,
            width: textSize.width + 24,
            height: textSize.height + 10
        )

        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        message.draw(
            in: CGRect(x: rect.minX + 12, y: rect.minY + 5, width: textSize.width, height: textSize.height),
            withAttributes: attributes
        )
    }
}

@MainActor
final class FloatingThumbnailController {
    private var panel: NSPanel?

    func show(image: NSImage) {
        let thumbnailView = FloatingThumbnailView(
            image: image,
            onCopy: {
                ScreenCaptureController.shared.copyCurrentCapture()
            },
            onSave: {
                ScreenCaptureController.shared.saveCurrentCapture()
            },
            onEdit: {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { !$0.isKind(of: NSPanel.self) }?.makeKeyAndOrderFront(nil)
            },
            onClose: { [weak self] in
                self?.panel?.orderOut(nil)
            }
        )

        let hostingView = NSHostingView(rootView: thumbnailView)
        let size = CGSize(width: 320, height: 320)
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let origin = CGPoint(x: screenFrame.minX + 18, y: screenFrame.midY - size.height / 2)

        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.orderFrontRegardless()

        self.panel = panel
    }
}

struct FloatingThumbnailView: View {
    let image: NSImage
    let onCopy: () -> Void
    let onSave: () -> Void
    let onEdit: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 272, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 14, y: 8)

            ZStack {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.56),
                        Color(red: 0.9, green: 0.67, blue: 0.04).opacity(0.72)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 12) {
                    Button(action: onCopy) {
                        Text("Copy")
                            .font(.title3.weight(.semibold))
                            .frame(width: 104, height: 48)
                    }
                    .buttonStyle(FloatingPillButtonStyle())

                    Button(action: onSave) {
                        Text("Save")
                            .font(.title3.weight(.semibold))
                            .frame(width: 104, height: 48)
                    }
                    .buttonStyle(FloatingPillButtonStyle())
                }

                VStack {
                    HStack {
                        thumbnailIcon("pin.fill", action: {})
                            .help("Pin")
                        Spacer()
                        thumbnailIcon("xmark", action: onClose)
                            .help("Close")
                    }
                    Spacer()
                    HStack {
                        thumbnailIcon("pencil.tip", action: onEdit)
                            .help("Edit")
                        Spacer()
                        thumbnailIcon("icloud.and.arrow.up", action: {})
                            .help("Upload")
                    }
                }
                .padding(12)
            }
            .frame(width: 272, height: 148)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 18, y: 10)
        }
        .padding(18)
        .background(Color.clear)
    }

    private func thumbnailIcon(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.86))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct FloatingPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black.opacity(0.86))
            .background(.white.opacity(configuration.isPressed ? 0.72 : 0.88))
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private extension String {
    var fourCharCode: OSType {
        utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
#endif
