import XCTest
@testable import TakeAShot

final class PostCapturePanelTests: XCTestCase {
    func testPlacementPrefersBelowAndClampsToVisibleFrame() {
        let frame = PostCapturePanelPlacement.frame(
            captureRect: CGRect(x: 900, y: 700, width: 180, height: 100),
            panelSize: CGSize(width: 260, height: 64),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            spacing: 8
        )

        XCTAssertEqual(frame.maxX, 1_000)
        XCTAssertEqual(frame.maxY, 692)
    }

    func testPlacementFallsBackAboveWhenBelowDoesNotFit() {
        let frame = PostCapturePanelPlacement.frame(
            captureRect: CGRect(x: 400, y: 20, width: 200, height: 100),
            panelSize: CGSize(width: 260, height: 64),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            spacing: 8
        )

        XCTAssertEqual(frame.midX, 500)
        XCTAssertEqual(frame.minY, 128)
    }

    func testPlacementClampsToVisibleFrameMinimumX() {
        let frame = PostCapturePanelPlacement.frame(
            captureRect: CGRect(x: -40, y: 300, width: 100, height: 100),
            panelSize: CGSize(width: 260, height: 64),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        XCTAssertEqual(frame.minX, 0)
    }

    func testPlacementClampsToVisibleFrameMaximumY() {
        let frame = PostCapturePanelPlacement.frame(
            captureRect: CGRect(x: 400, y: 900, width: 200, height: 40),
            panelSize: CGSize(width: 260, height: 64),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        XCTAssertEqual(frame.maxY, 800)
    }

    @MainActor
    func testFailedActionKeepsPanelAndAllowsRetry() async {
        var attempts = 0
        let dispatcher = PostCaptureActionDispatcher(
            dismiss: { XCTFail("failure must not dismiss") }
        )
        await dispatcher.perform {
            attempts += 1
            return false
        }
        await dispatcher.perform {
            attempts += 1
            return false
        }
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testSuccessfulActionDismissesExactlyOnce() async {
        var dismissals = 0
        let dispatcher = PostCaptureActionDispatcher {
            dismissals += 1
        }
        await dispatcher.perform { true }
        await dispatcher.perform { true }
        XCTAssertEqual(dismissals, 1)
    }

    @MainActor
    func testConcurrentActionIsIgnoredWhileFirstActionIsRunning() async {
        let gate = PostCaptureActionGate()
        var attempts = 0
        var dismissals = 0
        let dispatcher = PostCaptureActionDispatcher {
            dismissals += 1
        }

        let first = Task { @MainActor in
            await dispatcher.perform {
                attempts += 1
                await gate.wait()
                return true
            }
        }
        await gate.waitUntilSuspended()

        await dispatcher.perform {
            attempts += 1
            return true
        }
        gate.resume()
        await first.value

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(dismissals, 1)
    }
}

@MainActor
private final class PostCaptureActionGate {
    private var actionContinuation: CheckedContinuation<Void, Never>?
    private var waiterContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            actionContinuation = continuation
            waiterContinuation?.resume()
            waiterContinuation = nil
        }
    }

    func waitUntilSuspended() async {
        if actionContinuation != nil { return }
        await withCheckedContinuation { continuation in
            waiterContinuation = continuation
        }
    }

    func resume() {
        actionContinuation?.resume()
        actionContinuation = nil
    }
}
