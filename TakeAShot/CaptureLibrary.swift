import CoreGraphics
import Darwin
import Foundation
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
}

actor CaptureLibraryStore {
    private enum DirectoryName: String, CaseIterable {
        case originals
        case exports
        case thumbnails
        case annotations
        case temporary
    }

    private static let thumbnailMaxPixelSize = 320

    private let rootURL: URL
    private let ocr: any OCRRecognizing
    private let fileManager = FileManager.default
    private var indexedRecords: [CaptureRecord] = []
    private var visibleRecords: [CaptureRecord] = []
    private var isHydrated = false

    init(rootURL: URL, ocr: any OCRRecognizing) {
        self.rootURL = rootURL
        self.ocr = ocr
    }

    func load() throws -> [CaptureRecord] {
        let indexURL = rootURL.appendingPathComponent("index.json")
        guard fileManager.fileExists(atPath: indexURL.path) else {
            indexedRecords = []
            visibleRecords = []
            isHydrated = true
            return visibleRecords
        }

        let decodedRecords = try JSONDecoder().decode(
            [CaptureRecord].self,
            from: Data(contentsOf: indexURL)
        )
        indexedRecords = decodedRecords
        visibleRecords = decodedRecords.filter(hasAllOwnedFiles)
        isHydrated = true
        return visibleRecords
    }

    func persist(
        image: CapturedImage,
        annotations: AnnotationDocument? = nil
    ) async throws -> CaptureRecord {
        let ocrText = try await ocr.recognizeText(in: image.image)
        try hydrateIfNeeded()

        let identifier = image.id.uuidString
        let originalFilename = "originals/\(identifier).png"
        let thumbnailFilename = "thumbnails/\(identifier).png"
        let annotationFilename = annotations.map { _ in "annotations/\(identifier).json" }
        guard !indexedRecords.contains(where: { $0.id == image.id }) else {
            throw CaptureLibraryError.duplicateCapture(image.id)
        }

        try createStorageDirectories()
        let originalURL = try ownedFileURL(for: originalFilename)
        let thumbnailURL = try ownedFileURL(for: thumbnailFilename)
        let annotationURL = try annotationFilename.map(ownedFileURL)
        var assetDestinations: [(filename: String, url: URL)] = [
            (originalFilename, originalURL),
            (thumbnailFilename, thumbnailURL),
        ]
        if let annotationFilename, let annotationURL {
            assetDestinations.append((annotationFilename, annotationURL))
        }
        for (filename, url) in assetDestinations where fileManager.fileExists(atPath: url.path) {
            throw CaptureLibraryError.ownedFileAlreadyExists(filename)
        }

        let originalData = try ImageExporter.pngData(for: image.image)
        let thumbnail = try ImageExporter.thumbnail(
            for: image.image,
            maxPixelSize: Self.thumbnailMaxPixelSize
        )
        let thumbnailData = try ImageExporter.pngData(for: thumbnail)
        let annotationData = try annotations.map { try JSONEncoder().encode($0) }

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
                ocrText: ocrText,
                tags: []
            )
            let updatedRecords = indexedRecords + [record]
            try publish(updatedRecords)
            indexedRecords = updatedRecords
            visibleRecords = updatedRecords.filter(hasAllOwnedFiles)
            return record
        } catch let persistenceError {
            do {
                try removeFiles(at: assetDestinations.map(\.url))
            } catch {
                throw error
            }
            throw persistenceError
        }
    }

    func search(_ query: String) -> [CaptureRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return visibleRecords }

        return visibleRecords.filter { record in
            record.title.localizedCaseInsensitiveContains(trimmedQuery)
                || record.ocrText.localizedCaseInsensitiveContains(trimmedQuery)
                || record.tags.contains {
                    $0.localizedCaseInsensitiveContains(trimmedQuery)
                }
        }
    }

    func updateTags(id: UUID, tags: [String]) throws {
        try hydrateIfNeeded()
        guard let index = indexedRecords.firstIndex(where: { $0.id == id }) else { return }
        var updatedRecords = indexedRecords
        updatedRecords[index].tags = tags
        updatedRecords[index].lastEditedAt = .now
        try publish(updatedRecords)
        indexedRecords = updatedRecords
        visibleRecords = updatedRecords.filter(hasAllOwnedFiles)
    }

    func delete(id: UUID) throws {
        try hydrateIfNeeded()
        guard let index = indexedRecords.firstIndex(where: { $0.id == id }) else { return }
        let record = indexedRecords[index]
        let ownedURLs = try ownedFilenames(for: record).map(ownedFileURL)
        try removeFiles(at: ownedURLs)

        var updatedRecords = indexedRecords
        updatedRecords.remove(at: index)
        try publish(updatedRecords)
        indexedRecords = updatedRecords
        visibleRecords = updatedRecords.filter(hasAllOwnedFiles)
    }

    private func hydrateIfNeeded() throws {
        if !isHydrated {
            _ = try load()
        }
    }

    private func createStorageDirectories() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        for directory in DirectoryName.allCases {
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(directory.rawValue, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func publish(_ records: [CaptureRecord]) throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(records)
        let indexURL = rootURL.appendingPathComponent("index.json")
        let temporaryURL = rootURL.appendingPathComponent("index.json.tmp")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
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
        ownedFilenames(for: record).allSatisfy { filename in
            guard let url = try? ownedFileURL(for: filename) else { return false }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    private func ownedFilenames(for record: CaptureRecord) -> [String] {
        [
            record.originalFilename,
            record.editedFilename,
            record.thumbnailFilename,
            record.annotationFilename,
        ].compactMap { $0 }
    }

    private func removeFiles(at urls: [URL]) throws {
        var firstError: Error?
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private func ownedFileURL(for relativeFilename: String) throws -> URL {
        let pathComponents = relativeFilename.split(separator: "/")
        guard !relativeFilename.isEmpty,
              !(relativeFilename as NSString).isAbsolutePath,
              !pathComponents.contains("..")
        else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return rootURL.appendingPathComponent(relativeFilename)
    }
}
