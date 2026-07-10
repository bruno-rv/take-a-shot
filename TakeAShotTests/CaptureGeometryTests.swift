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
}
