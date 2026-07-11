import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import ImageIO
import XCTest
@testable import TakeAShot

final class CaptureLibraryTests: XCTestCase {
    func testRelaunchRecoversValidOrphanRecordingExactlyOnceAndCleansFragments() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        let temporary = root.appendingPathComponent("temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let recoveredID = UUID()
        let orphanURL = originals.appendingPathComponent("\(recoveredID.uuidString).gif")
        var writer = try GIFWriter(
            url: orphanURL,
            maxFPS: 10,
            maxPixelSize: 1_280,
            maxDuration: 60
        )
        try writer.append(
            image: TestImage.solid(width: 24, height: 16, color: .purple),
            presentationTime: .zero
        )
        try writer.append(
            image: TestImage.solid(width: 24, height: 16, color: .orange),
            presentationTime: CMTime(seconds: 0.1, preferredTimescale: 600)
        )
        try writer.finish(stopTime: CMTime(seconds: 0.2, preferredTimescale: 600))
        let thumbnails = root.appendingPathComponent("thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try ImageExporter.write(
            try ImageExporter.pngData(
                for: TestImage.solid(width: 1, height: 1, color: .black)
            ),
            to: thumbnails.appendingPathComponent("\(recoveredID.uuidString).png")
        )

        let invalidID = UUID()
        let invalidURL = originals.appendingPathComponent("\(invalidID.uuidString).gif")
        try Data("not-a-gif".utf8).write(to: invalidURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86_401)],
            ofItemAtPath: invalidURL.path
        )
        let partialURL = temporary.appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("partial".utf8).write(to: partialURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86_401)],
            ofItemAtPath: partialURL.path
        )

        let firstLaunch = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let firstLoad = try await firstLaunch.load()
        XCTAssertEqual(firstLoad.map(\.id), [recoveredID])
        XCTAssertEqual(firstLoad.first?.pixelSize, PixelSize(width: 24, height: 16))
        XCTAssertEqual(firstLoad.first?.duration ?? 0, 0.2, accuracy: 0.001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))

        let secondLaunch = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: ""))
        let secondLoad = try await secondLaunch.load()
        XCTAssertEqual(secondLoad.map(\.id), [recoveredID])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("thumbnails", isDirectory: true),
                includingPropertiesForKeys: nil
            ).count,
            1
        )
    }

    func testRegisterCommittedMediaReloadsSearchesAndDeletesWithoutRecopyingOriginal() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let identifier = UUID()
        let outputURL = originals.appendingPathComponent("\(identifier.uuidString).mp4")
        try await writeTestMP4(to: outputURL)
        let committedBytes = try Data(contentsOf: outputURL)
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

    func testCancelledPersistRollsBackAssetsBeforePublishingIndex() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexLock = try HeldCaptureLibraryIndexLock(rootURL: root)
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))
        let image = try TestImage.captured(width: 32, height: 24, kind: .area)
        let started = expectation(description: "persistence started")
        let persistence = Task {
            started.fulfill()
            return try await store.persist(image: image)
        }
        await fulfillment(of: [started], timeout: 1)

        persistence.cancel()
        indexLock.release()

        guard case .failure(let error) = await persistence.result else {
            return XCTFail("Expected cancelled persistence")
        }
        XCTAssertTrue(error is CancellationError)
        let reloaded = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))
        let records = try await reloaded.load()
        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("originals/\(image.id.uuidString).png").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("thumbnails/\(image.id.uuidString).png").path
        ))
    }

    func testCancelledPersistSurfacesAssetRollbackFailure() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexLock = try HeldCaptureLibraryIndexLock(rootURL: root)
        let operations = CaptureLibraryFileOperations(
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        let store = CaptureLibraryStore(
            rootURL: root,
            ocr: StubOCR(text: "unused"),
            fileOperations: operations
        )
        let image = try TestImage.captured(width: 32, height: 24, kind: .area)
        let started = expectation(description: "persistence started")
        let persistence = Task {
            started.fulfill()
            return try await store.persist(image: image)
        }
        await fulfillment(of: [started], timeout: 1)

        persistence.cancel()
        indexLock.release()

        guard case .failure(let error) = await persistence.result,
              let libraryError = error as? CaptureLibraryError,
              case .rollbackFailed = libraryError else {
            return XCTFail("Expected cancellation rollback failure")
        }
    }

    @MainActor
    func testSupersededPersistRollsBackAssetsBeforePublishingIndex() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexLock = try HeldCaptureLibraryIndexLock(rootURL: root)
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))
        let image = try TestImage.captured(width: 32, height: 24, kind: .window)
        let scope = CaptureOperationScope()
        let token = try XCTUnwrap(scope.begin(.windowDiscovery))
        let started = expectation(description: "persistence started")
        let persistence = Task {
            started.fulfill()
            return try await store.persist(image: image)
        }
        scope.retain(persistence, for: token)
        await fulfillment(of: [started], timeout: 1)

        _ = scope.begin(.displayCapture)
        indexLock.release()

        guard case .failure(let error) = await persistence.result else {
            return XCTFail("Expected superseded persistence")
        }
        XCTAssertTrue(error is CancellationError)
        let reloaded = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "unused"))
        let records = try await reloaded.load()
        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("originals/\(image.id.uuidString).png").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("thumbnails/\(image.id.uuidString).png").path
        ))
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

    func testSearchIsCaseAndDiacriticInsensitiveAcrossOCRTitleAndTags() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: StubOCR(text: "Résumé review"))
        let record = try await store.persist(
            image: TestImage.captured(width: 32, height: 24, kind: .window)
        )
        _ = try await eventually {
            await store.search("resume").first
        }
        try await store.updateTags(id: record.id, tags: ["Café"])

        let resumeIDs = await store.search("RESUME").map(\.id)
        let cafeIDs = await store.search("cafe").map(\.id)
        XCTAssertEqual(resumeIDs, [record.id])
        XCTAssertEqual(cafeIDs, [record.id])
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

    func testLoadSkipsCorruptOriginalAndReportsItWithoutDroppingValidRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let corrupt = try await store.persist(
            image: TestImage.captured(width: 24, height: 16, kind: .area)
        )
        let valid = try await store.persist(
            image: TestImage.captured(width: 20, height: 12, kind: .display)
        )
        try Data("not an image".utf8).write(
            to: root.appendingPathComponent(corrupt.originalFilename)
        )

        let reloaded = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let loadedIDs = try await reloaded.load().map(\.id)
        let issues = await reloaded.loadIssues()
        XCTAssertEqual(loadedIDs, [valid.id])
        XCTAssertEqual(
            issues,
            [CaptureLibraryLoadIssue(recordID: corrupt.id, reason: .corruptOriginal)]
        )
    }

    func testLoadRejectsMetadataReadableButPixelCorruptOriginal() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let corrupt = try await store.persist(
            image: TestImage.captured(width: 320, height: 240, kind: .area)
        )
        let valid = try await store.persist(
            image: TestImage.captured(width: 20, height: 12, kind: .display)
        )
        let originalURL = root.appendingPathComponent(corrupt.originalFilename)
        let complete = try Data(contentsOf: originalURL)
        var truncated: Data?
        for length in 33..<complete.count {
            let candidate = Data(complete.prefix(length))
            guard let source = CGImageSourceCreateWithData(candidate as CFData, nil),
                  CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else { continue }
            let decoded = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64,
                ] as CFDictionary
            )
            if decoded == nil {
                truncated = candidate
                break
            }
        }
        try XCTUnwrap(truncated).write(to: originalURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(originalURL as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCopyPropertiesAtIndex(source, 0, nil))

        let reloaded = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let loadedIDs = try await reloaded.load().map(\.id)
        let issues = await reloaded.loadIssues()
        XCTAssertEqual(loadedIDs, [valid.id])
        XCTAssertEqual(
            issues,
            [CaptureLibraryLoadIssue(recordID: corrupt.id, reason: .corruptOriginal)]
        )
    }

    func testLoadSkipsCorruptAnnotationAndReportsItWithoutDroppingValidRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let image = try TestImage.captured(width: 24, height: 16, kind: .area)
        let corrupt = try await store.persist(
            image: image,
            annotations: annotationDocument(captureID: image.id)
        )
        let valid = try await store.persist(
            image: TestImage.captured(width: 20, height: 12, kind: .display)
        )
        try Data("{bad annotation".utf8).write(
            to: root.appendingPathComponent(try XCTUnwrap(corrupt.annotationFilename))
        )

        let reloaded = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let loadedIDs = try await reloaded.load().map(\.id)
        let issues = await reloaded.loadIssues()
        XCTAssertEqual(loadedIDs, [valid.id])
        XCTAssertEqual(
            issues,
            [CaptureLibraryLoadIssue(recordID: corrupt.id, reason: .corruptAnnotation)]
        )
    }

    func testLoadSkipsEmptyRecordedMediaAndReportsItWithoutDroppingValidRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let mediaID = UUID()
        let mediaURL = originals.appendingPathComponent("\(mediaID.uuidString).gif")
        try Data().write(to: mediaURL)
        let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let valid = try await store.persist(
            image: TestImage.captured(width: 20, height: 12, kind: .display)
        )
        _ = try await store.register(media: RecordedMedia(
            id: mediaID,
            kind: .gif,
            title: "Corrupt GIF",
            createdAt: .now,
            pixelSize: PixelSize(width: 2, height: 2),
            duration: 1,
            originalURL: mediaURL,
            thumbnail: try TestImage.solid(width: 2, height: 2, color: .black)
        ))

        let reloaded = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let loadedIDs = try await reloaded.load().map(\.id)
        let issues = await reloaded.loadIssues()
        XCTAssertEqual(loadedIDs, [valid.id])
        XCTAssertEqual(
            issues,
            [CaptureLibraryLoadIssue(recordID: mediaID, reason: .corruptOriginal)]
        )
    }

    func testLoadRejectsNonemptyCorruptGIFAndMP4Containers() async throws {
        for kind in [CaptureKind.gif, .video] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let originals = root.appendingPathComponent("originals", isDirectory: true)
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
            let valid = try await store.persist(
                image: TestImage.captured(width: 20, height: 12, kind: .display)
            )
            let mediaID = UUID()
            let mediaURL = originals.appendingPathComponent(
                "\(mediaID.uuidString).\(kind == .gif ? "gif" : "mp4")"
            )
            try Data("nonempty but corrupt media".utf8).write(to: mediaURL)
            _ = try await store.register(media: RecordedMedia(
                id: mediaID,
                kind: kind,
                title: "Corrupt media",
                createdAt: .now,
                pixelSize: PixelSize(width: 2, height: 2),
                duration: 1,
                originalURL: mediaURL,
                thumbnail: try TestImage.solid(width: 2, height: 2, color: .black)
            ))

            let reloaded = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
            let loadedIDs = try await reloaded.load().map(\.id)
            let issues = await reloaded.loadIssues()
            XCTAssertEqual(loadedIDs, [valid.id], "Expected corrupt \(kind) to be skipped")
            XCTAssertEqual(
                issues,
                [CaptureLibraryLoadIssue(recordID: mediaID, reason: .corruptOriginal)]
            )
        }
    }

    func testMalformedIndexElementDoesNotEraseIndependentlyValidRecords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let first = try await store.persist(
            image: TestImage.captured(width: 24, height: 16, kind: .area)
        )
        let second = try await store.persist(
            image: TestImage.captured(width: 20, height: 12, kind: .display)
        )
        let encoder = JSONEncoder()
        let firstData = try encoder.encode(first)
        let secondData = try encoder.encode(second)
        let index = Data("[".utf8)
            + firstData
            + Data(",not-json,".utf8)
            + secondData
            + Data("]".utf8)
        try index.write(to: root.appendingPathComponent("index.json"))

        let reloaded = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let loadedIDs = try await reloaded.load().map(\.id)
        let issues = await reloaded.loadIssues()
        XCTAssertEqual(loadedIDs, [first.id, second.id])
        XCTAssertEqual(
            issues,
            [CaptureLibraryLoadIssue(recordID: nil, reason: .malformedRecord)]
        )
    }

    func testUnbalancedMalformedObjectOrArrayPreservesLaterValidRecordOrder() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let first = try await store.persist(
            image: TestImage.captured(width: 20, height: 12, kind: .display)
        )
        let second = try await store.persist(
            image: TestImage.captured(width: 18, height: 10, kind: .window)
        )
        let firstData = try JSONEncoder().encode(first)
        let secondData = try JSONEncoder().encode(second)

        for prefix in [Data("[{\"broken\":true,".utf8), Data("[[\"broken\",".utf8)] {
            let index = prefix + firstData + Data(",".utf8) + secondData + Data("]".utf8)
            try index.write(to: root.appendingPathComponent("index.json"))
            let reloaded = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
            let loadedIDs = try await reloaded.load().map(\.id)
            let issues = await reloaded.loadIssues()
            XCTAssertEqual(loadedIDs, [first.id, second.id])
            XCTAssertEqual(
                issues,
                [CaptureLibraryLoadIssue(recordID: nil, reason: .malformedRecord)]
            )
        }
    }

    func testBalancedNestedRecordObjectIsNotAcceptedAsTopLevelRecovery() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let record = try await store.persist(
            image: TestImage.captured(width: 20, height: 12, kind: .display)
        )
        let nested = Data("[{\"wrapper\":".utf8)
            + (try JSONEncoder().encode(record))
            + Data("}]".utf8)
        try nested.write(to: root.appendingPathComponent("index.json"))

        let reloaded = CaptureLibraryStore(rootURL: root, ocr: ThrowingOCR())
        let loaded = try await reloaded.load()
        let issues = await reloaded.loadIssues()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(
            issues,
            [CaptureLibraryLoadIssue(recordID: nil, reason: .malformedRecord)]
        )
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

    func testOCRWorkerIsSerialAndDownsamplesLargeInputs() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recognizer = SerialInspectingOCR(expectedStarts: 3)
        let store = CaptureLibraryStore(rootURL: root, ocr: recognizer)

        _ = try await store.persist(
            image: TestImage.captured(width: 2_400, height: 40, kind: .area)
        )
        _ = try await store.persist(
            image: TestImage.captured(width: 40, height: 40, kind: .window)
        )
        _ = try await store.persist(
            image: TestImage.captured(width: 40, height: 40, kind: .display)
        )
        await fulfillment(of: [recognizer.firstStarted], timeout: 1)
        try await Task.sleep(for: .milliseconds(30))

        var snapshot = await recognizer.snapshot()
        XCTAssertEqual(snapshot.started, 1)
        XCTAssertEqual(snapshot.maximumActive, 1)
        XCTAssertLessThanOrEqual(snapshot.maximumInputDimension, 2_048)

        for expectedStarts in 2...3 {
            await recognizer.resumeNext()
            _ = try await eventually {
                let value = await recognizer.snapshot().started
                return value == expectedStarts ? value : nil
            }
        }
        await recognizer.resumeNext()
        snapshot = await recognizer.snapshot()
        XCTAssertEqual(snapshot.maximumActive, 1)
    }

    func testCancellingOCRWorkerDropsQueuedJobs() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recognizer = SerialInspectingOCR(expectedStarts: 2)
        let store = CaptureLibraryStore(rootURL: root, ocr: recognizer)
        _ = try await store.persist(
            image: TestImage.captured(width: 40, height: 40, kind: .area)
        )
        _ = try await store.persist(
            image: TestImage.captured(width: 40, height: 40, kind: .window)
        )
        await fulfillment(of: [recognizer.firstStarted], timeout: 1)

        await store.cancelPendingOCR()
        _ = try await store.persist(
            image: TestImage.captured(width: 40, height: 40, kind: .display)
        )
        try await Task.sleep(for: .milliseconds(30))
        var started = await recognizer.snapshot().started
        XCTAssertEqual(started, 1)

        await recognizer.resumeNext()
        _ = try await eventually {
            let value = await recognizer.snapshot().started
            return value == 2 ? value : nil
        }
        await recognizer.resumeNext()

        started = await recognizer.snapshot().started
        XCTAssertEqual(started, 2)
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
        try writeTestGIF(to: originalURL)
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

private final class HeldCaptureLibraryIndexLock {
    private var descriptor: Int32

    init(rootURL: URL) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let lockURL = rootURL.appendingPathComponent(".index.lock")
        descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_CREAT | O_RDWR | O_EXLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
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

private actor SerialInspectingOCR: OCRRecognizing {
    struct Snapshot {
        let started: Int
        let maximumActive: Int
        let maximumInputDimension: Int
    }

    nonisolated let firstStarted = XCTestExpectation(description: "first OCR job started")
    private var continuations: [CheckedContinuation<String, Never>] = []
    private var started = 0
    private var active = 0
    private var maximumActive = 0
    private var maximumInputDimension = 0

    init(expectedStarts: Int) {}

    func recognizeText(in image: CGImage) async throws -> String {
        started += 1
        active += 1
        maximumActive = max(maximumActive, active)
        maximumInputDimension = max(maximumInputDimension, image.width, image.height)
        if started == 1 { firstStarted.fulfill() }
        let text = await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        active -= 1
        return text
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: "recognized")
    }

    func snapshot() -> Snapshot {
        Snapshot(
            started: started,
            maximumActive: maximumActive,
            maximumInputDimension: maximumInputDimension
        )
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

private func writeTestGIF(to url: URL) throws {
    var writer = try GIFWriter(
        url: url,
        maxFPS: 10,
        maxPixelSize: 1_280,
        maxDuration: 60
    )
    try writer.append(
        image: TestImage.solid(width: 24, height: 16, color: .purple),
        presentationTime: .zero
    )
    try writer.append(
        image: TestImage.solid(width: 24, height: 16, color: .orange),
        presentationTime: CMTime(seconds: 0.1, preferredTimescale: 600)
    )
    try writer.finish(stopTime: CMTime(seconds: 0.2, preferredTimescale: 600))
}

private func writeTestMP4(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 32,
            AVVideoHeightKey: 24,
        ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32,
            kCVPixelBufferHeightKey as String: 24,
        ]
    )
    writer.add(input)
    guard writer.startWriting() else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
    writer.startSession(atSourceTime: .zero)
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        nil,
        32,
        24,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw CocoaError(.fileWriteUnknown)
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(baseAddress, 0x7f, CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    guard adaptor.append(pixelBuffer, withPresentationTime: .zero),
          adaptor.append(
            pixelBuffer,
            withPresentationTime: CMTime(value: 1, timescale: 30)
          ) else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
    writer.endSession(atSourceTime: CMTime(value: 2, timescale: 30))
    input.markAsFinished()
    await withCheckedContinuation { continuation in
        writer.finishWriting { continuation.resume() }
    }
    guard writer.status == .completed else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
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
