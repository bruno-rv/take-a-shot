import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Vision

protocol OCRRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> String
}

struct VisionOCRService: OCRRecognizing {
    func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let text = (request.results as? [VNRecognizedTextObservation])?
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n") ?? ""
                    continuation.resume(returning: text)
                }
                request.recognitionLevel = .accurate
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum CaptureLibraryError: Error, Equatable {
    case duplicateCapture(UUID)
    case ownedFileAlreadyExists(String)
    case invalidOwnedFilename(String)
    case rollbackFailed(primary: String, rollback: String)
}

struct CaptureLibraryLoadIssue: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case malformedRecord
        case missingOwnedFile
        case corruptOriginal
        case corruptThumbnail
        case corruptEditedImage
        case corruptAnnotation
    }

    let recordID: UUID?
    let reason: Reason
}

struct CaptureLibraryFileOperations: @unchecked Sendable {
    let moveItem: (URL, URL) throws -> Void
    let removeItem: (URL) throws -> Void

    static let live = CaptureLibraryFileOperations(
        moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
        removeItem: { try FileManager.default.removeItem(at: $0) }
    )
}

private final class IndexMutationLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(rootURL: URL) async throws -> IndexMutationLock {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try FileManager.default.createDirectory(
                        at: rootURL,
                        withIntermediateDirectories: true
                    )
                    let lockURL = rootURL.appendingPathComponent(".index.lock")
                    var openError: Int32 = 0
                    let descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
                        guard let path else {
                            openError = EINVAL
                            return Int32(-1)
                        }
                        var descriptor: Int32
                        repeat {
                            descriptor = Darwin.open(
                                path,
                                O_CREAT | O_RDWR | O_EXLOCK | O_CLOEXEC,
                                S_IRUSR | S_IWUSR
                            )
                            if descriptor < 0 { openError = errno }
                        } while descriptor < 0 && openError == EINTR
                        return descriptor
                    }
                    guard descriptor >= 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: openError) ?? .EIO)
                    }
                    continuation.resume(returning: IndexMutationLock(descriptor: descriptor))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func release() {
        Darwin.close(descriptor)
    }
}

actor CaptureLibraryStore {
    private enum DirectoryName: String, CaseIterable {
        case originals
        case exports
        case thumbnails
        case annotations
        case temporary
    }

    private static let thumbnailMaxPixelSize = 512
    private static let ocrMaxPixelSize = 2_048

    private struct OCRJob: Sendable {
        let id: UUID
        let originalURL: URL
    }

    private let rootURL: URL
    private let ocr: any OCRRecognizing
    private let fileOperations: CaptureLibraryFileOperations
    private let didPublishCapture: @Sendable (UUID) async -> Void
    private let fileManager = FileManager.default
    private var indexedRecords: [CaptureRecord] = []
    private var visibleRecords: [CaptureRecord] = []
    private var currentLoadIssues: [CaptureLibraryLoadIssue] = []
    private var pendingOCRJobs: [OCRJob] = []
    private var ocrWorkerTask: Task<Void, Never>?
    private var changeContinuations: [UUID: AsyncStream<CaptureLibraryChange>.Continuation] = [:]

    init(
        rootURL: URL,
        ocr: any OCRRecognizing,
        fileOperations: CaptureLibraryFileOperations = .live,
        didPublishCapture: @escaping @Sendable (UUID) async -> Void = { _ in }
    ) {
        self.rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        self.ocr = ocr
        self.fileOperations = fileOperations
        self.didPublishCapture = didPublishCapture
    }

    deinit {
        ocrWorkerTask?.cancel()
    }

    func load() async throws -> [CaptureRecord] {
        let lock = try await IndexMutationLock.acquire(rootURL: rootURL)
        defer { lock.release() }
        try await reloadFromDisk()
        try await reconcileFinalizedRecordings()
        return visibleRecords
    }

    func load(matching query: String) async throws -> [CaptureRecord] {
        let lock = try await IndexMutationLock.acquire(rootURL: rootURL)
        defer { lock.release() }
        try await reloadFromDisk()
        try await reconcileFinalizedRecordings()
        return matchingRecords(query)
    }

    func loadIssues() async -> [CaptureLibraryLoadIssue] {
        currentLoadIssues
    }

    func changes() -> AsyncStream<CaptureLibraryChange> {
        let identifier = UUID()
        return AsyncStream { continuation in
            changeContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeChangeContinuation(identifier) }
            }
        }
    }

    private func reloadFromDisk() async throws {
        let indexURL = try safeRootFileURL("index.json")
        guard fileManager.fileExists(atPath: indexURL.path) else {
            indexedRecords = []
            visibleRecords = []
            currentLoadIssues = []
            return
        }

        let decoded = try decodeIndexRecords(from: Data(contentsOf: indexURL))
        let validation = validateVisibleRecords(decoded.records)
        let mediaValidation = await validateMediaRecords(validation.records)
        indexedRecords = mediaValidation.records
        visibleRecords = mediaValidation.records
        currentLoadIssues = decoded.issues + validation.issues + mediaValidation.issues
    }

    private func reconcileFinalizedRecordings() async throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try removeStaleTemporaryFragments()
        guard let originalsURL = try? safeRootFileURL(
            DirectoryName.originals.rawValue,
            isDirectory: true
        ) else { return }
        guard fileManager.fileExists(atPath: originalsURL.path) else { return }
        let candidates = try fileManager.contentsOfDirectory(
            at: originalsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let indexedIDs = Set(indexedRecords.map(\.id))
        let indexedFilenames = Set(indexedRecords.map(\.originalFilename))
        var recovered: [CaptureRecord] = []

        for candidate in candidates {
            let filename = candidate.lastPathComponent
            let fileExtension = candidate.pathExtension.lowercased()
            guard ["mp4", "gif"].contains(fileExtension),
                  let identifier = UUID(
                    uuidString: candidate.deletingPathExtension().lastPathComponent
                  ),
                  !indexedIDs.contains(identifier),
                  !indexedFilenames.contains("originals/\(filename)"),
                  !isSymbolicLink(candidate)
            else { continue }
            let media: RecordedMedia
            do {
                media = try await inspectFinalizedRecording(
                    at: candidate,
                    identifier: identifier,
                    fileExtension: fileExtension
                )
            } catch {
                let modified = try? candidate.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                if let modified, modified < Date(timeIntervalSinceNow: -86_400) {
                    try fileOperations.removeItem(candidate)
                    let thumbnailURL = try safeRootFileURL(
                        "thumbnails/\(identifier.uuidString).png"
                    )
                    if fileManager.fileExists(atPath: thumbnailURL.path) {
                        try fileOperations.removeItem(thumbnailURL)
                    }
                }
                continue
            }
            let thumbnailFilename = "thumbnails/\(identifier.uuidString).png"
            let thumbnailsURL = try safeRootFileURL(
                DirectoryName.thumbnails.rawValue,
                isDirectory: true
            )
            try fileManager.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
            let thumbnailURL = try ownedFileURL(
                for: thumbnailFilename,
                role: .thumbnail,
                recordID: identifier
            )
            let thumbnail = try ImageExporter.thumbnail(
                for: media.thumbnail,
                maxPixelSize: Self.thumbnailMaxPixelSize
            )
            try ImageExporter.write(try ImageExporter.pngData(for: thumbnail), to: thumbnailURL)
            recovered.append(CaptureRecord(
                id: identifier,
                kind: media.kind,
                title: media.title,
                createdAt: media.createdAt,
                lastEditedAt: media.createdAt,
                pixelSize: media.pixelSize,
                duration: media.duration,
                originalFilename: "originals/\(filename)",
                editedFilename: nil,
                thumbnailFilename: thumbnailFilename,
                annotationFilename: nil,
                ocrText: "",
                tags: []
            ))
        }

        guard !recovered.isEmpty else { return }
        let updatedRecords = indexedRecords + recovered
        try publish(updatedRecords)
        indexedRecords = updatedRecords
        visibleRecords = validatedVisibleRecords(updatedRecords)
    }

    private func inspectFinalizedRecording(
        at url: URL,
        identifier: UUID,
        fileExtension: String
    ) async throws -> RecordedMedia {
        let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
        if fileExtension == "gif" {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetCount(source) > 0,
                  let thumbnail = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw CocoaError(.fileReadCorruptFile) }
            var duration: TimeInterval = 0
            for index in 0..<CGImageSourceGetCount(source) {
                guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                duration += gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                    ?? gif?[kCGImagePropertyGIFDelayTime] as? Double
                    ?? 0.1
            }
            guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
            return RecordedMedia(
                id: identifier,
                kind: .gif,
                title: url.lastPathComponent,
                createdAt: createdAt,
                pixelSize: PixelSize(width: thumbnail.width, height: thumbnail.height),
                duration: duration,
                originalURL: url,
                thumbnail: thumbnail
            )
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.isValid,
              duration.seconds.isFinite,
              duration.seconds > 0,
              let track = try await asset.loadTracks(withMediaType: .video).first
        else { throw CocoaError(.fileReadCorruptFile) }
        let size = try await track.load(.naturalSize)
        let transformed = size.applying(try await track.load(.preferredTransform))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let thumbnail = try generator.copyCGImage(at: .zero, actualTime: nil)
        return RecordedMedia(
            id: identifier,
            kind: .video,
            title: url.lastPathComponent,
            createdAt: createdAt,
            pixelSize: PixelSize(
                width: Int(abs(transformed.width).rounded()),
                height: Int(abs(transformed.height).rounded())
            ),
            duration: duration.seconds,
            originalURL: url,
            thumbnail: thumbnail
        )
    }

    private func removeStaleTemporaryFragments() throws {
        guard let temporaryURL = try? safeRootFileURL(
            DirectoryName.temporary.rawValue,
            isDirectory: true
        ) else { return }
        guard fileManager.fileExists(atPath: temporaryURL.path) else { return }
        let cutoff = Date(timeIntervalSinceNow: -86_400)
        for item in try fileManager.contentsOfDirectory(
            at: temporaryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            guard !isSymbolicLink(item),
                  let modified = try? item.resourceValues(
                    forKeys: [.contentModificationDateKey]
                  ).contentModificationDate,
                  modified < cutoff else { continue }
            try fileOperations.removeItem(item)
        }
    }

    func persist(
        image: CapturedImage,
        annotations: AnnotationDocument? = nil
    ) async throws -> CaptureRecord {
        let identifier = image.id.uuidString
        let originalFilename = "originals/\(identifier).png"
        let thumbnailFilename = "thumbnails/\(identifier).png"
        let storedAnnotations = annotations.flatMap { $0.isEmpty ? nil : $0 }
        guard storedAnnotations?.captureID == nil || storedAnnotations?.captureID == image.id else {
            throw CaptureLibraryError.invalidOwnedFilename("Annotation capture identifier does not match.")
        }
        let annotationFilename = storedAnnotations.map { _ in "annotations/\(identifier).json" }
        let originalURL = try ownedFileURL(
            for: originalFilename,
            role: .original(image.kind),
            recordID: image.id
        )
        let thumbnailURL = try ownedFileURL(
            for: thumbnailFilename,
            role: .thumbnail,
            recordID: image.id
        )
        let annotationURL = try annotationFilename.map {
            try ownedFileURL(for: $0, role: .annotation, recordID: image.id)
        }
        var assetDestinations: [(filename: String, url: URL)] = [
            (originalFilename, originalURL),
            (thumbnailFilename, thumbnailURL),
        ]
        if let annotationFilename, let annotationURL {
            assetDestinations.append((annotationFilename, annotationURL))
        }
        let originalData = try ImageExporter.pngData(for: image.image)
        let thumbnail = try ImageExporter.thumbnail(
            for: image.image,
            maxPixelSize: Self.thumbnailMaxPixelSize
        )
        let thumbnailData = try ImageExporter.pngData(for: thumbnail)
        let annotationData = try storedAnnotations.map { try JSONEncoder().encode($0) }
        let lock = try await IndexMutationLock.acquire(rootURL: rootURL)
        defer { lock.release() }

        try await reloadFromDisk()
        guard !indexedRecords.contains(where: { $0.id == image.id }) else {
            throw CaptureLibraryError.duplicateCapture(image.id)
        }
        try createStorageDirectories()
        for (filename, url) in assetDestinations where fileManager.fileExists(atPath: url.path) {
            throw CaptureLibraryError.ownedFileAlreadyExists(filename)
        }

        let previousRecords = indexedRecords
        var didPublish = false
        do {
            try ImageExporter.write(originalData, to: originalURL)
            try ImageExporter.write(thumbnailData, to: thumbnailURL)
            if let annotationData, let annotationURL {
                try ImageExporter.write(annotationData, to: annotationURL)
            }

            let record = CaptureRecord(
                id: image.id,
                kind: image.kind,
                title: image.title,
                createdAt: image.createdAt,
                lastEditedAt: image.createdAt,
                pixelSize: image.pixelSize,
                duration: nil,
                originalFilename: originalFilename,
                editedFilename: nil,
                thumbnailFilename: thumbnailFilename,
                annotationFilename: annotationFilename,
                ocrText: "",
                tags: []
            )
            let updatedRecords = indexedRecords + [record]
            try Task.checkCancellation()
            try publish(updatedRecords)
            didPublish = true
            indexedRecords = updatedRecords
            visibleRecords = validatedVisibleRecords(updatedRecords)
            await didPublishCapture(image.id)
            publishChange(.imageOrAnnotationsChanged(image.id))
            try Task.checkCancellation()
            scheduleOCR(id: image.id, originalURL: originalURL)
            return record
        } catch let persistenceError {
            if didPublish {
                try rollbackPublishedCapture(
                    previousRecords: previousRecords,
                    assetURLs: assetDestinations.map(\.url),
                    after: persistenceError
                )
            }
            do {
                try removeFiles(at: assetDestinations.map(\.url), usingInjectedOperations: true)
            } catch let rollbackError {
                throw CaptureLibraryError.rollbackFailed(
                    primary: persistenceError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw persistenceError
        }
    }

    private func rollbackPublishedCapture(
        previousRecords: [CaptureRecord],
        assetURLs: [URL],
        after primaryError: Error
    ) throws -> Never {
        var rollbackErrors: [Error] = []
        do {
            try publish(previousRecords)
            indexedRecords = previousRecords
            visibleRecords = validatedVisibleRecords(previousRecords)
        } catch {
            rollbackErrors.append(error)
        }
        do {
            try removeFiles(at: assetURLs, usingInjectedOperations: true)
        } catch {
            rollbackErrors.append(error)
        }
        if let rollbackError = rollbackErrors.first {
            throw CaptureLibraryError.rollbackFailed(
                primary: primaryError.localizedDescription,
                rollback: rollbackError.localizedDescription
            )
        }
        throw primaryError
    }

    func register(media: RecordedMedia) async throws -> CaptureRecord {
        guard media.kind == .video || media.kind == .gif else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let identifier = media.id.uuidString
        let fileExtension = media.kind == .video ? "mp4" : "gif"
        let originalFilename = "originals/\(identifier).\(fileExtension)"
        let originalURL = try ownedFileURL(
            for: originalFilename,
            role: .original(media.kind),
            recordID: media.id
        )
        guard originalURL.resolvingSymlinksInPath().standardizedFileURL
            == media.originalURL.resolvingSymlinksInPath().standardizedFileURL
        else {
            throw CaptureLibraryError.invalidOwnedFilename(media.originalURL.path)
        }
        let thumbnailFilename = "thumbnails/\(identifier).png"
        let thumbnailURL = try ownedFileURL(
            for: thumbnailFilename,
            role: .thumbnail,
            recordID: media.id
        )
        let thumbnail = try ImageExporter.thumbnail(
            for: media.thumbnail,
            maxPixelSize: Self.thumbnailMaxPixelSize
        )
        let thumbnailData = try ImageExporter.pngData(for: thumbnail)
        let lock = try await IndexMutationLock.acquire(rootURL: rootURL)
        defer { lock.release() }

        try await reloadFromDisk()
        guard !indexedRecords.contains(where: { $0.id == media.id }) else {
            throw CaptureLibraryError.duplicateCapture(media.id)
        }
        guard !indexedRecords.contains(where: { $0.originalFilename == originalFilename }) else {
            throw CaptureLibraryError.ownedFileAlreadyExists(originalFilename)
        }
        guard fileManager.fileExists(atPath: originalURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try createStorageDirectories()
        guard !fileManager.fileExists(atPath: thumbnailURL.path) else {
            throw CaptureLibraryError.ownedFileAlreadyExists(thumbnailFilename)
        }

        do {
            try ImageExporter.write(thumbnailData, to: thumbnailURL)
            let record = CaptureRecord(
                id: media.id,
                kind: media.kind,
                title: media.title,
                createdAt: media.createdAt,
                lastEditedAt: media.createdAt,
                pixelSize: media.pixelSize,
                duration: media.duration,
                originalFilename: originalFilename,
                editedFilename: nil,
                thumbnailFilename: thumbnailFilename,
                annotationFilename: nil,
                ocrText: "",
                tags: []
            )
            let updatedRecords = indexedRecords + [record]
            try publish(updatedRecords)
            indexedRecords = updatedRecords
            visibleRecords = validatedVisibleRecords(updatedRecords)
            return record
        } catch let registrationError {
            do {
                if fileManager.fileExists(atPath: thumbnailURL.path) {
                    try fileOperations.removeItem(thumbnailURL)
                }
            } catch let rollbackError {
                throw CaptureLibraryError.rollbackFailed(
                    primary: registrationError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw registrationError
        }
    }

    func search(_ query: String) -> [CaptureRecord] {
        matchingRecords(query)
    }

    private func matchingRecords(_ query: String) -> [CaptureRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return visibleRecords }
        let foldedQuery = searchKey(trimmedQuery)

        return visibleRecords.filter { record in
            searchKey(record.title).contains(foldedQuery)
                || searchKey(record.kind.rawValue).contains(foldedQuery)
                || searchKey(record.ocrText).contains(foldedQuery)
                || record.tags.contains {
                    searchKey($0).contains(foldedQuery)
                }
        }
    }

    func updateTags(id: UUID, tags: [String]) async throws {
        let lock = try await IndexMutationLock.acquire(rootURL: rootURL)
        defer { lock.release() }
        try await reloadFromDisk()
        guard visibleRecords.contains(where: { $0.id == id }),
              let index = indexedRecords.firstIndex(where: { $0.id == id }) else { return }
        var updatedRecords = indexedRecords
        updatedRecords[index].tags = tags
        updatedRecords[index].lastEditedAt = .now
        try publish(updatedRecords)
        indexedRecords = updatedRecords
        visibleRecords = validatedVisibleRecords(updatedRecords)
        publishChange(.metadataChanged(id))
    }

    func saveAnnotations(
        _ document: AnnotationDocument,
        for id: UUID,
        editedAt: Date = .now
    ) async throws {
        guard document.captureID == id else {
            throw CaptureLibraryError.invalidOwnedFilename("Annotation capture identifier does not match.")
        }
        let lock = try await IndexMutationLock.acquire(rootURL: rootURL)
        defer { lock.release() }
        try await reloadFromDisk()
        guard let visibleRecord = visibleRecords.first(where: { $0.id == id }),
              ![CaptureKind.video, .gif].contains(visibleRecord.kind),
              let index = indexedRecords.firstIndex(where: { $0.id == id })
        else { throw CocoaError(.fileNoSuchFile) }

        try createStorageDirectories()
        let filename = "annotations/\(id.uuidString).json"
        let destination = try ownedFileURL(
            for: filename,
            role: .annotation,
            recordID: id
        )
        if document.isEmpty {
            guard visibleRecord.annotationFilename != nil else { return }
            try removeAnnotationsTransactionally(
                destination: destination,
                recordIndex: index,
                editedAt: editedAt
            )
            publishChange(.imageOrAnnotationsChanged(id))
            return
        }
        if visibleRecord.annotationFilename == filename,
           let storedData = try? Data(contentsOf: destination),
           let storedDocument = try? JSONDecoder().decode(
               AnnotationDocument.self,
               from: storedData
           ),
           storedDocument == document {
            return
        }

        let transactionID = UUID().uuidString
        let temporaryURL = try safeTemporaryURL("annotation-\(transactionID).json")
        let backupURL = try safeTemporaryURL("annotation-\(transactionID).backup")
        try ImageExporter.write(try JSONEncoder().encode(document), to: temporaryURL)
        var movedOldDocument = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileOperations.moveItem(destination, backupURL)
                movedOldDocument = true
            }
            try fileOperations.moveItem(temporaryURL, destination)
            var updatedRecords = indexedRecords
            updatedRecords[index].annotationFilename = filename
            updatedRecords[index].lastEditedAt = editedAt
            try publish(updatedRecords)
            indexedRecords = updatedRecords
            visibleRecords = validatedVisibleRecords(updatedRecords)
            if movedOldDocument { try fileOperations.removeItem(backupURL) }
            publishChange(.imageOrAnnotationsChanged(id))
        } catch let primaryError {
            var rollbackErrors: [Error] = []
            if fileManager.fileExists(atPath: destination.path) {
                do { try fileOperations.removeItem(destination) } catch { rollbackErrors.append(error) }
            }
            if movedOldDocument, fileManager.fileExists(atPath: backupURL.path) {
                do { try fileOperations.moveItem(backupURL, destination) } catch { rollbackErrors.append(error) }
            }
            if fileManager.fileExists(atPath: temporaryURL.path) {
                do { try fileOperations.removeItem(temporaryURL) } catch { rollbackErrors.append(error) }
            }
            if let rollbackError = rollbackErrors.first {
                throw CaptureLibraryError.rollbackFailed(
                    primary: primaryError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw primaryError
        }
    }

    func loadAnnotations(for id: UUID) async throws -> AnnotationDocument {
        try await reloadFromDisk()
        guard let record = visibleRecords.first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard let filename = record.annotationFilename else {
            return AnnotationDocument(captureID: id)
        }
        let url = try ownedFileURL(for: filename, role: .annotation, recordID: id)
        let document = try JSONDecoder().decode(
            AnnotationDocument.self,
            from: Data(contentsOf: url)
        )
        guard document.captureID == id else {
            throw CaptureLibraryError.invalidOwnedFilename(filename)
        }
        return document
    }

    func delete(id: UUID) async throws {
        let lock = try await IndexMutationLock.acquire(rootURL: rootURL)
        defer { lock.release() }
        try await reloadFromDisk()
        guard let record = visibleRecords.first(where: { $0.id == id }),
              let index = indexedRecords.firstIndex(where: { $0.id == id }) else { return }
        let ownedURLs = try ownedFiles(for: record)
        try createStorageDirectories()
        let stagingDirectory = try safeTemporaryURL(
            "deletions/\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var staged: [(source: URL, destination: URL)] = []
        do {
            for (offset, source) in ownedURLs.enumerated()
                where fileManager.fileExists(atPath: source.path) {
                let destination = stagingDirectory.appendingPathComponent(
                    "\(offset)-\(source.lastPathComponent)"
                )
                try fileOperations.moveItem(source, destination)
                staged.append((source, destination))
            }
        } catch let primaryError {
            try restore(staged, after: primaryError)
        }
        var updatedRecords = indexedRecords
        updatedRecords.remove(at: index)
        do {
            try publish(updatedRecords)
        } catch let primaryError {
            try restore(staged, after: primaryError)
        }
        indexedRecords = updatedRecords
        visibleRecords = validatedVisibleRecords(updatedRecords)
        publishChange(.deleted(id))
        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try fileOperations.removeItem(stagingDirectory)
        }
    }

    func rollbackPersistedImageCapture(id: UUID) async throws {
        let lock = try await IndexMutationLock.acquire(rootURL: rootURL)
        defer { lock.release() }

        let identifier = id.uuidString
        let assetURLs = try [
            ownedFileURL(
                for: "originals/\(identifier).png",
                role: .original(.display),
                recordID: id
            ),
            ownedFileURL(
                for: "thumbnails/\(identifier).png",
                role: .thumbnail,
                recordID: id
            ),
            ownedFileURL(
                for: "annotations/\(identifier).json",
                role: .annotation,
                recordID: id
            ),
        ]
        var rollbackErrors: [Error] = []

        do {
            let indexURL = try safeRootFileURL("index.json")
            if fileManager.fileExists(atPath: indexURL.path) {
                let records = try decodeIndexRecords(from: Data(contentsOf: indexURL)).records
                let updatedRecords = records.filter { $0.id != id }
                if updatedRecords.count != records.count {
                    try publish(updatedRecords)
                    indexedRecords = updatedRecords
                    visibleRecords = validatedVisibleRecords(updatedRecords)
                }
            }
        } catch {
            rollbackErrors.append(error)
        }

        do {
            try removeFiles(at: assetURLs, usingInjectedOperations: true)
        } catch {
            rollbackErrors.append(error)
        }

        if let rollbackError = rollbackErrors.first {
            throw CaptureLibraryError.rollbackFailed(
                primary: CancellationError().localizedDescription,
                rollback: rollbackError.localizedDescription
            )
        }
    }

    func originalURL(for id: UUID) throws -> URL {
        guard let record = visibleRecords.first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ownedFileURL(
            for: record.originalFilename,
            role: .original(record.kind),
            recordID: record.id
        )
    }

    func thumbnailURL(for id: UUID) throws -> URL {
        guard let record = visibleRecords.first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ownedFileURL(
            for: record.thumbnailFilename,
            role: .thumbnail,
            recordID: record.id
        )
    }

    func loadCapture(id: UUID) throws -> CapturedImage {
        guard let record = visibleRecords.first(where: { $0.id == id }),
              ![CaptureKind.video, .gif].contains(record.kind)
        else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let url = try ownedFileURL(
            for: record.originalFilename,
            role: .original(record.kind),
            recordID: record.id
        )
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return CapturedImage(
            id: record.id,
            kind: record.kind,
            title: record.title,
            createdAt: record.createdAt,
            image: image,
            pixelSize: record.pixelSize
        )
    }

    private func createStorageDirectories() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        for directory in DirectoryName.allCases {
            let url = try safeRootFileURL(directory.rawValue, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func publish(_ records: [CaptureRecord]) throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(records)
        let indexURL = try safeRootFileURL("index.json")
        let temporaryURL = try safeRootFileURL("index.json.\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL)
        var renameError: Int32 = 0
        let result = temporaryURL.withUnsafeFileSystemRepresentation { temporaryPath in
            indexURL.withUnsafeFileSystemRepresentation { indexPath in
                guard let temporaryPath, let indexPath else { return Int32(-1) }
                let result = Darwin.rename(temporaryPath, indexPath)
                if result != 0 { renameError = errno }
                return result
            }
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: renameError) ?? .EIO)
        }
    }

    private func hasAllOwnedFiles(_ record: CaptureRecord) -> Bool {
        guard let urls = try? ownedFiles(for: record) else { return false }
        return urls.allSatisfy { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    private func validatedVisibleRecords(_ records: [CaptureRecord]) -> [CaptureRecord] {
        validateVisibleRecords(records).records
    }

    private func validateVisibleRecords(
        _ records: [CaptureRecord]
    ) -> (records: [CaptureRecord], issues: [CaptureLibraryLoadIssue]) {
        var seenIDs: Set<UUID> = []
        var seenPaths: Set<String> = []
        var valid: [CaptureRecord] = []
        var issues: [CaptureLibraryLoadIssue] = []
        for record in records {
            guard !seenIDs.contains(record.id),
                  let paths = try? ownedFiles(for: record).map(\.path),
                  paths.allSatisfy({ !seenPaths.contains($0) })
            else {
                issues.append(CaptureLibraryLoadIssue(
                    recordID: record.id,
                    reason: .missingOwnedFile
                ))
                continue
            }
            guard hasAllOwnedFiles(record) else {
                issues.append(CaptureLibraryLoadIssue(
                    recordID: record.id,
                    reason: .missingOwnedFile
                ))
                continue
            }
            if let reason = corruptOwnedFileReason(for: record) {
                issues.append(CaptureLibraryLoadIssue(recordID: record.id, reason: reason))
                continue
            }
            seenIDs.insert(record.id)
            seenPaths.formUnion(paths)
            valid.append(record)
        }
        return (valid, issues)
    }

    private func corruptOwnedFileReason(
        for record: CaptureRecord
    ) -> CaptureLibraryLoadIssue.Reason? {
        guard let originalURL = try? ownedFileURL(
            for: record.originalFilename,
            role: .original(record.kind),
            recordID: record.id
        ) else { return .missingOwnedFile }
        if ![CaptureKind.video, .gif].contains(record.kind),
           !isDecodableImage(at: originalURL) {
            return .corruptOriginal
        }
        guard let thumbnailURL = try? ownedFileURL(
            for: record.thumbnailFilename,
            role: .thumbnail,
            recordID: record.id
        ), isDecodableImage(at: thumbnailURL) else {
            return .corruptThumbnail
        }
        if let editedFilename = record.editedFilename {
            guard let editedURL = try? ownedFileURL(
                for: editedFilename,
                role: .edited,
                recordID: record.id
            ), isDecodableImage(at: editedURL) else {
                return .corruptEditedImage
            }
        }
        if let annotationFilename = record.annotationFilename {
            guard let annotationURL = try? ownedFileURL(
                for: annotationFilename,
                role: .annotation,
                recordID: record.id
            ), let data = try? Data(contentsOf: annotationURL),
                  let document = try? JSONDecoder().decode(AnnotationDocument.self, from: data),
                  document.captureID == record.id else {
                return .corruptAnnotation
            }
        }
        return nil
    }

    private func isDecodableImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary
              ) else { return false }
        return image.width > 0 && image.height > 0
    }

    private func validateMediaRecords(
        _ records: [CaptureRecord]
    ) async -> (records: [CaptureRecord], issues: [CaptureLibraryLoadIssue]) {
        var valid: [CaptureRecord] = []
        var issues: [CaptureLibraryLoadIssue] = []
        for record in records {
            guard [CaptureKind.video, .gif].contains(record.kind) else {
                valid.append(record)
                continue
            }
            guard let url = try? ownedFileURL(
                for: record.originalFilename,
                role: .original(record.kind),
                recordID: record.id
            ), await isDecodableMedia(at: url, kind: record.kind) else {
                issues.append(CaptureLibraryLoadIssue(
                    recordID: record.id,
                    reason: .corruptOriginal
                ))
                continue
            }
            valid.append(record)
        }
        return (valid, issues)
    }

    private func isDecodableMedia(at url: URL, kind: CaptureKind) async -> Bool {
        if kind == .gif {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 64,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary
                  ) != nil else { return false }
            return (0..<CGImageSourceGetCount(source)).allSatisfy {
                CGImageSourceGetStatusAtIndex(source, $0) == .statusComplete
            }
        }

        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.isValid,
                  duration.seconds.isFinite,
                  duration.seconds > 0,
                  let track = try await asset.loadTracks(withMediaType: .video).first
            else { return false }
            _ = try await track.load(.naturalSize)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 64, height: 64)
            _ = try generator.copyCGImage(at: .zero, actualTime: nil)
            return true
        } catch {
            return false
        }
    }

    private func decodeIndexRecords(
        from data: Data
    ) throws -> (records: [CaptureRecord], issues: [CaptureLibraryLoadIssue]) {
        let bytes = Array(data)
        let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
        guard let first = bytes.firstIndex(where: { !whitespace.contains($0) }),
              let last = bytes.lastIndex(where: { !whitespace.contains($0) }),
              bytes[first] == 0x5B,
              bytes[last] == 0x5D else {
            throw CocoaError(.coderReadCorrupt)
        }
        guard first + 1 < last else { return ([], []) }
        let decoder = JSONDecoder()
        if let records = try? decoder.decode([CaptureRecord].self, from: data) {
            return (records, [])
        }

        struct Candidate {
            let range: Range<Int>
        }
        var candidates: [Candidate] = []
        for start in (first + 1)..<last where bytes[start] == 0x7B {
            var depth = 0
            var inString = false
            var escaped = false
            var index = start
            while index < last {
                let byte = bytes[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        inString = false
                    }
                } else if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B {
                    depth += 1
                } else if byte == 0x7D {
                    depth -= 1
                    if depth == 0 {
                        candidates.append(Candidate(range: start..<(index + 1)))
                        break
                    }
                }
                index += 1
            }
        }

        let topLevelCandidates = candidates.filter { candidate in
            !candidates.contains { container in
                container.range.lowerBound < candidate.range.lowerBound
                    && container.range.upperBound >= candidate.range.upperBound
            }
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        let records = topLevelCandidates.compactMap { candidate in
            try? decoder.decode(
                CaptureRecord.self,
                from: Data(bytes[candidate.range])
            )
        }
        return (
            records,
            [CaptureLibraryLoadIssue(recordID: nil, reason: .malformedRecord)]
        )
    }

    private func searchKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func ownedFiles(for record: CaptureRecord) throws -> [URL] {
        var urls = [
            try ownedFileURL(
                for: record.originalFilename,
                role: .original(record.kind),
                recordID: record.id
            ),
            try ownedFileURL(
                for: record.thumbnailFilename,
                role: .thumbnail,
                recordID: record.id
            ),
        ]
        if let editedFilename = record.editedFilename {
            urls.append(try ownedFileURL(
                for: editedFilename,
                role: .edited,
                recordID: record.id
            ))
        }
        if let annotationFilename = record.annotationFilename {
            urls.append(try ownedFileURL(
                for: annotationFilename,
                role: .annotation,
                recordID: record.id
            ))
        }
        return urls
    }

    private func removeFiles(
        at urls: [URL],
        usingInjectedOperations: Bool = false
    ) throws {
        var firstError: Error?
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                if usingInjectedOperations {
                    try fileOperations.removeItem(url)
                } else {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private enum OwnedFileRole {
        case original(CaptureKind)
        case edited
        case thumbnail
        case annotation
    }

    private func ownedFileURL(
        for relativeFilename: String,
        role: OwnedFileRole,
        recordID: UUID
    ) throws -> URL {
        let components = relativeFilename.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        let expectedDirectory: String
        let allowedExtensions: Set<String>
        switch role {
        case .original(let kind):
            expectedDirectory = DirectoryName.originals.rawValue
            switch kind {
            case .video: allowedExtensions = ["mp4"]
            case .gif: allowedExtensions = ["gif"]
            default: allowedExtensions = ["png"]
            }
        case .edited:
            expectedDirectory = DirectoryName.exports.rawValue
            allowedExtensions = ["png", "jpg", "jpeg"]
        case .thumbnail:
            expectedDirectory = DirectoryName.thumbnails.rawValue
            allowedExtensions = ["png"]
        case .annotation:
            expectedDirectory = DirectoryName.annotations.rawValue
            allowedExtensions = ["json"]
        }
        let filename = components.count == 2 ? components[1] : ""
        let fileURL = URL(fileURLWithPath: filename)
        guard components.count == 2,
              components[0] == expectedDirectory,
              fileURL.deletingPathExtension().lastPathComponent == recordID.uuidString,
              allowedExtensions.contains(fileURL.pathExtension.lowercased())
        else {
            throw CaptureLibraryError.invalidOwnedFilename(relativeFilename)
        }
        return try safeRootFileURL(relativeFilename)
    }

    private func safeRootFileURL(
        _ relativePath: String,
        isDirectory: Bool = false
    ) throws -> URL {
        guard !relativePath.isEmpty,
              !(relativePath as NSString).isAbsolutePath,
              !relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw CaptureLibraryError.invalidOwnedFilename(relativePath) }
        let candidate = rootURL.appendingPathComponent(relativePath, isDirectory: isDirectory)
            .standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidate.path.hasPrefix(prefix) else {
            throw CaptureLibraryError.invalidOwnedFilename(relativePath)
        }
        var componentURL = rootURL
        for component in relativePath.split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            if isSymbolicLink(componentURL) {
                throw CaptureLibraryError.invalidOwnedFilename(relativePath)
            }
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(prefix) else {
            throw CaptureLibraryError.invalidOwnedFilename(relativePath)
        }
        return candidate
    }

    private func safeTemporaryURL(
        _ relativePath: String,
        isDirectory: Bool = false
    ) throws -> URL {
        try safeRootFileURL(
            "\(DirectoryName.temporary.rawValue)/\(relativePath)",
            isDirectory: isDirectory
        )
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        var information = stat()
        let result = url.path.withCString { Darwin.lstat($0, &information) }
        return result == 0 && (information.st_mode & S_IFMT) == S_IFLNK
    }

    private func restore(
        _ staged: [(source: URL, destination: URL)],
        after primaryError: Error
    ) throws -> Never {
        var rollbackError: Error?
        for entry in staged.reversed() where fileManager.fileExists(atPath: entry.destination.path) {
            do { try fileOperations.moveItem(entry.destination, entry.source) }
            catch { if rollbackError == nil { rollbackError = error } }
        }
        if let rollbackError {
            throw CaptureLibraryError.rollbackFailed(
                primary: primaryError.localizedDescription,
                rollback: rollbackError.localizedDescription
            )
        }
        throw primaryError
    }

    private func removeAnnotationsTransactionally(
        destination: URL,
        recordIndex: Int,
        editedAt: Date
    ) throws {
        let stagedURL = try safeTemporaryURL("annotation-reset-\(UUID().uuidString).json")
        do {
            try fileOperations.moveItem(destination, stagedURL)
            var updatedRecords = indexedRecords
            updatedRecords[recordIndex].annotationFilename = nil
            updatedRecords[recordIndex].lastEditedAt = editedAt
            do {
                try publish(updatedRecords)
            } catch let primaryError {
                do { try fileOperations.moveItem(stagedURL, destination) }
                catch let rollbackError {
                    throw CaptureLibraryError.rollbackFailed(
                        primary: primaryError.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    )
                }
                throw primaryError
            }
            indexedRecords = updatedRecords
            visibleRecords = validatedVisibleRecords(updatedRecords)
            try fileOperations.removeItem(stagedURL)
        } catch {
            throw error
        }
    }

    private func scheduleOCR(id: UUID, originalURL: URL) {
        pendingOCRJobs.append(OCRJob(id: id, originalURL: originalURL))
        guard ocrWorkerTask == nil else { return }
        startOCRWorker()
    }

    private func startOCRWorker() {
        ocrWorkerTask = Task { [weak self] in
            await self?.runOCRWorker()
        }
    }

    func cancelPendingOCR() {
        pendingOCRJobs.removeAll()
        ocrWorkerTask?.cancel()
    }

    private func runOCRWorker() async {
        defer { finishOCRWorker() }
        while !Task.isCancelled, !pendingOCRJobs.isEmpty {
            let job = pendingOCRJobs.removeFirst()
            do {
                let image = try makeOCRImage(at: job.originalURL)
                let text = try await ocr.recognizeText(in: image)
                try Task.checkCancellation()
                try await updateOCR(text, for: job.id)
            } catch {
                continue
            }
        }
    }

    private func finishOCRWorker() {
        ocrWorkerTask = nil
        if !pendingOCRJobs.isEmpty {
            startOCRWorker()
        }
    }

    private func makeOCRImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Self.ocrMaxPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return image
    }

    private func updateOCR(_ text: String, for id: UUID) async throws {
        let lock = try await IndexMutationLock.acquire(rootURL: rootURL)
        defer { lock.release() }
        try await reloadFromDisk()
        guard visibleRecords.contains(where: { $0.id == id }),
              let index = indexedRecords.firstIndex(where: { $0.id == id }) else { return }
        var updatedRecords = indexedRecords
        updatedRecords[index].ocrText = text
        try publish(updatedRecords)
        indexedRecords = updatedRecords
        visibleRecords = validatedVisibleRecords(updatedRecords)
        publishChange(.metadataChanged(id))
    }

    private func publishChange(_ change: CaptureLibraryChange) {
        changeContinuations.values.forEach { $0.yield(change) }
    }

    private func removeChangeContinuation(_ identifier: UUID) {
        changeContinuations.removeValue(forKey: identifier)
    }
}

private extension AnnotationDocument {
    var isEmpty: Bool { items.isEmpty && cropRect == nil }
}
