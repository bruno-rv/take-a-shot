import XCTest
@testable import TakeAShot

final class CaptureGeometryTests: XCTestCase {
    func testHarnessLoadsApplicationModule() {
        XCTAssertEqual(CaptureMode.area.rawValue, "Area")
    }

    func testSourceRectConvertsAppKitBottomLeftToScreenCaptureTopLeft() {
        let display = DisplayGeometry(
            id: 7,
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            scale: 2
        )
        let selection = CGRect(x: 1540, y: 680, width: 300, height: 200)
        XCTAssertEqual(
            CaptureGeometry.sourceRect(selection: selection, display: display),
            CGRect(x: 100, y: 200, width: 300, height: 200)
        )
    }

    func testPixelSizeUsesCapturedDisplayScale() {
        XCTAssertEqual(
            CaptureGeometry.pixelSize(rect: CGRect(x: 0, y: 0, width: 300, height: 200), scale: 2),
            PixelSize(width: 600, height: 400)
        )
    }

    func testSelectionHandleHitTestFindsHandleWithinTolerance() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
        XCTAssertEqual(
            SelectionHandle.hitTest(CGPoint(x: 100, y: 100), in: rect, tolerance: 14),
            .bottomLeft
        )
        XCTAssertEqual(
            SelectionHandle.hitTest(CGPoint(x: 300, y: 175), in: rect, tolerance: 14),
            .right
        )
        XCTAssertNil(SelectionHandle.hitTest(CGPoint(x: 200, y: 175), in: rect, tolerance: 14))
    }

    func testSelectionHandleResizeNormalizesRectWhenDraggedPastOppositeEdge() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)

        // Dragging the top-right corner further out grows the rect from that corner.
        XCTAssertEqual(
            SelectionHandle.topRight.resized(rect, to: CGPoint(x: 400, y: 300)),
            CGRect(x: 100, y: 100, width: 300, height: 200)
        )

        // Dragging the top-right corner's x past the left edge flips the rect.
        XCTAssertEqual(
            SelectionHandle.topRight.resized(rect, to: CGPoint(x: 50, y: 300)),
            CGRect(x: 50, y: 100, width: 50, height: 200)
        )

        // Edge midpoint handles only move one axis.
        XCTAssertEqual(
            SelectionHandle.right.resized(rect, to: CGPoint(x: 350, y: 999)),
            CGRect(x: 100, y: 100, width: 250, height: 150)
        )
    }
}
