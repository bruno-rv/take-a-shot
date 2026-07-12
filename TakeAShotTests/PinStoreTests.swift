import CoreGraphics
import Foundation
import XCTest
@testable import TakeAShot

final class PinStoreTests: XCTestCase {
    func testRoundTripPreservesEveryPersistedField() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PinStore(rootURL: root)
        let pin = PinnedReference.fixture(
            captureID: UUID(),
            frame: .init(
                displayID: "display-a",
                panelFrame: CGRect(x: 20, y: 30, width: 400, height: 240),
                previousVisibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)
            ),
            zoom: 2,
            pan: .init(x: 0.25, y: 0.75),
            opacity: 0.65,
            isClickThrough: true,
            collapsedEdge: .right,
            restoresAfterRelaunch: true
        )

        try await store.replaceAll([pin])

        let reloaded = try await PinStore(rootURL: root).load()
        XCTAssertEqual(reloaded, [pin])
    }

    func testMalformedRecordDoesNotHideValidRecords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = PinnedReference.fixture(captureID: UUID())
        let validData = try JSONEncoder().encode(valid)
        let validJSON = try XCTUnwrap(String(data: validData, encoding: .utf8))
        let source = """
        {"schemaVersion":1,"pins":[{"broken":],\(validJSON)]}
        """
        try Data(source.utf8).write(to: root.appendingPathComponent("pins.json"))

        let store = PinStore(rootURL: root)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, [valid])
        let issues = await store.loadIssues()
        XCTAssertEqual(issues.count, 1)
    }

    func testDuplicateCaptureKeepsNewestValidRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let captureID = UUID()
        let older = PinnedReference.fixture(
            captureID: captureID,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = PinnedReference.fixture(
            captureID: captureID,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let store = PinStore(rootURL: root)

        try await store.replaceAll([older, newer])

        let loaded = try await store.load()
        XCTAssertEqual(loaded, [newer])
    }

    func testDebouncedUpdatesPublishOnlyFinalLayout() async throws {
        let files = RecordingPinFileOperations()
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PinStore(rootURL: root, fileOperations: files)
        var pin = PinnedReference.fixture(captureID: UUID())

        pin.opacity = 0.4
        await store.scheduleUpsert(pin)
        pin.opacity = 0.6
        await store.scheduleUpsert(pin)
        pin.opacity = 0.8
        await store.scheduleUpsert(pin)
        try await store.flush()

        XCTAssertEqual(files.atomicReplacementCount, 1)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.first?.opacity, 0.8)
    }

    func testPublishFailurePreservesPriorDocumentAndRemovesTemporaryFile() async throws {
        let files = FailingReplacementPinFileOperations()
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PinStore(rootURL: root, fileOperations: files)
        let original = PinnedReference.fixture(captureID: UUID())
        try await store.replaceAll([original])
        files.failNextReplacement = true

        await XCTAssertThrowsErrorAsync {
            try await store.replaceAll([.fixture(captureID: UUID())])
        }

        let persisted = try await PinStore(rootURL: root).load()
        XCTAssertEqual(persisted, [original])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("pins.json.tmp").path
        ))
    }
}

extension PinnedReference {
    static func fixture(
        id: UUID = UUID(),
        captureID: UUID,
        frame: PersistedPinFrame = .init(
            displayID: "display-a",
            panelFrame: CGRect(x: 10, y: 20, width: 320, height: 180),
            previousVisibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        ),
        zoom: Double = 1,
        pan: NormalizedPoint = .init(x: 0.5, y: 0.5),
        opacity: Double = 1,
        isClickThrough: Bool = false,
        collapsedEdge: PinEdge? = nil,
        restoresAfterRelaunch: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1),
        updatedAt: Date = Date(timeIntervalSince1970: 2)
    ) -> PinnedReference {
        PinnedReference(
            id: id,
            captureID: captureID,
            frame: frame,
            zoom: zoom,
            normalizedPan: pan,
            opacity: opacity,
            isClickThrough: isClickThrough,
            collapsedEdge: collapsedEdge,
            restoresAfterRelaunch: restoresAfterRelaunch,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

class RecordingPinFileOperations: PinFileOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var replacementCount = 0

    var atomicReplacementCount: Int {
        lock.withLock { replacementCount }
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func data(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    func replaceItem(at destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        lock.withLock { replacementCount += 1 }
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

final class FailingReplacementPinFileOperations: RecordingPinFileOperations, @unchecked Sendable {
    private let failureLock = NSLock()
    private var shouldFailNextReplacement = false

    var failNextReplacement: Bool {
        get { failureLock.withLock { shouldFailNextReplacement } }
        set { failureLock.withLock { shouldFailNextReplacement = newValue } }
    }

    override func replaceItem(at destination: URL, with source: URL) throws {
        if failureLock.withLock({
            defer { shouldFailNextReplacement = false }
            return shouldFailNextReplacement
        }) {
            throw NSError(domain: "PinStoreTests", code: 1)
        }
        try super.replaceItem(at: destination, with: source)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {}
}
