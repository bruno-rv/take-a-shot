import CoreGraphics
import Carbon

enum CaptureGeometry {
    static func sourceRect(selection: CGRect, display: DisplayGeometry) -> CGRect {
        CGRect(
            x: selection.minX - display.frame.minX,
            y: display.frame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        ).integral
    }

    static func pixelSize(rect: CGRect, scale: CGFloat) -> PixelSize {
        PixelSize(
            width: Int((rect.width * scale).rounded()),
            height: Int((rect.height * scale).rounded())
        )
    }
}

/// One of the 8 resize handles drawn around a selection rect (corners + edge midpoints).
enum SelectionHandle: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right

    /// Returns the handle whose point falls within `tolerance` of `point`, if any.
    /// Corners take priority over edge midpoints when zones overlap on tiny rects.
    static func hitTest(_ point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> SelectionHandle? {
        allCases.first { handle in
            let handlePoint = handle.point(in: rect)
            return abs(point.x - handlePoint.x) <= tolerance && abs(point.y - handlePoint.y) <= tolerance
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        }
    }

    /// Resizes `rect` by moving this handle to `location`, normalizing min/max so
    /// dragging past the opposite edge flips the rect instead of producing negative size.
    func resized(_ rect: CGRect, to location: CGPoint) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch self {
        case .topLeft, .left, .bottomLeft:
            minX = location.x
        case .topRight, .right, .bottomRight:
            maxX = location.x
        case .top, .bottom:
            break
        }

        switch self {
        case .topLeft, .top, .topRight:
            maxY = location.y
        case .bottomLeft, .bottom, .bottomRight:
            minY = location.y
        case .left, .right:
            break
        }

        return CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
    }
}

enum SelectionOverlayInput: Equatable {
    case escapeKey
    case returnKey
    case doubleClick

    init?(keyCode: UInt16) {
        switch keyCode {
        case UInt16(kVK_Escape): self = .escapeKey
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter): self = .returnKey
        default: return nil
        }
    }
}
