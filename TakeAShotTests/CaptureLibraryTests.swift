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
        let searchIDs = try await eventually {
            let ids = await store.search("revenue").map(\.id)
            return ids.isEmpty ? nil : ids
        }
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
        let annotations = annotationDocument(captureID: image.id)
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
        _ = try await eventually {
            let ids = await store.search("text").map(\.id)
            return ids == [record.id] ? ids : nil
        }
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
            annotations: annotationDocument(captureID: image.id)
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

    func testDeleteMoveFailureRestoresEveryOwnedFileAndKeepsRecordVisible() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let moves = LockedCounter()
        let operations = CaptureLibraryFileOperations(
            moveItem: { source, destination in
                if moves.increment() == 2 { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.moveItem(at: source, to: destination)
            },
            removeItem: { try FileManager.default.removeItem(at: $0) }
        )
        let store = CaptureLibraryStore(
            rootURL: root,
            ocr: StubOCR(text: "text"),
            fileOperations: operations
        )
        let image = try TestImage.captured(width: 32, height: 24, kind: .area)
        let record = try await store.persist(
            image: image,
            annotations: annotationDocument(captureID: image.id)
        )
        let originalURL = root.appendingPathComponent(record.originalFilename)
        let thumbnailURL = root.appendingPathComponent(record.thumbnailFilename)
        let annotationURL = root.appendingPathComponent(try XCTUnwrap(record.annotationFilename))
        var deletionError: Error?

        do {
            try await store.delete(id: record.id)
        } catch {
            deletionError = error
        }

        XCTAssertNotNil(deletionError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: annotationURL.path))
        let visibleSearchIDs = await store.search("text").map(\.id)
        XCTAssertTrue(visibleSearchIDs.contains(record.id))
        let failedIndexData = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let failedIndexRecords = try JSONDecoder().decode(
            [CaptureRecord].self,
            from: failedIndexData
        )
        XCTAssertEqual(failedIndexRecords.map(\.id), [record.id])

    }

    func testAnnotationDocumentRoundTripsAcrossRelaunchAndUpdatesLastEditedAt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let image = try TestImage.captured(width: 80, height: 60, kind: .window)
        let record = try await store.persist(image: image)
        let document = annotationDocument(captureID: image.id)
        let editedAt = Date(timeIntervalSince1970: 9_876)

        try await store.saveAnnotations(document, for: record.id, editedAt: editedAt)

        let relaunched = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let records = try await relaunched.load()
        let loadedDocument = try await relaunched.loadAnnotations(for: record.id)
        XCTAssertEqual(loadedDocument, document)
        XCTAssertEqual(records.first?.annotationFilename, "annotations/\(record.id.uuidString).json")
        XCTAssertEqual(records.first?.lastEditedAt, editedAt)
    }

    func testSavingUnchangedAnnotationDocumentDoesNotChangeFileOrLastEditedAt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let image = try TestImage.captured(width: 80, height: 60, kind: .window)
        let record = try await store.persist(image: image)
        let document = annotationDocument(captureID: image.id)
        let originalDate = Date(timeIntervalSince1970: 1_000)
        try await store.saveAnnotations(document, for: record.id, editedAt: originalDate)
        let annotationURL = root.appendingPathComponent(
            "annotations/\(record.id.uuidString).json"
        )
        let originalData = try Data(contentsOf: annotationURL)

        try await store.saveAnnotations(
            document,
            for: record.id,
            editedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(try Data(contentsOf: annotationURL), originalData)
        let records = try await store.load()
        XCTAssertEqual(records.first?.lastEditedAt, originalDate)
    }

    func testEmptyAnnotationDocumentDoesNotCreateFileAndResetRemovesExistingFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let image = try TestImage.captured(width: 40, height: 30, kind: .area)
        let record = try await store.persist(
            image: image,
            annotations: AnnotationDocument(captureID: image.id)
        )
        XCTAssertNil(record.annotationFilename)

        try await store.saveAnnotations(annotationDocument(captureID: image.id), for: image.id)
        var loaded = try await store.load()
        let filename = try XCTUnwrap(loaded.first?.annotationFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(filename).path))

        try await store.saveAnnotations(AnnotationDocument(captureID: image.id), for: image.id)

        loaded = try await store.load()
        XCTAssertNil(loaded.first?.annotationFilename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(filename).path))
    }

    func testAnnotationReplaceRollsBackDocumentAndMetadataWhenIndexPublishFails() async throws {
        let root = temporaryDirectory()
        let indexURL = root.appendingPathComponent("index.json")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: indexURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let image = try TestImage.captured(width: 40, height: 30, kind: .area)
        _ = try await store.persist(image: image)
        let original = annotationDocument(captureID: image.id)
        let originalDate = Date(timeIntervalSince1970: 100)
        try await store.saveAnnotations(original, for: image.id, editedAt: originalDate)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: indexURL.path)
        var replacement = original
        replacement.cropRect = NormalizedRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)

        await XCTAssertThrowsErrorAsync {
            try await store.saveAnnotations(
                replacement,
                for: image.id,
                editedAt: Date(timeIntervalSince1970: 200)
            )
        }
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: indexURL.path)

        let relaunched = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let loadedDocument = try await relaunched.loadAnnotations(for: image.id)
        let loadedRecords = try await relaunched.load()
        XCTAssertEqual(loadedDocument, original)
        XCTAssertEqual(loadedRecords.first?.lastEditedAt, originalDate)
    }

    func testPersistencePublishesBeforeOCRAndEventuallyIndexesResult() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ocr = GatedOCR()
        let store = CaptureLibraryStore(rootURL: root, ocr: ocr)
        let image = try TestImage.captured(width: 32, height: 24, kind: .area)

        let record = try await store.persist(image: image)
        await fulfillment(of: [ocr.started], timeout: 1)

        XCTAssertEqual(record.ocrText, "")
        let persistedIDs = try await store.load().map(\.id)
        XCTAssertEqual(persistedIDs, [image.id])
        await ocr.resume(with: .success("Deferred invoice total"))
        let searchIDs = try await eventually {
            let ids = await store.search("invoice").map(\.id)
            return ids.isEmpty ? nil : ids
        }
        XCTAssertEqual(searchIDs, [image.id])
    }

    func testOCRFailureDoesNotFailPersistenceOrRemovePublishedCapture() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let image = try TestImage.captured(width: 32, height: 24, kind: .display)

        let record = try await store.persist(image: image)

        XCTAssertEqual(record.ocrText, "")
        let relaunched = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let relaunchedIDs = try await relaunched.load().map(\.id)
        XCTAssertEqual(relaunchedIDs, [image.id])
    }

    func testForgedOwnedFilenamesAreSkippedAndNeverDeleteUnownedFiles() async throws {
        for forged in [
            "originals/../sentinel.png",
            "originals/\(UUID().uuidString).png",
            "thumbnails/placeholder.png",
            "originals/placeholder.jpg",
        ] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
            let image = try TestImage.captured(width: 12, height: 12, kind: .area)
            let record = try await store.persist(image: image)
            let sentinel = root.appendingPathComponent("sentinel.png")
            try Data("owned-by-user".utf8).write(to: sentinel)
            var forgedRecord = record
            forgedRecord = CaptureRecord(
                id: forgedRecord.id,
                kind: forgedRecord.kind,
                title: forgedRecord.title,
                createdAt: forgedRecord.createdAt,
                lastEditedAt: forgedRecord.lastEditedAt,
                pixelSize: forgedRecord.pixelSize,
                duration: forgedRecord.duration,
                originalFilename: forged.replacingOccurrences(
                    of: "placeholder",
                    with: record.id.uuidString
                ),
                editedFilename: forgedRecord.editedFilename,
                thumbnailFilename: forgedRecord.thumbnailFilename,
                annotationFilename: forgedRecord.annotationFilename,
                ocrText: forgedRecord.ocrText,
                tags: forgedRecord.tags
            )
            try JSONEncoder().encode([forgedRecord]).write(to: root.appendingPathComponent("index.json"))

            let fresh = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
            let loaded = try await fresh.load()
            XCTAssertTrue(loaded.isEmpty, "Expected rejection for \(forged)")
            try await fresh.delete(id: record.id)
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("owned-by-user".utf8))
        }
    }

    func testDuplicateForgedIndexEntrySharingOwnedFilesIsSkipped() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let image = try TestImage.captured(width: 12, height: 12, kind: .area)
        let record = try await store.persist(image: image)
        var forged = record
        forged = CaptureRecord(
            id: forged.id,
            kind: forged.kind,
            title: "Forged duplicate",
            createdAt: forged.createdAt,
            lastEditedAt: forged.lastEditedAt,
            pixelSize: forged.pixelSize,
            duration: forged.duration,
            originalFilename: forged.originalFilename,
            editedFilename: forged.editedFilename,
            thumbnailFilename: forged.thumbnailFilename,
            annotationFilename: forged.annotationFilename,
            ocrText: forged.ocrText,
            tags: forged.tags
        )
        try JSONEncoder().encode([record, forged]).write(
            to: root.appendingPathComponent("index.json")
        )

        let fresh = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let records = try await fresh.load()

        XCTAssertEqual(records, [record])
    }

    func testDeleteRemovesAcceptedRecordWhenInvalidDuplicatePrecedesIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let record = try await store.persist(
            image: TestImage.captured(width: 12, height: 12, kind: .area)
        )
        let originalURL = root.appendingPathComponent(record.originalFilename)
        let thumbnailURL = root.appendingPathComponent(record.thumbnailFilename)
        try JSONEncoder().encode([invalidDuplicate(of: record), record]).write(
            to: root.appendingPathComponent("index.json")
        )
        let fresh = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())

        try await fresh.delete(id: record.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
        let indexed = try JSONDecoder().decode(
            [CaptureRecord].self,
            from: Data(contentsOf: root.appendingPathComponent("index.json"))
        )
        XCTAssertTrue(indexed.isEmpty)
        let loaded = try await fresh.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testSaveAnnotationsTargetsAcceptedRecordWhenInvalidDuplicatePrecedesIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let record = try await store.persist(
            image: TestImage.captured(width: 12, height: 12, kind: .area)
        )
        try JSONEncoder().encode([invalidDuplicate(of: record), record]).write(
            to: root.appendingPathComponent("index.json")
        )
        let document = annotationDocument(captureID: record.id)
        let editedAt = Date(timeIntervalSince1970: 2_468)
        let fresh = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())

        try await fresh.saveAnnotations(document, for: record.id, editedAt: editedAt)

        let indexed = try JSONDecoder().decode(
            [CaptureRecord].self,
            from: Data(contentsOf: root.appendingPathComponent("index.json"))
        )
        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(indexed.first?.originalFilename, record.originalFilename)
        XCTAssertEqual(indexed.first?.annotationFilename, "annotations/\(record.id.uuidString).json")
        XCTAssertEqual(indexed.first?.lastEditedAt, editedAt)
        let loadedDocument = try await fresh.loadAnnotations(for: record.id)
        XCTAssertEqual(loadedDocument, document)
    }

    func testUpdateTagsTargetsAcceptedRecordWhenInvalidDuplicatePrecedesIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let record = try await store.persist(
            image: TestImage.captured(width: 12, height: 12, kind: .area)
        )
        try JSONEncoder().encode([invalidDuplicate(of: record), record]).write(
            to: root.appendingPathComponent("index.json")
        )
        let fresh = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())

        try await fresh.updateTags(id: record.id, tags: ["Accepted"])

        let indexed = try JSONDecoder().decode(
            [CaptureRecord].self,
            from: Data(contentsOf: root.appendingPathComponent("index.json"))
        )
        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(indexed.first?.originalFilename, record.originalFilename)
        XCTAssertEqual(indexed.first?.tags, ["Accepted"])
    }

    func testOCRUpdateTargetsAcceptedRecordWhenInvalidDuplicatePrecedesIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ocr = GatedOCR()
        let store = CaptureLibraryStore(rootURL: root, ocr: ocr)
        let record = try await store.persist(
            image: TestImage.captured(width: 12, height: 12, kind: .area)
        )
        await fulfillment(of: [ocr.started], timeout: 1)
        try JSONEncoder().encode([invalidDuplicate(of: record), record]).write(
            to: root.appendingPathComponent("index.json")
        )

        await ocr.resume(with: .success("Accepted OCR"))

        let indexed = try await eventually {
            let records = try JSONDecoder().decode(
                [CaptureRecord].self,
                from: Data(contentsOf: root.appendingPathComponent("index.json"))
            )
            return records.count == 1 && records.first?.ocrText == "Accepted OCR"
                ? records
                : nil
        }
        XCTAssertEqual(indexed.first?.originalFilename, record.originalFilename)
    }

    func testIntermediateSymlinkEscapeIsSkippedAndExternalFileIsPreservedOnDelete() async throws {
        let root = temporaryDirectory()
        let external = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let image = try TestImage.captured(width: 12, height: 12, kind: .area)
        let record = try await store.persist(image: image)
        let originals = root.appendingPathComponent("originals")
        try FileManager.default.removeItem(at: originals)
        try FileManager.default.createSymbolicLink(at: originals, withDestinationURL: external)
        let escaped = external.appendingPathComponent("\(record.id.uuidString).png")
        try Data("external".utf8).write(to: escaped)

        let fresh = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let loaded = try await fresh.load()
        XCTAssertTrue(loaded.isEmpty)
        try await fresh.delete(id: record.id)
        XCTAssertEqual(try Data(contentsOf: escaped), Data("external".utf8))
    }

    func testSymlinkedIndexIsRejectedWithoutReadingExternalMetadata() async throws {
        let root = temporaryDirectory()
        let external = temporaryDirectory().appendingPathComponent("external-index.json")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external.deletingLastPathComponent())
        }
        try Data("[]".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("index.json"),
            withDestinationURL: external
        )
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))

        await XCTAssertThrowsErrorAsync { _ = try await store.load() }
        XCTAssertEqual(try Data(contentsOf: external), Data("[]".utf8))
    }

    func testMediaRegistrationRejectsSymlinkedOriginalEvenAtExactOwnedPath() async throws {
        let root = temporaryDirectory()
        let externalRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalRoot)
        }
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let id = UUID()
        let external = externalRoot.appendingPathComponent("recording.mp4")
        try Data("external-media".utf8).write(to: external)
        let linked = originals.appendingPathComponent("\(id.uuidString).mp4")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))

        await XCTAssertThrowsErrorAsync {
            _ = try await store.register(media: RecordedMedia(
                id: id,
                kind: .video,
                title: "Linked",
                createdAt: .now,
                pixelSize: PixelSize(width: 1, height: 1),
                duration: 1,
                originalURL: linked,
                thumbnail: try TestImage.solid(width: 1, height: 1, color: .black)
            ))
        }
        XCTAssertEqual(try Data(contentsOf: external), Data("external-media".utf8))
    }

    func testMediaRegistrationRequiresExactOwnedUUIDAndExtension() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let identifier = UUID()
        let wrong = originals.appendingPathComponent("\(UUID().uuidString).gif")
        try Data("gif".utf8).write(to: wrong)
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let media = RecordedMedia(
            id: identifier,
            kind: .gif,
            title: "GIF",
            createdAt: .now,
            pixelSize: PixelSize(width: 1, height: 1),
            duration: 1,
            originalURL: wrong,
            thumbnail: try TestImage.solid(width: 1, height: 1, color: .black)
        )

        await XCTAssertThrowsErrorAsync { _ = try await store.register(media: media) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrong.path))
    }

    func testMediaRegistrationSurfacesThumbnailRollbackFailure() async throws {
        let root = temporaryDirectory()
        let indexURL = root.appendingPathComponent("index.json")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: indexURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let identifier = UUID()
        let output = originals.appendingPathComponent("\(identifier.uuidString).mp4")
        try Data("media".utf8).write(to: output)
        let operations = CaptureLibraryFileOperations(
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { url in
                if url.pathExtension == "png" { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.removeItem(at: url)
            }
        )
        let store = CaptureLibraryStore(
            rootURL: root,
            ocr: StubOCR(text: ""),
            fileOperations: operations
        )
        try Data("[]".utf8).write(to: indexURL)
        _ = try await store.load()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: indexURL.path)

        do {
            _ = try await store.register(media: RecordedMedia(
                id: identifier,
                kind: .video,
                title: "Video",
                createdAt: .now,
                pixelSize: PixelSize(width: 1, height: 1),
                duration: 1,
                originalURL: output,
                thumbnail: try TestImage.solid(width: 1, height: 1, color: .black)
            ))
            XCTFail("Expected rollback failure")
        } catch let error as CaptureLibraryError {
            guard case .rollbackFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMediaDeleteIndexFailureRestoresOriginalThumbnailAndMetadata() async throws {
        let root = temporaryDirectory()
        let indexURL = root.appendingPathComponent("index.json")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: indexURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let id = UUID()
        let originalURL = originals.appendingPathComponent("\(id.uuidString).gif")
        try Data("gif".utf8).write(to: originalURL)
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let record = try await store.register(media: RecordedMedia(
            id: id,
            kind: .gif,
            title: "GIF",
            createdAt: .now,
            pixelSize: PixelSize(width: 2, height: 2),
            duration: 1,
            originalURL: originalURL,
            thumbnail: try TestImage.solid(width: 2, height: 2, color: .black)
        ))
        let thumbnailURL = root.appendingPathComponent(record.thumbnailFilename)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: indexURL.path)

        await XCTAssertThrowsErrorAsync { try await store.delete(id: id) }
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: indexURL.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
        let reloaded = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let records = try await reloaded.load()
        XCTAssertEqual(records.map(\.id), [id])
    }
}

private struct StubOCR: OCRRecognizing {
    let text: String

    func recognizeText(in image: CGImage) async throws -> String {
        text
    }
}

private struct ThrowingOCR: OCRRecognizing {
    func recognizeText(in image: CGImage) async throws -> String {
        throw CocoaError(.coderReadCorrupt)
    }
}

private actor GatedOCR: OCRRecognizing {
    nonisolated let started = XCTestExpectation(description: "OCR started")
    private var continuation: CheckedContinuation<String, Error>?

    func recognizeText(in image: CGImage) async throws -> String {
        started.fulfill()
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resume(with result: Result<String, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private func annotationDocument(captureID: UUID) -> AnnotationDocument {
    AnnotationDocument(
        captureID: captureID,
        items: [
            .text(TextAnnotation(
                id: UUID(),
                bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2),
                text: "Persisted",
                fontSize: 20,
                color: .red
            )),
            .blur(RectAnnotation(
                id: UUID(),
                rect: NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                color: .red,
                amount: 8
            )),
        ],
        cropRect: NormalizedRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    )
}

private func invalidDuplicate(of record: CaptureRecord) -> CaptureRecord {
    CaptureRecord(
        id: record.id,
        kind: record.kind,
        title: "Invalid duplicate",
        createdAt: record.createdAt,
        lastEditedAt: record.lastEditedAt,
        pixelSize: record.pixelSize,
        duration: record.duration,
        originalFilename: "originals/\(UUID().uuidString).png",
        editedFilename: record.editedFilename,
        thumbnailFilename: record.thumbnailFilename,
        annotationFilename: record.annotationFilename,
        ocrText: record.ocrText,
        tags: record.tags
    )
}

private func eventually<T>(
    attempts: Int = 200,
    operation: () async throws -> T?
) async throws -> T {
    for _ in 0..<attempts {
        if let value = try await operation() { return value }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.coderValueNotFound)
}

private func XCTAssertThrowsErrorAsync(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
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
