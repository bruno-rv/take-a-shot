import CoreGraphics
import ImageIO
import XCTest
@testable import TakeAShot

final class CaptureLibraryTests: XCTestCase {
    func testPersistReloadSearchAndDelete() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "Quarterly revenue"))
        let image = try TestImage.captured(width: 32, height: 24, kind: .area)

        let record = try await store.persist(image: image)

        let searchIDs = await store.search("revenue").map(\.id)
        XCTAssertEqual(searchIDs, [record.id])

        let reloaded = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))
        let reloadedIDs = try await reloaded.load().map(\.id)
        XCTAssertEqual(reloadedIDs, [record.id])

        try await reloaded.delete(id: record.id)

        let remainingRecords = try await reloaded.load()
        XCTAssertTrue(remainingRecords.isEmpty)
    }

    func testUpdatedTagsArePersistedAndSearchableCaseInsensitively() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unrelated"))
        let record = try await store.persist(
            image: TestImage.captured(width: 32, height: 24, kind: .window)
        )

        try await store.updateTags(id: record.id, tags: ["Finance"])

        let reloaded = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))
        let records = try await reloaded.load()
        let searchIDs = await reloaded.search("FINAN").map(\.id)
        XCTAssertEqual(records.first?.tags, ["Finance"])
        XCTAssertEqual(searchIDs, [record.id])
    }

    func testLoadExcludesOnlyRecordWhoseOwnedFileIsMissing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "text"))
        let corruptRecord = try await store.persist(
            image: TestImage.captured(width: 24, height: 16, kind: .area)
        )
        let validRecord = try await store.persist(
            image: TestImage.captured(width: 20, height: 12, kind: .display)
        )
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(corruptRecord.originalFilename)
        )

        let reloaded = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))
        let loadedIDs = try await reloaded.load().map(\.id)

        XCTAssertEqual(loadedIDs, [validRecord.id])
    }

    func testPersistStoresRelativeOwnedFilenames() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try TestImage.captured(width: 32, height: 24, kind: .area)
        let annotations = AnnotationDocument(captureID: image.id)
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "text"))

        let record = try await store.persist(image: image, annotations: annotations)

        let filenames = [
            record.originalFilename,
            record.editedFilename,
            record.thumbnailFilename,
            record.annotationFilename,
        ].compactMap { $0 }
        XCTAssertFalse(filenames.isEmpty)
        for filename in filenames {
            XCTAssertFalse((filename as NSString).isAbsolutePath)
            XCTAssertFalse(filename.split(separator: "/").contains(".."))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(filename).path
            ))
        }
    }

    func testPersistCreatesDecodableDownsampledThumbnail() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "text"))
        let image = try TestImage.captured(width: 800, height: 400, kind: .area)

        let record = try await store.persist(image: image)

        let thumbnailURL = root.appendingPathComponent(record.thumbnailFilename)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil))
        let thumbnail = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThan(thumbnail.width, image.image.width)
        XCTAssertLessThan(thumbnail.height, image.image.height)
        XCTAssertEqual(
            Double(thumbnail.width) / Double(thumbnail.height),
            Double(image.image.width) / Double(image.image.height),
            accuracy: 0.01
        )
    }

    func testStorageDirectoriesAreCreatedOnFirstPersist() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "text"))
        let directoryNames = ["originals", "exports", "thumbnails", "annotations", "temporary"]
        for name in directoryNames {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(name).path
            ))
        }

        _ = try await store.persist(
            image: TestImage.captured(width: 32, height: 24, kind: .area)
        )

        for name in directoryNames {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(name).path,
                isDirectory: &isDirectory
            ))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testIndexUpdatesReplaceReadOnlyPublishedFileAtomically() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "text"))
        let firstRecord = try await store.persist(
            image: TestImage.captured(width: 32, height: 24, kind: .area)
        )
        let indexURL = root.appendingPathComponent("index.json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: indexURL.path
        )

        let secondRecord = try await store.persist(
            image: TestImage.captured(width: 30, height: 20, kind: .window)
        )

        let publishedRecords = try JSONDecoder().decode(
            [CaptureRecord].self,
            from: Data(contentsOf: indexURL)
        )
        XCTAssertEqual(publishedRecords.map(\.id), [firstRecord.id, secondRecord.id])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("index.json.tmp").path
        ))
    }
}

private struct StubOCR: OCRRecognizing {
    let text: String

    func recognizeText(in image: CGImage) async throws -> String {
        text
    }
}

private extension TestImage {
    static func captured(width: Int, height: Int, kind: CaptureKind) throws -> CapturedImage {
        let image = try solid(width: width, height: height, color: .white)
        return CapturedImage(
            id: UUID(),
            kind: kind,
            title: "Test capture",
            createdAt: .now,
            image: image,
            pixelSize: .init(width: width, height: height)
        )
    }
}
