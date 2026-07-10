import XCTest
@testable import TakeAShot

final class CaptureGeometryTests: XCTestCase {
    func testHarnessLoadsApplicationModule() {
        XCTAssertEqual(CaptureMode.area.rawValue, "Area")
    }
}
