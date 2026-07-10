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

    static let standard = AnnotationStyle(
        color: .red,
        strokeWidth: 4,
        opacity: 0.4,
        blurRadius: 10,
        fontSize: 22
    )
}

struct PendingAnnotationText: Equatable, Sendable {
    let anchor: NormalizedPoint
    var text: String
}

enum AnnotationResizeHandle: CaseIterable, Identifiable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: Self { self }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeading:
            CGPoint(x: rect.minX, y: rect.minY)
        case .topTrailing:
            CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeading:
            CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomTrailing:
            CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    func point(in rect: NormalizedRect) -> NormalizedPoint {
        switch self {
        case .topLeading:
            NormalizedPoint(x: rect.x, y: rect.y)
        case .topTrailing:
            NormalizedPoint(x: rect.x + rect.width, y: rect.y)
        case .bottomLeading:
            NormalizedPoint(x: rect.x, y: rect.y + rect.height)
        case .bottomTrailing:
            NormalizedPoint(x: rect.x + rect.width, y: rect.y + rect.height)
        }
    }

    func oppositePoint(in rect: NormalizedRect) -> NormalizedPoint {
        switch self {
        case .topLeading:
            NormalizedPoint(x: rect.x + rect.width, y: rect.y + rect.height)
        case .topTrailing:
            NormalizedPoint(x: rect.x, y: rect.y + rect.height)
        case .bottomLeading:
            NormalizedPoint(x: rect.x + rect.width, y: rect.y)
        case .bottomTrailing:
            NormalizedPoint(x: rect.x, y: rect.y)
        }
    }
}

struct AnnotationEditorState: Sendable {
    private var history: AnnotationHistory
    private(set) var selectedItemID: UUID?
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
        case .text:
            break
        }
    }

    mutating func beginText(
        at anchor: NormalizedPoint,
        style: AnnotationStyle
    ) {
        resolvePendingText(style: style)
        pendingText = PendingAnnotationText(anchor: anchor, text: "")
    }

    mutating func updatePendingText(_ text: String) {
        pendingText?.text = text
    }

    mutating func resolvePendingText(style: AnnotationStyle) {
        guard let pendingText else { return }
        self.pendingText = nil
        commitText(pendingText.text, at: pendingText.anchor, style: style)
    }

    mutating func cancelPendingText() {
        pendingText = nil
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

    var document: AnnotationDocument { state.document }
    var selectedItemID: UUID? { state.selectedItemID }
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

    func beginText(at anchor: NormalizedPoint) {
        mutate { $0.beginText(at: anchor, style: style) }
    }

    func updatePendingText(_ text: String) {
        mutate { $0.updatePendingText(text) }
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
        state = next
    }
}

struct AnnotationEditor: View {
    let capture: CapturedImage
    let selectedTool: AnnotationTool
    @ObservedObject var model: AnnotationEditorModel

    @State private var dragStart: NormalizedPoint?
    @State private var dragCurrent: NormalizedPoint?
    @FocusState private var textFieldIsFocused: Bool

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
                Image(decorative: capture.image, scale: 1)
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
                }

                ForEach(model.document.items) { item in
                    itemLayer(item, transform: transform)
                }

                draftLayer(transform: transform)

                if selectedTool.allowsItemManipulation,
                   let selectedItem = model.selectedItem {
                    selectionLayer(for: selectedItem, transform: transform)
                }

                if let pendingText = model.pendingText {
                    inlineTextField(
                        at: transform.canvasPoint(from: pendingText.anchor),
                        canvasSize: proxy.size
                    )
                }

                keyboardActions
            }
            .coordinateSpace(name: coordinateSpaceName)
            .clipped()
        }
        .onChange(of: selectedTool) {
            model.resolvePendingText()
            if !selectedTool.allowsItemManipulation {
                model.select(nil)
            }
            textFieldIsFocused = false
            dragStart = nil
            dragCurrent = nil
        }
    }

    private func canvasGesture(transform: CanvasTransform) -> some Gesture {
        DragGesture(minimumDistance: selectedTool == .text ? 0 : 2, coordinateSpace: .named(coordinateSpaceName))
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
                    model.beginText(at: start)
                    DispatchQueue.main.async {
                        textFieldIsFocused = true
                    }
                    return
                }

                let end = transform.clampedNormalizedPoint(from: value.location)
                guard hypot(end.x - start.x, end.y - start.y) >= 0.005 else { return }
                model.applyDrag(tool: selectedTool, from: start, to: end)
            }
    }

    @ViewBuilder
    private func itemLayer(
        _ item: AnnotationItem,
        transform: CanvasTransform
    ) -> some View {
        switch item {
        case .arrow(let annotation):
            EditorArrowShape(
                start: transform.canvasPoint(from: annotation.start),
                end: transform.canvasPoint(from: annotation.end)
            )
            .stroke(
                annotation.color.swiftUIColor,
                style: StrokeStyle(
                    lineWidth: screenStrokeWidth(annotation.strokeWidth, transform: transform),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .allowsHitTesting(false)
        case .text(let annotation):
            let rect = transform.canvasRect(from: annotation.bounds)
            Text(annotation.text)
                .font(.system(size: screenFontSize(annotation.fontSize, transform: transform), weight: .semibold))
                .foregroundStyle(annotation.color.swiftUIColor)
                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        case .highlight(let annotation):
            let rect = transform.canvasRect(from: annotation.rect)
            Rectangle()
                .fill(annotation.color.swiftUIColor.opacity(annotation.amount))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        case .blur(let annotation):
            let rect = transform.canvasRect(from: annotation.rect)
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Image(systemName: "drop.degreesign")
                        .foregroundStyle(.white.opacity(0.68))
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }

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
            case .text:
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

            ForEach(AnnotationResizeHandle.allCases) { handle in
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

    private func inlineTextField(at anchor: CGPoint, canvasSize: CGSize) -> some View {
        TextField(
            "Add text",
            text: Binding(
                get: { model.pendingText?.text ?? "" },
                set: model.updatePendingText
            )
        )
            .textFieldStyle(.roundedBorder)
            .focused($textFieldIsFocused)
            .onSubmit {
                model.resolvePendingText()
                textFieldIsFocused = false
            }
            .onExitCommand {
                model.cancelPendingText()
                textFieldIsFocused = false
            }
            .onChange(of: textFieldIsFocused) {
                if !textFieldIsFocused {
                    model.resolvePendingText()
                }
            }
            .frame(width: 220)
            .position(
                x: min(max(116, anchor.x + 110), max(116, canvasSize.width - 116)),
                y: min(max(18, anchor.y + 18), max(18, canvasSize.height - 18))
            )
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

    private func screenStrokeWidth(
        _ pixelWidth: Double,
        transform: CanvasTransform
    ) -> CGFloat {
        max(2, CGFloat(pixelWidth) * transform.imageRect.width / CGFloat(capture.pixelSize.width))
    }

    private func screenFontSize(
        _ pixelSize: Double,
        transform: CanvasTransform
    ) -> CGFloat {
        max(10, CGFloat(pixelSize) * transform.imageRect.width / CGFloat(capture.pixelSize.width))
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
        }
    }

    func translated(dx: Double, dy: Double) -> AnnotationItem {
        switch self {
        case .arrow(var annotation):
            annotation.start = NormalizedPoint(
                x: annotation.start.x + dx,
                y: annotation.start.y + dy
            )
            annotation.end = NormalizedPoint(
                x: annotation.end.x + dx,
                y: annotation.end.y + dy
            )
            return .arrow(annotation)
        case .text(var annotation):
            annotation.bounds = annotation.bounds.translated(dx: dx, dy: dy)
            return .text(annotation)
        case .highlight(var annotation):
            annotation.rect = annotation.rect.translated(dx: dx, dy: dy)
            return .highlight(annotation)
        case .blur(var annotation):
            annotation.rect = annotation.rect.translated(dx: dx, dy: dy)
            return .blur(annotation)
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
        case .text, .highlight, .blur:
            return resized(
                to: NormalizedRect.containing(
                    point,
                    handle.oppositePoint(in: bounds)
                )
            )
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
