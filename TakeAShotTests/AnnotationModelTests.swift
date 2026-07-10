import Foundation
import XCTest
@testable import TakeAShot

final class AnnotationModelTests: XCTestCase {
    func testUndoAndRedoRestoreWholeDocument() {
        let initial = AnnotationDocument(captureID: UUID())
        var history = AnnotationHistory(initial: initial, limit: 50)
        let arrow = AnnotationItem.arrow(.init(
            id: UUID(),
            start: .init(x: 0.1, y: 0.2),
            end: .init(x: 0.8, y: 0.7),
            color: .red,
            strokeWidth: 4
        ))

        history.commit { $0.items.append(arrow) }
        XCTAssertEqual(history.document.items, [arrow])

        history.undo()
        XCTAssertTrue(history.document.items.isEmpty)

        history.redo()
        XCTAssertEqual(history.document.items, [arrow])
    }

    func testDocumentCodableRoundTripPreservesAnnotationsAndCrop() throws {
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .arrow(.init(
                    id: UUID(),
                    start: .init(x: 0.1, y: 0.2),
                    end: .init(x: 0.8, y: 0.7),
                    color: .red,
                    strokeWidth: 4
                )),
                .text(.init(
                    id: UUID(),
                    bounds: .init(x: 0.2, y: 0.3, width: 0.4, height: 0.2),
                    text: "Review this",
                    fontSize: 18,
                    color: .red
                )),
                .highlight(.init(
                    id: UUID(),
                    rect: .init(x: 0.1, y: 0.5, width: 0.6, height: 0.25),
                    color: .red,
                    amount: 0.5
                )),
                .blur(.init(
                    id: UUID(),
                    rect: .init(x: 0.6, y: 0.1, width: 0.3, height: 0.3),
                    color: .red,
                    amount: 8
                )),
            ],
            cropRect: .init(x: 0.05, y: 0.1, width: 0.9, height: 0.8)
        )

        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: encoded)

        XCTAssertEqual(decoded, document)
    }

    func testNormalizedGeometryClampsToImageBounds() {
        XCTAssertEqual(NormalizedPoint(x: -0.25, y: 1.4), NormalizedPoint(x: 0, y: 1))
        XCTAssertEqual(
            NormalizedRect(x: 0.75, y: -0.2, width: 0.5, height: 1.5),
            NormalizedRect(x: 0.75, y: 0, width: 0.25, height: 1)
        )
        XCTAssertEqual(
            NormalizedRect(x: 0.2, y: 0.3, width: -1, height: -1),
            NormalizedRect(x: 0.2, y: 0.3, width: 0, height: 0)
        )
    }
}
