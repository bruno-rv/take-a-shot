import CoreGraphics
import Darwin
import Dispatch
import Foundation
import ImageIO

private enum BenchmarkError: LocalizedError {
    case invalidFixture(String)
    case invalidPreseed(expected: Int, actual: Int)
    case invalidPersistence(String)
    case invalidSamples(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .invalidFixture(let message), .invalidPersistence(let message):
            message
        case .invalidPreseed(let expected, let actual):
            "Expected \(expected) valid preseed records, found \(actual)."
        case .invalidSamples(let expected, let actual):
            "Expected \(expected) samples, found \(actual)."
        }
    }
}

private struct BenchmarkMetric: Encodable {
    let name: String
    let preseedRecordCount: Int?
    let rawMilliseconds: [Double]
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let madMilliseconds: Double
}

private struct BenchmarkReport: Encodable {
    struct ImageFixture: Encodable {
        let width: Int
        let height: Int
        let pattern: String
    }

    struct SourceMetadata: Encodable {
        let sourceRoot: String
        let gitRevision: String?
        let operatingSystemVersion: String?
        let architecture: String?
        let swiftVersion: String?
    }

    let schemaVersion = 1
    let warmupCount: Int
    let sampleCount: Int
    let percentileMethod = "nearest-rank"
    let imageFixture: ImageFixture
    let source: SourceMetadata
    let ocrStrategy = "barrier-tracked-CancellationError"
    let metrics: [BenchmarkMetric]
}

private actor OCRTrialTracker: OCRRecognizing {
    private var recognizerCompleted = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    /// `CaptureLibraryStore` calls this only after it prepares the OCR image.
    func recognizeText(in _: CGImage) async throws -> String {
        defer { completeRecognizer() }
        throw CancellationError()
    }

    /// The state check and continuation registration are actor-isolated, so the
    /// recognizer cannot complete between them and lose a wakeup.
    func waitUntilRecognizerCompletes() async {
        guard !recognizerCompleted else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }

    private func completeRecognizer() {
        recognizerCompleted = true
        let waiters = completionWaiters
        completionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

@main
private struct CaptureLibraryBenchmark {
    private static let isSmokeRun = CommandLine.arguments.dropFirst().contains("--smoke")
    private static let warmupCount = isSmokeRun ? 1 : 5
    private static let sampleCount = isSmokeRun ? 2 : 15
    private static let imageWidth = 1_280
    private static let imageHeight = 720
    private static let preseedCounts = isSmokeRun ? [0, 10] : [0, 100, 500]
    private static let fixtureDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func main() async {
        do {
            let report = try await run()
            var data = try JSONEncoder.prettySorted.encode(report)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        } catch {
            let message = "CaptureLibrary benchmark failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    private static func run() async throws -> BenchmarkReport {
        let image = try SyntheticImage.make(width: imageWidth, height: imageHeight)
        let imageFixture = BenchmarkReport.ImageFixture(
            width: image.width,
            height: image.height,
            pattern: "deterministic-xor-gradient-rgba"
        )

        var metrics = [try benchmarkEncodeOnly(image: image)]
        for preseedCount in preseedCounts {
            metrics.append(try await benchmarkPersistence(
                image: image,
                preseedCount: preseedCount
            ))
        }
        return BenchmarkReport(
            warmupCount: warmupCount,
            sampleCount: sampleCount,
            imageFixture: imageFixture,
            source: sourceMetadata(),
            metrics: metrics
        )
    }

    private static func sourceMetadata() -> BenchmarkReport.SourceMetadata {
        BenchmarkReport.SourceMetadata(
            sourceRoot: environmentValue("CAPTURE_LIBRARY_BENCHMARK_SOURCE_ROOT")
                ?? FileManager.default.currentDirectoryPath,
            gitRevision: environmentValue("CAPTURE_LIBRARY_BENCHMARK_GIT_REVISION"),
            operatingSystemVersion: environmentValue("CAPTURE_LIBRARY_BENCHMARK_OS_VERSION"),
            architecture: environmentValue("CAPTURE_LIBRARY_BENCHMARK_ARCH"),
            swiftVersion: environmentValue("CAPTURE_LIBRARY_BENCHMARK_SWIFT_VERSION")
        )
    }

    private static func environmentValue(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func benchmarkEncodeOnly(image: CGImage) throws -> BenchmarkMetric {
        let rawMilliseconds = try collectSamples {
            let start = DispatchTime.now().uptimeNanoseconds
            let data = try ImageExporter.pngData(for: image)
            let elapsed = milliseconds(since: start)
            guard isDecodableImage(data) else {
                throw BenchmarkError.invalidFixture("PNG encoding produced an unreadable image.")
            }
            return elapsed
        }
        return metric(
            name: "encode_only",
            preseedRecordCount: nil,
            rawMilliseconds: rawMilliseconds
        )
    }

    private static func benchmarkPersistence(
        image: CGImage,
        preseedCount: Int
    ) async throws -> BenchmarkMetric {
        var rawMilliseconds: [Double] = []
        for iteration in 0..<(warmupCount + sampleCount) {
            let elapsed = try await persistSample(image: image, preseedCount: preseedCount)
            if iteration >= warmupCount {
                rawMilliseconds.append(elapsed)
            }
        }
        guard rawMilliseconds.count == sampleCount else {
            throw BenchmarkError.invalidSamples(
                expected: sampleCount,
                actual: rawMilliseconds.count
            )
        }
        return metric(
            name: "persist_n_\(preseedCount)",
            preseedRecordCount: preseedCount,
            rawMilliseconds: rawMilliseconds
        )
    }

    private static func persistSample(
        image: CGImage,
        preseedCount: Int
    ) async throws -> Double {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try preseed(root: root, count: preseedCount, image: image)
        let ocr = OCRTrialTracker()
        let store = CaptureLibraryStore(rootURL: root, ocr: ocr)
        let existing = try await store.load()
        let existingIssues = await store.loadIssues()
        guard existing.count == preseedCount, existingIssues.isEmpty else {
            throw BenchmarkError.invalidPreseed(expected: preseedCount, actual: existing.count)
        }

        let capture = capturedImage(image)
        let start = DispatchTime.now().uptimeNanoseconds
        let record = try await store.persist(image: capture)
        let elapsed = milliseconds(since: start)

        await ocr.waitUntilRecognizerCompletes()
        try await validatePersistence(
            root: root,
            store: store,
            record: record,
            expectedRecordCount: preseedCount + 1
        )
        return elapsed
    }

    private static func preseed(root: URL, count: Int, image: CGImage) throws {
        guard count > 0 else { return }

        let fileManager = FileManager.default
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        let thumbnails = root.appendingPathComponent("thumbnails", isDirectory: true)
        let fixtures = root.appendingPathComponent("benchmark-fixtures", isDirectory: true)
        try fileManager.createDirectory(at: originals, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fixtures, withIntermediateDirectories: true)

        let originalFixture = fixtures.appendingPathComponent("original.png")
        let thumbnailFixture = fixtures.appendingPathComponent("thumbnail.png")
        try ImageExporter.write(try ImageExporter.pngData(for: image), to: originalFixture)
        let thumbnail = try ImageExporter.thumbnail(for: image, maxPixelSize: 512)
        try ImageExporter.write(try ImageExporter.pngData(for: thumbnail), to: thumbnailFixture)

        var records: [CaptureRecord] = []
        records.reserveCapacity(count)
        for index in 0..<count {
            let id = preseedIdentifier(for: index)
            let originalFilename = "originals/\(id.uuidString).png"
            let thumbnailFilename = "thumbnails/\(id.uuidString).png"
            try fileManager.linkItem(
                at: originalFixture,
                to: root.appendingPathComponent(originalFilename)
            )
            try fileManager.linkItem(
                at: thumbnailFixture,
                to: root.appendingPathComponent(thumbnailFilename)
            )
            records.append(CaptureRecord(
                id: id,
                kind: .area,
                title: "Preseed \(index)",
                createdAt: fixtureDate,
                lastEditedAt: fixtureDate,
                pixelSize: PixelSize(width: image.width, height: image.height),
                duration: nil,
                originalFilename: originalFilename,
                editedFilename: nil,
                thumbnailFilename: thumbnailFilename,
                annotationFilename: nil,
                ocrText: "",
                tags: []
            ))
        }
        try JSONEncoder().encode(records).write(
            to: root.appendingPathComponent("index.json"),
            options: .atomic
        )
    }

    private static func validatePersistence(
        root: URL,
        store: CaptureLibraryStore,
        record: CaptureRecord,
        expectedRecordCount: Int
    ) async throws {
        let matchingRecords = await store.search("benchmark capture")
        guard matchingRecords.contains(where: { $0.id == record.id }) else {
            throw BenchmarkError.invalidPersistence("Persisted capture was not searchable.")
        }
        let originalURL = try await store.originalURL(for: record.id)
        let thumbnailURL = try await store.thumbnailURL(for: record.id)
        guard isDecodableImage(at: originalURL), isDecodableImage(at: thumbnailURL) else {
            throw BenchmarkError.invalidPersistence("Persisted image assets were not decodable.")
        }

        let reloadedStore = CaptureLibraryStore(rootURL: root, ocr: OCRTrialTracker())
        let reloadedRecords = try await reloadedStore.load()
        let reloadIssues = await reloadedStore.loadIssues()
        guard reloadedRecords.count == expectedRecordCount,
              reloadedRecords.contains(where: { $0.id == record.id }),
              reloadIssues.isEmpty else {
            throw BenchmarkError.invalidPersistence("Reload did not preserve every valid record.")
        }
    }

    private static func collectSamples(_ sample: () throws -> Double) throws -> [Double] {
        var rawMilliseconds: [Double] = []
        for iteration in 0..<(warmupCount + sampleCount) {
            let elapsed = try sample()
            if iteration >= warmupCount {
                rawMilliseconds.append(elapsed)
            }
        }
        guard rawMilliseconds.count == sampleCount else {
            throw BenchmarkError.invalidSamples(
                expected: sampleCount,
                actual: rawMilliseconds.count
            )
        }
        return rawMilliseconds
    }

    private static func metric(
        name: String,
        preseedRecordCount: Int?,
        rawMilliseconds: [Double]
    ) -> BenchmarkMetric {
        let sorted = rawMilliseconds.sorted()
        let medianValue = median(of: sorted)
        let deviations = rawMilliseconds.map { abs($0 - medianValue) }.sorted()
        let p95Index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return BenchmarkMetric(
            name: name,
            preseedRecordCount: preseedRecordCount,
            rawMilliseconds: rawMilliseconds,
            medianMilliseconds: medianValue,
            p95Milliseconds: sorted[p95Index],
            madMilliseconds: median(of: deviations)
        )
    }

    private static func median(of sortedValues: [Double]) -> Double {
        let midpoint = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[midpoint - 1] + sortedValues[midpoint]) / 2
        }
        return sortedValues[midpoint]
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "take-a-shot-capture-library-benchmark-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private static func capturedImage(_ image: CGImage) -> CapturedImage {
        CapturedImage(
            id: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!,
            kind: .area,
            title: "Benchmark capture",
            createdAt: fixtureDate,
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height)
        )
    }

    private static func preseedIdentifier(for index: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(index + 1))
        return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }

    private static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        return image.width > 0 && image.height > 0
    }

    private static func isDecodableImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        return image.width > 0 && image.height > 0
    }
}

private enum SyntheticImage {
    static func make(width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
        else {
            throw BenchmarkError.invalidFixture("Could not create the synthetic image context.")
        }

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value = UInt8(truncatingIfNeeded: (x &* 31) ^ (y &* 17) ^ ((x &* y) >> 3))
                pixels[offset] = value
                pixels[offset + 1] = value &+ UInt8(truncatingIfNeeded: x)
                pixels[offset + 2] = value &+ UInt8(truncatingIfNeeded: y)
                pixels[offset + 3] = .max
            }
        }
        guard let image = context.makeImage() else {
            throw BenchmarkError.invalidFixture("Could not finalize the synthetic image.")
        }
        return image
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
