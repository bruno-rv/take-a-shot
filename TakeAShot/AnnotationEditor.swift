import AppKit
import CoreGraphics
import SwiftUI

struct CanvasTransform {
    let imageRect: CGRect

    init(canvasSize: CGSize, imageSize: CGSize, zoom: CGFloat) {
        let scale = min(
            canvasSize.width / imageSize.width,
            canvasSize.height / imageSize.height
        ) * zoom
        let size = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        imageRect = CGRect(
            x: (canvasSize.width - size.width) / 2,
            y: (canvasSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func normalizedPoint(from point: CGPoint) -> NormalizedPoint? {
        guard imageRect.contains(point) else { return nil }
        return NormalizedPoint(
            x: Double((point.x - imageRect.minX) / imageRect.width),
            y: Double((point.y - imageRect.minY) / imageRect.height)
        )
    }

    func canvasPoint(from point: NormalizedPoint) -> CGPoint {
        CGPoint(
            x: imageRect.minX + CGFloat(point.x) * imageRect.width,
            y: imageRect.minY + CGFloat(point.y) * imageRect.height
        )
    }

    func canvasRect(from rect: NormalizedRect) -> CGRect {
        CGRect(
            x: imageRect.minX + CGFloat(rect.x) * imageRect.width,
            y: imageRect.minY + CGFloat(rect.y) * imageRect.height,
            width: CGFloat(rect.width) * imageRect.width,
            height: CGFloat(rect.height) * imageRect.height
        )
    }

    func clampedNormalizedPoint(from point: CGPoint) -> NormalizedPoint {
        NormalizedPoint(
            x: Double((point.x - imageRect.minX) / imageRect.width),
            y: Double((point.y - imageRect.minY) / imageRect.height)
        )
    }
}

protocol AnnotationRenderServicing: Sendable {
    func render(
        capture: CapturedImage,
        document: AnnotationDocument
    ) async throws -> CGImage
}

struct DetachedAnnotationRenderService: AnnotationRenderServicing {
    typealias Operation = @Sendable (CGImage, AnnotationDocument) throws -> CGImage

    private let operation: Operation

    init(operation: @escaping Operation = { source, document in
        try AnnotationRenderer().render(source: source, document: document)
    }) {
        self.operation = operation
    }

    func render(
        capture: CapturedImage,
        document: AnnotationDocument
    ) async throws -> CGImage {
        let source = capture.image
        let operation = operation
        return try await Task.detached(priority: .userInitiated) {
            try operation(source, document)
        }.value
    }
}

actor AnnotationPreviewService {
    nonisolated static let maximumPixelSize = 4_096

    typealias Operation = @Sendable (
        CGImage,
        AnnotationDocument,
        Int
    ) async throws -> CGImage

    private final class Request {
        let id: UUID
        let source: CGImage
        let document: AnnotationDocument
        let maxPixelSize: Int
        var continuation: CheckedContinuation<CGImage, Error>?

        init(
            id: UUID,
            source: CGImage,
            document: AnnotationDocument,
            maxPixelSize: Int,
            continuation: CheckedContinuation<CGImage, Error>
        ) {
            self.id = id
            self.source = source
            self.document = document
            self.maxPixelSize = maxPixelSize
            self.continuation = continuation
        }
    }

    private let operation: Operation
    private var activeRequest: Request?
    private var pendingRequest: Request?
    private var isProcessing = false

    init(operation: @escaping Operation = { source, document, maxPixelSize in
        try await Task.detached(priority: .userInitiated) {
            let previewSource = try ImageExporter.thumbnail(
                for: source,
                maxPixelSize: maxPixelSize
            )
            let scale = CGFloat(previewSource.width) / CGFloat(source.width)
            return try AnnotationRenderer().render(
                source: previewSource,
                document: document,
                appliesCrop: false,
                annotationScale: scale
            )
        }.value
    }) {
        self.operation = operation
    }

    func render(
        capture: CapturedImage,
        document: AnnotationDocument,
        maxPixelSize: Int
    ) async throws -> CGImage {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    Request(
                        id: id,
                        source: capture.image,
                        document: document,
                        maxPixelSize: min(
                            Self.maximumPixelSize,
                            max(1, maxPixelSize)
                        ),
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func enqueue(_ request: Request) {
        if let pendingRequest {
            pendingRequest.continuation?.resume(throwing: CancellationError())
            pendingRequest.continuation = nil
        }
        pendingRequest = request
        guard !isProcessing else { return }
        isProcessing = true
        Task { await processRequests() }
    }

    private func cancel(id: UUID) {
        if pendingRequest?.id == id {
            pendingRequest?.continuation?.resume(throwing: CancellationError())
            pendingRequest = nil
            return
        }
        if activeRequest?.id == id {
            activeRequest?.continuation?.resume(throwing: CancellationError())
            activeRequest?.continuation = nil
        }
    }

    private func processRequests() async {
        while let request = pendingRequest {
            pendingRequest = nil
            activeRequest = request
            do {
                let image = try await operation(
                    request.source,
                    request.document,
                    request.maxPixelSize
                )
                request.continuation?.resume(returning: image)
            } catch {
                request.continuation?.resume(throwing: error)
            }
            request.continuation = nil
            activeRequest = nil
        }
        isProcessing = false
    }
}

@MainActor
protocol AnnotationClipboardPublishing: AnyObject {
    func publish(_ image: CGImage)
}

@MainActor
struct AnnotationExportCoordinator {
    let renderService: any AnnotationRenderServicing
    let clipboard: any AnnotationClipboardPublishing

    func copy(
        capture: CapturedImage,
        document: AnnotationDocument
    ) async throws {
        let rendered = try await renderService.render(
            capture: capture,
            document: document
        )
        clipboard.publish(rendered)
    }
}

struct AnnotationStyle: Equatable, Sendable {
    var color: RGBAColor
    var strokeWidth: Double
    var opacity: Double
    var blurRadius: Double
    var fontSize: Double
    var emoji: String = "😀"

    /// Emoji tool default font size — larger than the Text tool's default so a placed glyph reads
    /// clearly at a glance. Not user-adjustable via the style (no slider), unlike `fontSize`.
    static let emojiFontSize: Double = 64

    static let standard = AnnotationStyle(
        color: .red,
        strokeWidth: 4,
        opacity: 0.4,
        blurRadius: 10,
        fontSize: 22
    )
}

/// A selectable entry in the shared annotation color palette. `displayColor` is the SwiftUI color
/// shown on the swatch and may intentionally diverge from `color` (e.g. "blue" renders as the
/// system accent color so the swatch tracks the user's tint, while the persisted annotation color
/// stays a fixed value).
struct AnnotationColorOption: Identifiable, Equatable {
    let id: String
    let color: RGBAColor
    let displayColor: Color
    let accessibilityLabel: String
}

/// Shared across the inspector, editor, and (later) the Quick Annotation overlay toolbar.
enum AnnotationPalette {
    static let options: [AnnotationColorOption] = [
        AnnotationColorOption(
            id: "red",
            color: .red,
            displayColor: .red,
            accessibilityLabel: "red"
        ),
        AnnotationColorOption(
            id: "blue",
            color: RGBAColor(red: 0.16, green: 0.5, blue: 1, alpha: 1),
            displayColor: .accentColor,
            accessibilityLabel: "blue"
        ),
        AnnotationColorOption(
            id: "yellow",
            color: RGBAColor(red: 1, green: 0.82, blue: 0.12, alpha: 1),
            displayColor: .yellow,
            accessibilityLabel: "yellow"
        ),
        AnnotationColorOption(
            id: "charcoal",
            color: RGBAColor(red: 0.13, green: 0.17, blue: 0.25, alpha: 1),
            displayColor: Color(red: 0.13, green: 0.17, blue: 0.25),
            accessibilityLabel: "charcoal"
        ),
    ]

    /// Small, fixed emoji picker for the Emoji tool. Deliberately not a full macOS emoji picker
    /// (out of scope per PLAN.md).
    static let emojiOptions: [String] = [
        "😀", "😂", "😍", "😎", "🤔", "😢",
        "😡", "👍", "👎", "👀", "🙌", "🤝",
        "❤️", "🔥", "⭐️", "✅", "❌", "⚠️",
        "💡", "🚀", "🎯", "🎉", "💯", "📌",
    ]
}

/// A text annotation being typed but not yet committed — PLAN.md "Text Input". `rect` is the
/// resizable wrap box (becomes `TextAnnotation.bounds` on commit); `minSize` is the normalized
/// floor computed once at `beginText` from the image's `PixelSize` (never recomputed mid-edit, so
/// it stays stable even if the rect itself later shrinks toward it). `userSized` becomes `true`
/// the moment a person drags a resize handle, after which auto-grow-on-typing stops touching the
/// rect.
struct PendingAnnotationText: Equatable, Sendable {
    var rect: NormalizedRect
    var text: String
    var minSize: NormalizedSize
    var userSized: Bool = false
}

enum AnnotationResizeHandle: CaseIterable, Identifiable, Sendable {
    case topLeading
    case top
    case topTrailing
    case leading
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing

    var id: Self { self }

    static let cornerCases: [Self] = [
        .topLeading,
        .topTrailing,
        .bottomLeading,
        .bottomTrailing,
    ]

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeading:
            CGPoint(x: rect.minX, y: rect.minY)
        case .top:
            CGPoint(x: rect.midX, y: rect.minY)
        case .topTrailing:
            CGPoint(x: rect.maxX, y: rect.minY)
        case .leading:
            CGPoint(x: rect.minX, y: rect.midY)
        case .trailing:
            CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeading:
            CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom:
            CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomTrailing:
            CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    func point(in rect: NormalizedRect) -> NormalizedPoint {
        switch self {
        case .topLeading:
            NormalizedPoint(x: rect.x, y: rect.y)
        case .top:
            NormalizedPoint(x: rect.x + rect.width / 2, y: rect.y)
        case .topTrailing:
            NormalizedPoint(x: rect.x + rect.width, y: rect.y)
        case .leading:
            NormalizedPoint(x: rect.x, y: rect.y + rect.height / 2)
        case .trailing:
            NormalizedPoint(x: rect.x + rect.width, y: rect.y + rect.height / 2)
        case .bottomLeading:
            NormalizedPoint(x: rect.x, y: rect.y + rect.height)
        case .bottom:
            NormalizedPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height)
        case .bottomTrailing:
            NormalizedPoint(x: rect.x + rect.width, y: rect.y + rect.height)
        }
    }

    func oppositePoint(in rect: NormalizedRect) -> NormalizedPoint {
        switch self {
        case .topLeading:
            NormalizedPoint(x: rect.x + rect.width, y: rect.y + rect.height)
        case .top:
            NormalizedPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height)
        case .topTrailing:
            NormalizedPoint(x: rect.x, y: rect.y + rect.height)
        case .leading:
            NormalizedPoint(x: rect.x + rect.width, y: rect.y + rect.height / 2)
        case .trailing:
            NormalizedPoint(x: rect.x, y: rect.y + rect.height / 2)
        case .bottomLeading:
            NormalizedPoint(x: rect.x + rect.width, y: rect.y)
        case .bottom:
            NormalizedPoint(x: rect.x + rect.width / 2, y: rect.y)
        case .bottomTrailing:
            NormalizedPoint(x: rect.x, y: rect.y)
        }
    }

    func resized(_ rect: NormalizedRect, to point: NormalizedPoint) -> NormalizedRect {
        switch self {
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing:
            return NormalizedRect.containing(point, oppositePoint(in: rect))
        case .top:
            return NormalizedRect(
                x: rect.x,
                y: min(point.y, rect.y + rect.height),
                width: rect.width,
                height: abs(rect.y + rect.height - point.y)
            )
        case .leading:
            return NormalizedRect(
                x: min(point.x, rect.x + rect.width),
                y: rect.y,
                width: abs(rect.x + rect.width - point.x),
                height: rect.height
            )
        case .trailing:
            return NormalizedRect(
                x: min(rect.x, point.x),
                y: rect.y,
                width: abs(point.x - rect.x),
                height: rect.height
            )
        case .bottom:
            return NormalizedRect(
                x: rect.x,
                y: min(rect.y, point.y),
                width: rect.width,
                height: abs(point.y - rect.y)
            )
        }
    }
}

struct AnnotationEditorState: Sendable {
    private var history: AnnotationHistory
    private(set) var selectedItemID: UUID?
    private(set) var isCropSelected = false
    private(set) var pendingText: PendingAnnotationText?

    var document: AnnotationDocument { history.document }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    init(document: AnnotationDocument, historyLimit: Int = 50) {
        history = AnnotationHistory(initial: document, limit: historyLimit)
    }

    mutating func applyDrag(
        tool: AnnotationTool,
        from start: NormalizedPoint,
        to end: NormalizedPoint,
        style: AnnotationStyle
    ) {
        switch tool {
        case .select:
            break
        case .arrow:
            let annotation = ArrowAnnotation(
                id: UUID(),
                start: start,
                end: end,
                color: style.color,
                strokeWidth: style.strokeWidth
            )
            commit(.arrow(annotation))
        case .highlight:
            let annotation = RectAnnotation(
                id: UUID(),
                rect: Self.rect(containing: start, and: end),
                color: style.color,
                amount: style.opacity
            )
            commit(.highlight(annotation))
        case .blur:
            let annotation = RectAnnotation(
                id: UUID(),
                rect: Self.rect(containing: start, and: end),
                color: style.color,
                amount: style.blurRadius
            )
            commit(.blur(annotation))
        case .crop:
            let cropRect = Self.rect(containing: start, and: end)
            guard cropRect != document.cropRect else { return }
            history.commit { $0.cropRect = cropRect }
            selectedItemID = nil
            isCropSelected = true
        case .rect, .ellipse:
            let annotation = ShapeAnnotation(
                id: UUID(),
                kind: tool == .rect ? .rect : .ellipse,
                rect: Self.rect(containing: start, and: end),
                color: style.color,
                strokeWidth: style.strokeWidth
            )
            commit(.shape(annotation))
        case .text, .steps, .emoji:
            // Click-to-place tools: created via `placeStep`/`placeEmoji`, not drag.
            break
        }
    }

    mutating func placeStep(at point: NormalizedPoint) {
        let nextNumber = 1 + (document.items.compactMap { item -> Int? in
            guard case .step(let annotation) = item else { return nil }
            return annotation.number
        }.max() ?? 0)
        let annotation = StepAnnotation(id: UUID(), center: point, number: nextNumber)
        commit(.step(annotation))
    }

    mutating func placeEmoji(
        at point: NormalizedPoint,
        style: AnnotationStyle
    ) {
        let annotation = TextAnnotation(
            id: UUID(),
            bounds: NormalizedRect(x: point.x, y: point.y, width: 0.12, height: 0.12),
            text: style.emoji,
            fontSize: AnnotationStyle.emojiFontSize,
            color: style.color
        )
        commit(.text(annotation))
    }

    mutating func beginText(
        rect: NormalizedRect,
        minSize: NormalizedSize,
        style: AnnotationStyle
    ) {
        resolvePendingText(style: style)
        pendingText = PendingAnnotationText(rect: rect, text: "", minSize: minSize)
    }

    mutating func updatePendingText(_ text: String) {
        pendingText?.text = text
    }

    /// Pending-only resize (PLAN.md "Text Input") — `resizeSelection` is hard-wired to committed
    /// `AnnotationItem`s and never sees a pending text box. Clamps the dragged handle's point
    /// against `pendingText.minSize` before resizing, so the box can never collapse below its
    /// floor no matter how far the handle is dragged past it. Marks `userSized`, which stops
    /// auto-grow from touching the rect again.
    mutating func resizePendingText(
        handle: AnnotationResizeHandle,
        to point: NormalizedPoint
    ) {
        guard var pending = pendingText else { return }
        let clampedPoint = Self.clampResizePoint(
            point,
            handle: handle,
            in: pending.rect,
            minSize: pending.minSize
        )
        pending.rect = handle.resized(pending.rect, to: clampedPoint)
        pending.userSized = true
        pendingText = pending
    }

    /// Grows the pending box's height to fit wrapped text as it's typed — width is never touched
    /// here (only handle drags change width) — until `userSized` is set, after which the rect is
    /// authoritative and this is a no-op.
    mutating func growPendingText(toHeight height: Double) {
        guard var pending = pendingText, !pending.userSized else { return }
        let clampedHeight = max(pending.minSize.height, height)
        guard clampedHeight != pending.rect.height else { return }
        pending.rect = NormalizedRect(
            x: pending.rect.x,
            y: pending.rect.y,
            width: pending.rect.width,
            height: clampedHeight
        )
        pendingText = pending
    }

    mutating func resolvePendingText(style: AnnotationStyle) {
        guard let pendingText else { return }
        self.pendingText = nil
        // Trim ONLY to test for emptiness — the committed annotation stores the ORIGINAL,
        // untrimmed string (PLAN.md "Text Input").
        guard !pendingText.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let annotation = TextAnnotation(
            id: UUID(),
            bounds: pendingText.rect,
            text: pendingText.text,
            fontSize: style.fontSize,
            color: style.color
        )
        commit(.text(annotation))
    }

    mutating func cancelPendingText() {
        pendingText = nil
    }

    /// Clamps a resize-handle drag point so the resulting rect can never shrink below `minSize` on
    /// the axis/axes that `handle` controls, by capping the point relative to the rect's opposite
    /// (fixed) edge — the one shared clamp layer serving both `resizePendingText` and (indirectly,
    /// via the `minSize` floor in `growPendingText`) auto-grow.
    private static func clampResizePoint(
        _ point: NormalizedPoint,
        handle: AnnotationResizeHandle,
        in rect: NormalizedRect,
        minSize: NormalizedSize
    ) -> NormalizedPoint {
        let opposite = handle.oppositePoint(in: rect)
        var x = point.x
        var y = point.y
        switch handle {
        case .topLeading, .leading, .bottomLeading:
            x = min(x, opposite.x - minSize.width)
        case .topTrailing, .trailing, .bottomTrailing:
            x = max(x, opposite.x + minSize.width)
        case .top, .bottom:
            break
        }
        switch handle {
        case .topLeading, .top, .topTrailing:
            y = min(y, opposite.y - minSize.height)
        case .bottomLeading, .bottom, .bottomTrailing:
            y = max(y, opposite.y + minSize.height)
        case .leading, .trailing:
            break
        }
        return NormalizedPoint(x: x, y: y)
    }

    mutating func commitText(
        _ text: String,
        at anchor: NormalizedPoint,
        style: AnnotationStyle
    ) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let annotation = TextAnnotation(
            id: UUID(),
            bounds: NormalizedRect(
                x: anchor.x,
                y: anchor.y,
                width: 0.3,
                height: 0.12
            ),
            text: text,
            fontSize: style.fontSize,
            color: style.color
        )
        commit(.text(annotation))
    }

    mutating func select(_ itemID: UUID?) {
        guard itemID == nil || document.items.contains(where: { $0.id == itemID }) else {
            return
        }
        selectedItemID = itemID
        isCropSelected = false
    }

    mutating func selectCrop() {
        guard document.cropRect != nil else { return }
        selectedItemID = nil
        isCropSelected = true
    }

    mutating func select(_ itemID: UUID?, style: AnnotationStyle) {
        resolvePendingText(style: style)
        select(itemID)
    }

    mutating func moveSelection(dx: Double, dy: Double) {
        guard
            let selectedItemID,
            let item = document.items.first(where: { $0.id == selectedItemID })
        else { return }

        let bounds = item.bounds
        let clampedDX = max(-bounds.x, min(dx, 1 - bounds.x - bounds.width))
        let clampedDY = max(-bounds.y, min(dy, 1 - bounds.y - bounds.height))
        updateSelection { $0.translated(dx: clampedDX, dy: clampedDY) }
    }

    mutating func moveCrop(dx: Double, dy: Double) {
        guard let crop = document.cropRect else { return }
        let clampedDX = max(-crop.x, min(dx, 1 - crop.x - crop.width))
        let clampedDY = max(-crop.y, min(dy, 1 - crop.y - crop.height))
        let updated = crop.translated(dx: clampedDX, dy: clampedDY)
        guard updated != crop else { return }
        history.commit { $0.cropRect = updated }
    }

    mutating func resizeCrop(
        handle: AnnotationResizeHandle,
        to point: NormalizedPoint
    ) {
        guard let crop = document.cropRect else { return }
        let updated = handle.resized(crop, to: point)
        guard updated != crop else { return }
        history.commit { $0.cropRect = updated }
    }

    mutating func resizeSelection(to bounds: NormalizedRect) {
        updateSelection { $0.resized(to: bounds) }
    }

    mutating func resizeSelection(
        handle: AnnotationResizeHandle,
        to point: NormalizedPoint
    ) {
        updateSelection { $0.resized(handle: handle, to: point) }
    }

    mutating func deleteSelection() {
        if isCropSelected, document.cropRect != nil {
            history.commit { $0.cropRect = nil }
            isCropSelected = false
            return
        }
        guard let selectedItemID else { return }
        history.commit { document in
            document.items.removeAll { $0.id == selectedItemID }
        }
        self.selectedItemID = nil
    }

    mutating func undo() {
        history.undo()
        discardMissingSelection()
    }

    mutating func redo() {
        history.redo()
        discardMissingSelection()
    }

    private mutating func commit(_ item: AnnotationItem) {
        history.commit { $0.items.append(item) }
        selectedItemID = item.id
    }

    private mutating func updateSelection(
        _ mutation: (AnnotationItem) -> AnnotationItem
    ) {
        guard
            let selectedItemID,
            let index = document.items.firstIndex(where: { $0.id == selectedItemID })
        else { return }
        let item = document.items[index]
        let updatedItem = mutation(item)
        guard updatedItem != item else { return }
        history.commit { document in
            document.items[index] = updatedItem
        }
    }

    private mutating func discardMissingSelection() {
        if document.cropRect == nil {
            isCropSelected = false
        }
        guard let selectedItemID else { return }
        if !document.items.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = nil
        }
    }

    private static func rect(
        containing first: NormalizedPoint,
        and second: NormalizedPoint
    ) -> NormalizedRect {
        NormalizedRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(first.x - second.x),
            height: abs(first.y - second.y)
        )
    }
}

@MainActor
final class AnnotationEditorModel: ObservableObject {
    @Published private(set) var state: AnnotationEditorState
    @Published private(set) var renderRevision: UInt64 = 0
    @Published var style: AnnotationStyle = .standard
    @Published var zoom: CGFloat = 1 {
        didSet {
            let clamped = max(0.25, min(zoom, 4))
            if zoom != clamped {
                zoom = clamped
            }
        }
    }

    private(set) var capture: CapturedImage?
    let previewService = AnnotationPreviewService()

    var document: AnnotationDocument { state.document }
    var selectedItemID: UUID? { state.selectedItemID }
    var isCropSelected: Bool { state.isCropSelected }
    var hasSelection: Bool { selectedItemID != nil || isCropSelected }
    var selectedItem: AnnotationItem? {
        document.items.first { $0.id == selectedItemID }
    }
    var pendingText: PendingAnnotationText? { state.pendingText }
    var canUndo: Bool { state.canUndo }
    var canRedo: Bool { state.canRedo }

    init(capture: CapturedImage? = nil) {
        self.capture = capture
        state = AnnotationEditorState(
            document: AnnotationDocument(captureID: capture?.id ?? UUID())
        )
    }

    func load(_ capture: CapturedImage) {
        load(capture, document: AnnotationDocument(captureID: capture.id))
    }

    func load(_ capture: CapturedImage, document: AnnotationDocument) {
        guard document.captureID == capture.id else { return }
        self.capture = capture
        state = AnnotationEditorState(document: document)
        renderRevision &+= 1
        zoom = 1
    }

    func applyDrag(
        tool: AnnotationTool,
        from start: NormalizedPoint,
        to end: NormalizedPoint
    ) {
        mutate { $0.applyDrag(tool: tool, from: start, to: end, style: style) }
    }

    func commitText(_ text: String, at anchor: NormalizedPoint) {
        mutate { $0.commitText(text, at: anchor, style: style) }
    }

    func placeStep(at anchor: NormalizedPoint) {
        mutate { $0.placeStep(at: anchor) }
    }

    func placeEmoji(at anchor: NormalizedPoint) {
        mutate { $0.placeEmoji(at: anchor, style: style) }
    }

    func beginText(rect: NormalizedRect, minSize: NormalizedSize) {
        mutate { $0.beginText(rect: rect, minSize: minSize, style: style) }
    }

    func updatePendingText(_ text: String) {
        mutate { $0.updatePendingText(text) }
    }

    func resizePendingText(handle: AnnotationResizeHandle, to point: NormalizedPoint) {
        mutate { $0.resizePendingText(handle: handle, to: point) }
    }

    func growPendingText(toHeight height: Double) {
        mutate { $0.growPendingText(toHeight: height) }
    }

    func resolvePendingText() {
        mutate { $0.resolvePendingText(style: style) }
    }

    func cancelPendingText() {
        mutate { $0.cancelPendingText() }
    }

    func select(_ itemID: UUID?) {
        mutate { $0.select(itemID, style: style) }
    }

    func moveSelection(dx: Double, dy: Double) {
        mutate { $0.moveSelection(dx: dx, dy: dy) }
    }

    func selectCrop() {
        mutate { $0.selectCrop() }
    }

    func moveCrop(dx: Double, dy: Double) {
        mutate { $0.moveCrop(dx: dx, dy: dy) }
    }

    func resizeCrop(handle: AnnotationResizeHandle, to point: NormalizedPoint) {
        mutate { $0.resizeCrop(handle: handle, to: point) }
    }

    func resizeSelection(to bounds: NormalizedRect) {
        mutate { $0.resizeSelection(to: bounds) }
    }

    func resizeSelection(
        handle: AnnotationResizeHandle,
        to point: NormalizedPoint
    ) {
        mutate { $0.resizeSelection(handle: handle, to: point) }
    }

    func deleteSelection() {
        mutate { $0.deleteSelection() }
    }

    func undo() {
        mutate { $0.undo() }
    }

    func redo() {
        mutate { $0.redo() }
    }

    private func mutate(_ mutation: (inout AnnotationEditorState) -> Void) {
        var next = state
        mutation(&next)
        let documentChanged = next.document != state.document
        state = next
        if documentChanged {
            renderRevision &+= 1
        }
    }
}

struct AnnotationEditor: View {
    let capture: CapturedImage
    let selectedTool: AnnotationTool
    @ObservedObject var model: AnnotationEditorModel

    @State private var dragStart: NormalizedPoint?
    @State private var dragCurrent: NormalizedPoint?
    @State private var previewImage: CGImage?
    /// Bridges focus to/from the pending-text `NSTextView` (PLAN.md "Text Input") — replaces
    /// `@FocusState`, which has no way to drive an embedded `NSViewRepresentable`'s first-responder
    /// status; `PendingTextInputView`'s Coordinator reads/writes this directly.
    @State private var isTextFieldFocused = false
    /// Suspends the focus-loss resolve (`.onChange(of: isTextFieldFocused)`) for the duration of a
    /// pending-text handle drag, re-enabled once the drag commits the resized rect.
    @State private var isResizingPendingText = false

    private let coordinateSpaceName = "annotation-canvas"

    var body: some View {
        GeometryReader { proxy in
            let imageSize = CGSize(
                width: capture.pixelSize.width,
                height: capture.pixelSize.height
            )
            let transform = CanvasTransform(
                canvasSize: proxy.size,
                imageSize: imageSize,
                zoom: model.zoom
            )

            ZStack {
                // Full-canvas (letterbox included) click-outside-commits catcher for the pending
                // text box (PLAN.md "Text Input") — sits below everything else in the ZStack, so
                // the image/handles/items above it win hit-testing wherever they overlap; only
                // clicks that land nowhere else (most notably the letterboxed bars around the
                // image, which the Image view itself never covers) reach it. The `.onChange(of:
                // isTextFieldFocused)` below remains the backup path for focus-loss commits that
                // originate from AppKit rather than a SwiftUI tap here.
                if model.pendingText != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .onTapGesture {
                            model.resolvePendingText()
                            isTextFieldFocused = false
                        }
                }

                Image(decorative: previewImage ?? capture.image, scale: 1)
                    .resizable()
                    .frame(
                        width: transform.imageRect.width,
                        height: transform.imageRect.height
                    )
                    .position(
                        x: transform.imageRect.midX,
                        y: transform.imageRect.midY
                    )
                    .shadow(color: .black.opacity(0.22), radius: 24, y: 14)
                    .contentShape(Rectangle())
                    .gesture(canvasGesture(transform: transform))

                if let cropRect = model.document.cropRect {
                    cropOverlay(cropRect, transform: transform, canvasSize: proxy.size)
                    if selectedTool.allowsItemManipulation {
                        cropHitTarget(cropRect, transform: transform)
                    }
                }

                ForEach(model.document.items) { item in
                    itemLayer(item, transform: transform)
                }

                draftLayer(transform: transform)

                if selectedTool.allowsItemManipulation,
                   let selectedItem = model.selectedItem {
                    selectionLayer(for: selectedItem, transform: transform)
                }

                if selectedTool.allowsItemManipulation,
                   model.isCropSelected,
                   let crop = model.document.cropRect {
                    cropSelectionLayer(crop, transform: transform)
                }

                if let pendingText = model.pendingText {
                    inlineTextField(pendingText: pendingText, transform: transform)
                }

                keyboardActions
            }
            .coordinateSpace(name: coordinateSpaceName)
            .clipped()
            .task(id: "\(capture.id.uuidString):\(model.renderRevision)") {
                previewImage = capture.image
                do {
                    let maxPixelSize = max(
                        1,
                        Int(ceil(max(transform.imageRect.width, transform.imageRect.height) * 2))
                    )
                    let rendered = try await model.previewService.render(
                        capture: capture,
                        document: model.document,
                        maxPixelSize: maxPixelSize
                    )
                    try Task.checkCancellation()
                    previewImage = rendered
                } catch is CancellationError {
                    return
                } catch {
                    previewImage = capture.image
                }
            }
        }
        .onChange(of: selectedTool) {
            model.resolvePendingText()
            if !selectedTool.allowsItemManipulation {
                model.select(nil)
            }
            isTextFieldFocused = false
            dragStart = nil
            dragCurrent = nil
        }
        .onChange(of: isTextFieldFocused) {
            if !isTextFieldFocused, !isResizingPendingText {
                model.resolvePendingText()
            }
        }
    }

    private func canvasGesture(transform: CanvasTransform) -> some Gesture {
        DragGesture(minimumDistance: Self.isClickToPlace(selectedTool) ? 0 : 2, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                guard
                    let start = transform.normalizedPoint(from: value.startLocation)
                else {
                    dragStart = nil
                    dragCurrent = nil
                    return
                }
                dragStart = start
                dragCurrent = transform.clampedNormalizedPoint(from: value.location)
            }
            .onEnded { value in
                defer {
                    dragStart = nil
                    dragCurrent = nil
                }
                guard
                    let start = transform.normalizedPoint(from: value.startLocation)
                else { return }

                if selectedTool == .select {
                    model.select(nil)
                    return
                }

                if selectedTool == .text {
                    let width = transform.imageRect.width > 0
                        ? Double(Self.defaultPendingTextWidth / transform.imageRect.width) : 1
                    let height = transform.imageRect.height > 0
                        ? Double(Self.defaultPendingTextHeight / transform.imageRect.height) : 1
                    model.beginText(
                        rect: NormalizedRect(x: start.x, y: start.y, width: width, height: height),
                        minSize: minimumPendingTextSize
                    )
                    isTextFieldFocused = true
                    return
                }

                if selectedTool == .steps {
                    model.placeStep(at: start)
                    return
                }

                if selectedTool == .emoji {
                    model.placeEmoji(at: start)
                    return
                }

                let end = transform.clampedNormalizedPoint(from: value.location)
                guard hypot(end.x - start.x, end.y - start.y) >= 0.005 else { return }
                model.applyDrag(tool: selectedTool, from: start, to: end)
            }
    }

    /// Text/Steps/Emoji place on click rather than drag-to-create, matching the Text tool's
    /// existing `minimumDistance: 0` gesture.
    private static func isClickToPlace(_ tool: AnnotationTool) -> Bool {
        tool == .text || tool == .steps || tool == .emoji
    }

    /// Default pending-text box size in canvas points (mirrors the Selection Overlay field
    /// editor's own 220x30 default, `CaptureController.swift`'s `beginFieldEditor`) — converted to
    /// a normalized rect at the anchor through `CanvasTransform` so its on-screen footprint stays
    /// constant across zoom levels.
    private static let defaultPendingTextWidth: CGFloat = 220
    private static let defaultPendingTextHeight: CGFloat = 30

    /// Normalized floor for the pending-text box (PLAN.md "Text Input") — `min(60, w)/w x
    /// min(28, h)/h` against the image's own `PixelSize`, capped at 1.0, so the physical minimum
    /// (60x28 px) stays meaningful even for an image smaller than that in either dimension.
    private var minimumPendingTextSize: NormalizedSize {
        let width = Double(capture.pixelSize.width)
        let height = Double(capture.pixelSize.height)
        guard width > 0, height > 0 else { return NormalizedSize(width: 1, height: 1) }
        return NormalizedSize(
            width: min(1, min(60, width) / width),
            height: min(1, min(28, height) / height)
        )
    }

    @ViewBuilder
    private func itemLayer(
        _ item: AnnotationItem,
        transform: CanvasTransform
    ) -> some View {
        if selectedTool.allowsItemManipulation {
            itemHitTarget(item, transform: transform)
        }
    }

    private func itemHitTarget(
        _ item: AnnotationItem,
        transform: CanvasTransform
    ) -> some View {
        let rect = transform.canvasRect(from: item.bounds)
        return Color.clear
            .frame(width: max(22, rect.width), height: max(22, rect.height))
            .contentShape(Rectangle())
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture {
                model.select(item.id)
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(coordinateSpaceName))
                    .onEnded { value in
                        let start = transform.clampedNormalizedPoint(from: value.startLocation)
                        let end = transform.clampedNormalizedPoint(from: value.location)
                        model.select(item.id)
                        model.moveSelection(
                            dx: end.x - start.x,
                            dy: end.y - start.y
                        )
                    }
            )
    }

    @ViewBuilder
    private func draftLayer(transform: CanvasTransform) -> some View {
        if let dragStart, let dragCurrent {
            switch selectedTool {
            case .select:
                EmptyView()
            case .arrow:
                EditorArrowShape(
                    start: transform.canvasPoint(from: dragStart),
                    end: transform.canvasPoint(from: dragCurrent)
                )
                .stroke(
                    model.style.color.swiftUIColor.opacity(0.8),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
            case .highlight, .blur, .crop:
                let rect = transform.canvasRect(
                    from: NormalizedRect.containing(dragStart, dragCurrent)
                )
                RoundedRectangle(cornerRadius: 3)
                    .fill(model.style.color.swiftUIColor.opacity(0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(model.style.color.swiftUIColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            case .rect:
                let rect = transform.canvasRect(
                    from: NormalizedRect.containing(dragStart, dragCurrent)
                )
                Rectangle()
                    .stroke(model.style.color.swiftUIColor, lineWidth: max(1, CGFloat(model.style.strokeWidth)))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            case .ellipse:
                let rect = transform.canvasRect(
                    from: NormalizedRect.containing(dragStart, dragCurrent)
                )
                Ellipse()
                    .stroke(model.style.color.swiftUIColor, lineWidth: max(1, CGFloat(model.style.strokeWidth)))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            case .text, .steps, .emoji:
                EmptyView()
            }
        }
    }

    private func cropOverlay(
        _ crop: NormalizedRect,
        transform: CanvasTransform,
        canvasSize: CGSize
    ) -> some View {
        let cropRect = transform.canvasRect(from: crop)
        return ZStack {
            Path { path in
                path.addRect(transform.imageRect)
                path.addRect(cropRect)
            }
            .fill(.black.opacity(0.48), style: FillStyle(eoFill: true))

            Rectangle()
                .stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
    }

    private func cropHitTarget(
        _ crop: NormalizedRect,
        transform: CanvasTransform
    ) -> some View {
        let rect = transform.canvasRect(from: crop)
        return Color.clear
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture(perform: model.selectCrop)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(coordinateSpaceName))
                    .onEnded { value in
                        let start = transform.clampedNormalizedPoint(from: value.startLocation)
                        let end = transform.clampedNormalizedPoint(from: value.location)
                        model.selectCrop()
                        model.moveCrop(dx: end.x - start.x, dy: end.y - start.y)
                    }
            )
    }

    private func cropSelectionLayer(
        _ crop: NormalizedRect,
        transform: CanvasTransform
    ) -> some View {
        let rect = transform.canvasRect(from: crop)
        return ZStack {
            ForEach(AnnotationResizeHandle.allCases) { handle in
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: 10, height: 10)
                    .position(handle.point(in: rect))
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpaceName))
                            .onEnded { value in
                                model.selectCrop()
                                model.resizeCrop(
                                    handle: handle,
                                    to: transform.clampedNormalizedPoint(from: value.location)
                                )
                            }
                    )
            }
        }
    }

    private func selectionLayer(
        for item: AnnotationItem,
        transform: CanvasTransform
    ) -> some View {
        let rect = transform.canvasRect(from: item.bounds)
        return ZStack {
            Rectangle()
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            ForEach(AnnotationResizeHandle.cornerCases) { handle in
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: 10, height: 10)
                    .position(handle.point(in: rect))
                    .gesture(resizeGesture(handle: handle, item: item, transform: transform))
            }
        }
    }

    private func resizeGesture(
        handle: AnnotationResizeHandle,
        item: AnnotationItem,
        transform: CanvasTransform
    ) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpaceName))
            .onEnded { value in
                let point = transform.clampedNormalizedPoint(from: value.location)
                model.select(item.id)
                model.resizeSelection(handle: handle, to: point)
            }
    }

    /// The pending text box (PLAN.md "Text Input"): a multiline, colored `NSTextView` wrapped for
    /// SwiftUI, sized to `pendingText.rect` (which becomes `TextAnnotation.bounds` on commit), with
    /// its own corner resize handles. Enter inserts a newline; ⌘Return/Esc/click-outside commit —
    /// key routing lives in `PendingTextInputView.Coordinator` via `TextInputKeyDecision`.
    private func inlineTextField(
        pendingText: PendingAnnotationText,
        transform: CanvasTransform
    ) -> some View {
        let rect = transform.canvasRect(from: pendingText.rect)
        return ZStack {
            PendingTextInputView(
                text: Binding(
                    get: { model.pendingText?.text ?? "" },
                    set: model.updatePendingText
                ),
                textColor: model.style.color.nsColor,
                width: rect.width,
                isFocused: $isTextFieldFocused,
                onCommit: { model.resolvePendingText() },
                onHeightChange: { height in
                    guard transform.imageRect.height > 0 else { return }
                    model.growPendingText(toHeight: Double(height) / Double(transform.imageRect.height))
                }
            )
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 1))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)

            ForEach(AnnotationResizeHandle.cornerCases) { handle in
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: 10, height: 10)
                    .position(handle.point(in: rect))
                    .gesture(pendingTextResizeGesture(handle: handle, transform: transform))
            }
        }
    }

    private func pendingTextResizeGesture(
        handle: AnnotationResizeHandle,
        transform: CanvasTransform
    ) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { _ in isResizingPendingText = true }
            .onEnded { value in
                let point = transform.clampedNormalizedPoint(from: value.location)
                model.resizePendingText(handle: handle, to: point)
                isResizingPendingText = false
            }
    }

    private var keyboardActions: some View {
        HStack {
            Button("Undo", action: model.undo)
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo", action: model.redo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Delete", action: model.deleteSelection)
                .keyboardShortcut(.delete, modifiers: [])
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
    }

}

/// A multiline, colored `NSTextView` wrapped for SwiftUI — the post-capture editor's pending-text
/// input surface (PLAN.md "Text Input"). No scroll-view chrome; sized entirely by the SwiftUI
/// `.frame` the caller applies around it. Key routing goes through the shared
/// `TextInputKeyDecision` seam via `Coordinator.textView(_:doCommandBy:)`.
private struct PendingTextInputView: NSViewRepresentable {
    @Binding var text: String
    var textColor: NSColor
    var width: CGFloat
    var isFocused: Binding<Bool>
    var onCommit: () -> Void
    var onHeightChange: (CGFloat) -> Void
    /// Injected so `Coordinator.textView(_:doCommandBy:)` stays deterministically unit-testable —
    /// `NSApp.currentEvent` cannot be set from a test. Defaults to the real current event's ⌘ flag.
    var commandModifierProvider: () -> Bool = {
        NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
    }

    /// Exact wrap configuration (PLAN.md "Text Input"): the container never grows horizontally
    /// (`isHorizontallyResizable = false`, `widthTracksTextView = true`) and its height stays
    /// unbounded (`heightTracksTextView = false`, `.greatestFiniteMagnitude`) so `usedRect` always
    /// measures the full wrapped extent regardless of the view's own current on-screen frame.
    static func configuredTextView(width: CGFloat) -> NSTextView {
        let textView = FocusBridgingTextView(frame: .zero)
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainerInset = CGSize(width: 4, height: 4)
        textView.textContainer?.containerSize = CGSize(
            width: max(1, width - Self.horizontalInset),
            height: .greatestFiniteMagnitude
        )
        textView.font = .systemFont(ofSize: 15)
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        return textView
    }

    static let horizontalInset: CGFloat = 16

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = Self.configuredTextView(width: width)
        textView.delegate = context.coordinator
        textView.string = text
        textView.textColor = textColor
        context.coordinator.textView = textView
        (textView as? FocusBridgingTextView)?.onWindowAvailable = { [weak coordinator = context.coordinator] in
            coordinator?.syncFocus()
        }
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        context.coordinator.parent = self
        if nsView.string != text {
            nsView.string = text
        }
        if nsView.textColor != textColor {
            nsView.textColor = textColor
        }
        let targetWidth = max(1, width - Self.horizontalInset)
        if nsView.textContainer?.containerSize.width != targetWidth {
            nsView.textContainer?.containerSize = CGSize(
                width: targetWidth,
                height: .greatestFiniteMagnitude
            )
        }
        context.coordinator.syncFocus()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PendingTextInputView
        weak var textView: NSTextView?

        init(parent: PendingTextInputView) {
            self.parent = parent
        }

        /// Activation guarded on having a window (PLAN.md "Text Input" focus bridge) — `beginText`
        /// can fire before this representable is actually mounted, so both `updateNSView` and
        /// `FocusBridgingTextView.viewDidMoveToWindow` call this; the main-queue hop lets AppKit
        /// finish installing the view in its window hierarchy first.
        func syncFocus() {
            guard parent.isFocused.wrappedValue,
                  let textView,
                  let window = textView.window,
                  window.firstResponder !== textView
            else { return }
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch TextInputKeyDecision.action(
                for: commandSelector,
                commandModifier: parent.commandModifierProvider()
            ) {
            case .insertNewline:
                // AppKit's default handling inserts exactly one newline; returning `true` here
                // (after also inserting manually) would double it.
                return false
            case .commit:
                parent.onCommit()
                // Reverse focus path (PLAN.md "Text Input"): commit resigns first responder and
                // returns key focus to the canvas instead of leaving it on a now-dismissed view.
                textView.window?.makeFirstResponder(nil)
                return true
            case .pass:
                return false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: container)
            parent.onHeightChange(layoutManager.usedRect(for: container).height)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = false
        }
    }
}

/// Reports once it has a window so `PendingTextInputView.Coordinator` can attempt first-responder
/// activation even when `beginText` fires before this view is actually mounted — SwiftUI can
/// construct/update an `NSViewRepresentable` before its host window exists (PLAN.md "Text Input").
private final class FocusBridgingTextView: NSTextView {
    var onWindowAvailable: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onWindowAvailable?()
        }
    }
}

private struct EditorArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 14
        let spread = CGFloat.pi / 6
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        path.move(to: end)
        path.addLine(to: CGPoint(
            x: end.x - arrowLength * cos(angle - spread),
            y: end.y - arrowLength * sin(angle - spread)
        ))
        path.move(to: end)
        path.addLine(to: CGPoint(
            x: end.x - arrowLength * cos(angle + spread),
            y: end.y - arrowLength * sin(angle + spread)
        ))
        return path
    }
}

extension AnnotationItem {
    var bounds: NormalizedRect {
        switch self {
        case .arrow(let annotation):
            return NormalizedRect(
                x: min(annotation.start.x, annotation.end.x),
                y: min(annotation.start.y, annotation.end.y),
                width: abs(annotation.start.x - annotation.end.x),
                height: abs(annotation.start.y - annotation.end.y)
            )
        case .text(let annotation):
            return annotation.bounds
        case .highlight(let annotation), .blur(let annotation):
            return annotation.rect
        case .shape(let annotation):
            return annotation.rect
        case .step(let annotation):
            let radius = StepAnnotation.diameterFraction / 2
            return NormalizedRect(
                x: annotation.center.x - radius,
                y: annotation.center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        }
    }

    func translated(dx: Double, dy: Double) -> AnnotationItem {
        let bounds = bounds
        let clampedDX = max(-bounds.x, min(dx, 1 - bounds.x - bounds.width))
        let clampedDY = max(-bounds.y, min(dy, 1 - bounds.y - bounds.height))
        switch self {
        case .arrow(var annotation):
            annotation.start = NormalizedPoint(
                x: annotation.start.x + clampedDX,
                y: annotation.start.y + clampedDY
            )
            annotation.end = NormalizedPoint(
                x: annotation.end.x + clampedDX,
                y: annotation.end.y + clampedDY
            )
            return .arrow(annotation)
        case .text(var annotation):
            annotation.bounds = annotation.bounds.translated(dx: clampedDX, dy: clampedDY)
            return .text(annotation)
        case .highlight(var annotation):
            annotation.rect = annotation.rect.translated(dx: clampedDX, dy: clampedDY)
            return .highlight(annotation)
        case .blur(var annotation):
            annotation.rect = annotation.rect.translated(dx: clampedDX, dy: clampedDY)
            return .blur(annotation)
        case .shape(var annotation):
            annotation.rect = annotation.rect.translated(dx: clampedDX, dy: clampedDY)
            return .shape(annotation)
        case .step(var annotation):
            annotation.center = NormalizedPoint(
                x: annotation.center.x + clampedDX,
                y: annotation.center.y + clampedDY
            )
            return .step(annotation)
        }
    }

    func resized(to newBounds: NormalizedRect) -> AnnotationItem {
        switch self {
        case .arrow(var annotation):
            let oldBounds = bounds
            annotation.start = Self.map(
                annotation.start,
                from: oldBounds,
                to: newBounds
            )
            annotation.end = Self.map(
                annotation.end,
                from: oldBounds,
                to: newBounds
            )
            return .arrow(annotation)
        case .text(var annotation):
            annotation.bounds = newBounds
            return .text(annotation)
        case .highlight(var annotation):
            annotation.rect = newBounds
            return .highlight(annotation)
        case .blur(var annotation):
            annotation.rect = newBounds
            return .blur(annotation)
        case .shape(var annotation):
            annotation.rect = newBounds
            return .shape(annotation)
        case .step(var annotation):
            // Fixed-size badge: only the center moves, per newBounds' midpoint.
            annotation.center = NormalizedPoint(
                x: newBounds.x + newBounds.width / 2,
                y: newBounds.y + newBounds.height / 2
            )
            return .step(annotation)
        }
    }

    func resized(
        handle: AnnotationResizeHandle,
        to point: NormalizedPoint
    ) -> AnnotationItem {
        switch self {
        case .arrow(var annotation):
            let handlePoint = handle.point(in: bounds)
            let startDistance = Self.distance(annotation.start, handlePoint)
            let endDistance = Self.distance(annotation.end, handlePoint)
            if startDistance <= endDistance {
                annotation.start = point
            } else {
                annotation.end = point
            }
            return .arrow(annotation)
        case .text, .highlight, .blur, .shape:
            return resized(to: handle.resized(bounds, to: point))
        case .step:
            // Fixed-size badge: no resize handles (move only).
            return self
        }
    }

    private static func map(
        _ point: NormalizedPoint,
        from source: NormalizedRect,
        to destination: NormalizedRect
    ) -> NormalizedPoint {
        let xRatio = source.width > 0 ? (point.x - source.x) / source.width : 0.5
        let yRatio = source.height > 0 ? (point.y - source.y) / source.height : 0.5
        return NormalizedPoint(
            x: destination.x + xRatio * destination.width,
            y: destination.y + yRatio * destination.height
        )
    }

    private static func distance(
        _ first: NormalizedPoint,
        _ second: NormalizedPoint
    ) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }
}

private extension NormalizedRect {
    static func containing(
        _ first: NormalizedPoint,
        _ second: NormalizedPoint
    ) -> NormalizedRect {
        NormalizedRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(first.x - second.x),
            height: abs(first.y - second.y)
        )
    }

    func translated(dx: Double, dy: Double) -> NormalizedRect {
        NormalizedRect(
            x: x + dx,
            y: y + dy,
            width: width,
            height: height
        )
    }
}

private extension RGBAColor {
    var swiftUIColor: Color {
        Color(
            red: red,
            green: green,
            blue: blue,
            opacity: alpha
        )
    }
}
