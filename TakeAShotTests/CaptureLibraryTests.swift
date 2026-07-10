import CoreGraphics
import ImageIO
import XCTest
@testable import TakeAShot

final class CaptureLibraryTests: XCTestCase {
    func testRegisterCommittedMediaReloadsSearchesAndDeletesWithoutRecopyingOriginal() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let identifier = UUID()
        let outputURL = originals.appendingPathComponent("\(identifier.uuidString).mp4")
        let committedBytes = Data("committed-media".utf8)
        try committedBytes.write(to: outputURL)
        let thumbnail = try TestImage.solid(width: 640, height: 360, color: .purple)
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))

        let record = try await store.register(
            media: RecordedMedia(
                id: identifier,
                kind: .video,
                title: "Product demo",
                createdAt: Date(timeIntervalSince1970: 123),
                pixelSize: PixelSize(width: 1920, height: 1080),
                duration: 8.5,
                originalURL: outputURL,
                thumbnail: thumbnail
            )
        )

        XCTAssertEqual(record.originalFilename, "originals/\(identifier.uuidString).mp4")
        XCTAssertEqual(try Data(contentsOf: outputURL), committedBytes)
        let originalPaths = try FileManager.default.contentsOfDirectory(
            at: originals,
            includingPropertiesForKeys: nil
        ).map { $0.resolvingSymlinksInPath().path }
        XCTAssertEqual(originalPaths, [outputURL.resolvingSymlinksInPath().path])
        let searchIDs = await store.search("VIDEO").map(\.id)
        XCTAssertEqual(searchIDs, [identifier])
        let reloaded = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))
        let reloadedIDs = try await reloaded.load().map(\.id)
        XCTAssertEqual(reloadedIDs, [identifier])

        try await reloaded.delete(id: identifier)

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        let remaining = try await reloaded.load()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMediaRegistrationRollbackRemovesThumbnailButKeepsCommittedOriginal() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let identifier = UUID()
        let outputURL = originals.appendingPathComponent("\(identifier.uuidString).gif")
        try Data("gif".utf8).write(to: outputURL)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("index.json", isDirectory: true),
            withIntermediateDirectories: true
        )
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))

        do {
            _ = try await store.register(
                media: RecordedMedia(
                    id: identifier,
                    kind: .gif,
                    title: "GIF recording",
                    createdAt: .now,
                    pixelSize: PixelSize(width: 640, height: 360),
                    duration: 2,
                    originalURL: outputURL,
                    thumbnail: try TestImage.solid(width: 640, height: 360, color: .orange)
                )
            )
            XCTFail("Expected index publication failure")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("thumbnails/\(identifier.uuidString).png").path
            ))
        }
    }

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
        let temporaryIndexFiles = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("index.json.")
                && $0.pathExtension == "tmp"
        }
        XCTAssertTrue(temporaryIndexFiles.isEmpty)
    }

    func testFreshStorePersistHydratesAndPreservesExistingRecords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "first"))
        let firstRecord = try await firstStore.persist(
            image: TestImage.captured(width: 32, height: 24, kind: .area)
        )
        let freshStore = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "second"))

        let secondRecord = try await freshStore.persist(
            image: TestImage.captured(width: 30, height: 20, kind: .window)
        )

        let reloaded = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))
        let reloadedIDs = try await reloaded.load().map(\.id)
        XCTAssertEqual(reloadedIDs, [firstRecord.id, secondRecord.id])
    }

    func testFreshStoreUpdateTagsHydratesExistingIndex() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "text"))
        let record = try await firstStore.persist(
            image: TestImage.captured(width: 32, height: 24, kind: .area)
        )
        let freshStore = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))

        try await freshStore.updateTags(id: record.id, tags: ["Hydrated"])

        let reloaded = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))
        let reloadedRecords = try await reloaded.load()
        XCTAssertEqual(reloadedRecords.first?.tags, ["Hydrated"])
    }

    func testStaleLoadedStoreReloadsIndexBeforePersisting() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeA = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "A"))
        let storeB = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "B"))
        let recordsA = try await storeA.load()
        let recordsB = try await storeB.load()
        XCTAssertTrue(recordsA.isEmpty)
        XCTAssertTrue(recordsB.isEmpty)

        let recordB = try await storeB.persist(
            image: TestImage.captured(width: 30, height: 20, kind: .window)
        )
        let recordA = try await storeA.persist(
            image: TestImage.captured(width: 32, height: 24, kind: .area)
        )

        let reloaded = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))
        let reloadedIDs = try await reloaded.load().map(\.id)
        XCTAssertEqual(reloadedIDs, [recordB.id, recordA.id])
    }

    func testDuplicateCaptureDoesNotOverwriteOriginalOrIndex() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "text"))
        let image = try TestImage.captured(width: 32, height: 24, kind: .area)
        let record = try await store.persist(image: image)
        let originalURL = root.appendingPathComponent(record.originalFilename)
        let indexURL = root.appendingPathComponent("index.json")
        let originalData = try Data(contentsOf: originalURL)
        let indexData = try Data(contentsOf: indexURL)
        var capturedError: Error?

        do {
            _ = try await store.persist(image: image)
        } catch {
            capturedError = error
        }

        let duplicateError = try XCTUnwrap(capturedError as? CaptureLibraryError)
        XCTAssertEqual(duplicateError, .duplicateCapture(image.id))
        XCTAssertEqual(try Data(contentsOf: originalURL), originalData)
        XCTAssertEqual(try Data(contentsOf: indexURL), indexData)
        let indexedRecords = try JSONDecoder().decode([CaptureRecord].self, from: indexData)
        XCTAssertEqual(indexedRecords.map(\.id), [record.id])
    }

    func testPreexistingOriginalDestinationIsRejectedWithoutOverwrite() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try TestImage.captured(width: 32, height: 24, kind: .area)
        let identifier = image.id.uuidString
        let originalsURL = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originalsURL, withIntermediateDirectories: true)
        let originalURL = originalsURL.appendingPathComponent("\(identifier).png")
        let sentinelData = Data([0x01, 0x02, 0x03])
        try sentinelData.write(to: originalURL)
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "text"))
        var didThrow = false

        do {
            _ = try await store.persist(image: image)
        } catch {
            didThrow = true
        }

        XCTAssertTrue(didThrow)
        XCTAssertEqual(try Data(contentsOf: originalURL), sentinelData)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("thumbnails/\(identifier).png").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("index.json").path
        ))
    }

    func testPersistRollsBackAssetsWhenIndexPublicationFails() async throws {
        let root = temporaryDirectory()
        let indexURL = root.appendingPathComponent("index.json")
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: indexURL.path
            )
            try? FileManager.default.removeItem(at: root)
        }
        let initialIndexData = Data("[]".utf8)
        try initialIndexData.write(to: indexURL)
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "text"))
        let initialRecords = try await store.load()
        XCTAssertTrue(initialRecords.isEmpty)
        try FileManager.default.setAttributes(
            [.immutable: true],
            ofItemAtPath: indexURL.path
        )
        let image = try TestImage.captured(width: 32, height: 24, kind: .area)
        let annotations = AnnotationDocument(captureID: image.id)
        let identifier = image.id.uuidString
        var didThrow = false

        do {
            _ = try await store.persist(image: image, annotations: annotations)
        } catch {
            didThrow = true
        }

        XCTAssertTrue(didThrow)
        for filename in [
            "originals/\(identifier).png",
            "thumbnails/\(identifier).png",
            "annotations/\(identifier).json",
        ] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(filename).path
            ))
        }
        XCTAssertEqual(try Data(contentsOf: indexURL), initialIndexData)
    }

    func testFreshStoreDeleteHydratesAndRemovesAllOwnedFiles() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "text"))
        let image = try TestImage.captured(width: 32, height: 24, kind: .area)
        let record = try await firstStore.persist(
            image: image,
            annotations: AnnotationDocument(captureID: image.id)
        )
        let ownedURLs = [
            record.originalFilename,
            record.thumbnailFilename,
            try XCTUnwrap(record.annotationFilename),
        ].map { root.appendingPathComponent($0) }
        let freshStore = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))

        try await freshStore.delete(id: record.id)

        for url in ownedURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        let indexData = try Data(contentsOf: root.appendingPathComponent("index.json"))
        XCTAssertTrue(try JSONDecoder().decode([CaptureRecord].self, from: indexData).isEmpty)
    }

    func testDeleteFailureKeepsRecordIndexedAndAttemptsAllCleanup() async throws {
        let root = temporaryDirectory()
        let thumbnailDirectory = root.appendingPathComponent("thumbnails", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: thumbnailDirectory.path
            )
            try? FileManager.default.removeItem(at: root)
        }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "text"))
        let image = try TestImage.captured(width: 32, height: 24, kind: .area)
        let record = try await store.persist(
            image: image,
            annotations: AnnotationDocument(captureID: image.id)
        )
        let originalURL = root.appendingPathComponent(record.originalFilename)
        let thumbnailURL = root.appendingPathComponent(record.thumbnailFilename)
        let annotationURL = root.appendingPathComponent(try XCTUnwrap(record.annotationFilename))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: thumbnailDirectory.path
        )
        var deletionError: Error?

        do {
            try await store.delete(id: record.id)
        } catch {
            deletionError = error
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: thumbnailDirectory.path
        )
        XCTAssertNotNil(deletionError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: annotationURL.path))
        let visibleSearchIDs = await store.search("text").map(\.id)
        XCTAssertFalse(visibleSearchIDs.contains(record.id))
        let failedIndexData = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let failedIndexRecords = try JSONDecoder().decode(
            [CaptureRecord].self,
            from: failedIndexData
        )
        XCTAssertEqual(failedIndexRecords.map(\.id), [record.id])

        try await store.delete(id: record.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
        let retriedIndexData = try Data(contentsOf: root.appendingPathComponent("index.json"))
        XCTAssertTrue(try JSONDecoder().decode(
            [CaptureRecord].self,
            from: retriedIndexData
        ).isEmpty)
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
