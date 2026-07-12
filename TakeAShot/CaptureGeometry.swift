import CoreGraphics

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
