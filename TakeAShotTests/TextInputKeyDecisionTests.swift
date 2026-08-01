import AppKit
import XCTest
@testable import TakeAShot

/// Pure tests for the key-routing seam shared by both text-input surfaces (PLAN.md "Text Input").
final class TextInputKeyDecisionTests: XCTestCase {
    func testInsertNewlineWithoutCommandModifierInsertsNewline() {
        let decision = TextInputKeyDecision.action(
            for: #selector(NSResponder.insertNewline(_:)),
            commandModifier: false
        )
        XCTAssertEqual(decision, .insertNewline)
    }

    func testInsertNewlineWithCommandModifierCommits() {
        let decision = TextInputKeyDecision.action(
            for: #selector(NSResponder.insertNewline(_:)),
            commandModifier: true
        )
        XCTAssertEqual(decision, .commit)
    }

    func testCancelOperationCommitsRegardlessOfCommandModifier() {
        XCTAssertEqual(
            TextInputKeyDecision.action(
                for: #selector(NSResponder.cancelOperation(_:)),
                commandModifier: false
            ),
            .commit
        )
        XCTAssertEqual(
            TextInputKeyDecision.action(
                for: #selector(NSResponder.cancelOperation(_:)),
                commandModifier: true
            ),
            .commit
        )
    }

    func testOtherSelectorPasses() {
        let decision = TextInputKeyDecision.action(
            for: #selector(NSResponder.deleteBackward(_:)),
            commandModifier: false
        )
        XCTAssertEqual(decision, .pass)
    }
}
