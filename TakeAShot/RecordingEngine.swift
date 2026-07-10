import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

final class RecordingFailureRelay: @unchecked Sendable {
    let events: AsyncStream<RecordingError>

    private let continuation: AsyncStream<RecordingError>.Continuation
    private let lock = NSLock()
    private var isOpen = true
    private var didReport = false

    init() {
        let failures = AsyncStream.makeStream(
            of: RecordingError.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        events = failures.stream
        continuation = failures.continuation
    }

    @discardableResult
    func report(_ failure: RecordingError) -> Bool {
        lock.withLock {
            guard isOpen, !didReport else { return false }
            didReport = true
            continuation.yield(failure)
            return true
        }
    }

    func finish() {
        lock.withLock {
            guard isOpen else { return }
            isOpen = false
            continuation.finish()
        }
    }
}

protocol RecordingSession: Sendable {
    var failureEvents: AsyncStream<RecordingError> { get }
    var outputURL: URL { get async }
    func start() async throws
    func stop() async throws -> URL
    func cancel() async
}

struct RecordingFileLocations: Equatable, Sendable {
    let temporaryURL: URL
    let outputURL: URL

    init(rootURL: URL, identifier: UUID, format: RecordingFormat = .mp4) {
        let filename = "\(identifier.uuidString).\(format.fileExtension)"
        temporaryURL = rootURL
            .appendingPathComponent("temporary", isDirectory: true)
            .appendingPathComponent(filename)
        outputURL = rootURL
            .appendingPathComponent("originals", isDirectory: true)
            .appendingPathComponent(filename)
    }

    static func `default`(
        identifier: UUID,
        format: RecordingFormat = .mp4
    ) throws -> RecordingFileLocations {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return RecordingFileLocations(
            rootURL: applicationSupport.appendingPathComponent("TakeAShot", isDirectory: true),
            identifier: identifier,
            format: format
        )
    }
}

private extension RecordingFormat {
    var fileExtension: String {
        switch self {
        case .mp4: "mp4"
        case .gif: "gif"
        }
    }
}

final class RecordingOutputTransaction: @unchecked Sendable {
    typealias RemoveItem = @Sendable (URL) throws -> Void

    private let locations: RecordingFileLocations
    private let fileManager: FileManager
    private let removeItem: RemoveItem

    init(
        locations: RecordingFileLocations,
        fileManager: FileManager = .default,
        removeItem: RemoveItem? = nil
    ) {
        self.locations = locations
        self.fileManager = fileManager
        self.removeItem = removeItem ?? { try fileManager.removeItem(at: $0) }
    }

    func prepare() throws {
        guard !fileManager.fileExists(atPath: locations.outputURL.path) else {
            throw RecordingError.writerSetupFailed("The destination file already exists.")
        }
        try fileManager.createDirectory(
            at: locations.temporaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: locations.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: locations.temporaryURL.path) {
            try removeItem(locations.temporaryURL)
        }
    }

    func commit() throws {
        guard fileManager.fileExists(atPath: locations.temporaryURL.path) else {
            throw RecordingError.recordingFailed("The completed temporary file is missing.")
        }
        guard !fileManager.fileExists(atPath: locations.outputURL.path) else {
            throw RecordingError.recordingFailed("The destination file already exists.")
        }
        try fileManager.moveItem(at: locations.temporaryURL, to: locations.outputURL)
    }

    func rollback(removeOutput: Bool = false) {
        try? rollbackThrowing(removeOutput: removeOutput)
    }

    func rollbackThrowing(removeOutput: Bool = false) throws {
        var failures: [String] = []
        let urls = removeOutput
            ? [locations.temporaryURL, locations.outputURL]
            : [locations.temporaryURL]
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                try removeItem(url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw RecordingError.gifCleanupFailed(failures.joined(separator: "; "))
        }
    }
}

struct GIFWriter {
    typealias DestinationFactory = @Sendable (URL, Int) -> CGImageDestination?
    typealias RemoveItem = @Sendable (URL) throws -> Void

    private struct StagedFrame {
        let imageURL: URL
        let timestampURL: URL
    }

    private struct PlannedFrame {
        let stagedFrame: StagedFrame
        let delay: TimeInterval
    }

    private enum State: Equatable {
        case active
        case finalized
        case cancelled
        case failed
    }

    static let defaultMaxTemporaryBytes = 512 * 1_024 * 1_024
    private static let minimumSafeDelay = CMTime(
        seconds: 0.02,
        preferredTimescale: 600_000
    )

    private let outputURL: URL
    private let journalURL: URL
    private let maxPixelSize: Int
    private let maxDuration: CMTime
    private let minimumFrameInterval: CMTime
    private let maxTemporaryBytes: Int
    private let destinationFactory: DestinationFactory
    private let removeItem: RemoveItem
    private var state: State = .active
    private var startTime: CMTime?
    private var latestAcceptedTime: CMTime?
    private var stagedFrames: [StagedFrame] = []
    private var temporaryBytes = 0

    init(
        url: URL,
        maxFPS: Int,
        maxPixelSize: Int,
        maxDuration: TimeInterval,
        maxTemporaryBytes: Int = GIFWriter.defaultMaxTemporaryBytes,
        destinationFactory: DestinationFactory? = nil,
        removeItem: RemoveItem? = nil
    ) throws {
        guard (1...10).contains(maxFPS) else {
            throw RecordingError.invalidGIFFrameRate(maxFPS)
        }
        guard (1...1_280).contains(maxPixelSize),
              maxDuration >= 0.02,
              maxDuration <= 60,
              maxTemporaryBytes > 0 else {
            throw RecordingError.writerSetupFailed("GIF limits exceed the supported bounds.")
        }
        outputURL = url
        journalURL = Self.journalURL(for: url)
        self.maxPixelSize = maxPixelSize
        self.maxDuration = CMTime(seconds: maxDuration, preferredTimescale: 600_000)
        minimumFrameInterval = CMTime(
            seconds: 1 / Double(maxFPS),
            preferredTimescale: 600_000
        )
        self.maxTemporaryBytes = maxTemporaryBytes
        self.destinationFactory = destinationFactory ?? { outputURL, count in
            CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                UTType.gif.identifier as CFString,
                count,
                nil
            )
        }
        self.removeItem = removeItem ?? { try FileManager.default.removeItem(at: $0) }

        do {
            if FileManager.default.fileExists(atPath: journalURL.path) {
                try self.removeItem(journalURL)
            }
            try FileManager.default.createDirectory(
                at: journalURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw RecordingError.gifStorageFailed(error.localizedDescription)
        }
    }

    static func journalURL(for outputURL: URL) -> URL {
        outputURL.appendingPathExtension("frames")
    }

    mutating func append(image: CGImage, presentationTime: CMTime) throws {
        guard state == .active else {
            throw RecordingError.gifEncodingFailed("The GIF writer is already finalized.")
        }
        let seconds = CMTimeGetSeconds(presentationTime)
        guard presentationTime.isValid,
              !presentationTime.isIndefinite,
              seconds.isFinite else { return }
        if let latestAcceptedTime,
           CMTimeCompare(presentationTime, latestAcceptedTime) <= 0 {
            return
        }

        let candidateStart = startTime ?? presentationTime
        let elapsed = CMTimeSubtract(presentationTime, candidateStart)
        let latestSafeTime = CMTimeSubtract(maxDuration, Self.minimumSafeDelay)
        guard CMTimeCompare(elapsed, .zero) >= 0,
              CMTimeCompare(elapsed, latestSafeTime) <= 0 else { return }
        if let latestAcceptedTime {
            let interval = CMTimeSubtract(presentationTime, latestAcceptedTime)
            guard CMTimeCompare(interval, minimumFrameInterval) >= 0 else { return }
        }

        let boundedImage = try Self.boundedImage(image, maxPixelSize: maxPixelSize)
        let index = stagedFrames.count
        let imageURL = journalURL.appendingPathComponent(String(format: "%06d.png", index))
        let timestampURL = journalURL.appendingPathComponent(String(format: "%06d.time", index))
        do {
            try Self.writeStagedImage(boundedImage, to: imageURL)
            let timestampData = Data(
                "\(presentationTime.value),\(presentationTime.timescale)".utf8
            )
            try timestampData.write(to: timestampURL, options: .atomic)
            let bytes = try Self.fileSize(at: imageURL) + Self.fileSize(at: timestampURL)
            guard temporaryBytes <= maxTemporaryBytes - bytes else {
                try failAndCleanup(
                    .gifTemporaryStorageLimitExceeded(limit: maxTemporaryBytes)
                )
            }
            stagedFrames.append(StagedFrame(imageURL: imageURL, timestampURL: timestampURL))
            temporaryBytes += bytes
            startTime = candidateStart
            latestAcceptedTime = presentationTime
        } catch let recordingError as RecordingError {
            if state == .failed { throw recordingError }
            try failAndCleanup(recordingError)
        } catch {
            try failAndCleanup(.gifStorageFailed(error.localizedDescription))
        }
    }

    mutating func finish(stopTime: CMTime? = nil) throws {
        guard state == .active else {
            throw RecordingError.gifEncodingFailed("The GIF writer is already finalized.")
        }
        guard !stagedFrames.isEmpty else {
            try failAndCleanup(
                .gifEncodingFailed("No GIF frames were captured.")
            )
        }

        do {
            let plannedFrames = try timingPlan(stopTime: stopTime)
            guard let destination = destinationFactory(outputURL, plannedFrames.count) else {
                try failAndCleanup(
                    .gifEncodingFailed("An exact-count Image I/O destination could not be created.")
                )
            }
            CGImageDestinationSetProperties(
                destination,
                [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFLoopCount: 0,
                    ],
                ] as CFDictionary
            )
            for frame in plannedFrames {
                guard let source = CGImageSourceCreateWithURL(
                    frame.stagedFrame.imageURL as CFURL,
                    nil
                ), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    try failAndCleanup(
                        .gifStorageFailed("A staged GIF frame could not be read.")
                    )
                }
                CGImageDestinationAddImage(
                    destination,
                    image,
                    [
                        kCGImagePropertyGIFDictionary: [
                            kCGImagePropertyGIFDelayTime: frame.delay,
                            kCGImagePropertyGIFUnclampedDelayTime: frame.delay,
                        ],
                    ] as CFDictionary
                )
            }
            guard CGImageDestinationFinalize(destination) else {
                try failAndCleanup(
                    .gifEncodingFailed("Image I/O could not finalize the GIF.")
                )
            }
            do {
                try removeIfPresent(journalURL)
            } catch {
                try failAndCleanup(.gifCleanupFailed(error.localizedDescription))
            }
            stagedFrames.removeAll()
            temporaryBytes = 0
            state = .finalized
        } catch let recordingError as RecordingError {
            if state == .failed { throw recordingError }
            try failAndCleanup(recordingError)
        } catch {
            try failAndCleanup(.gifEncodingFailed(error.localizedDescription))
        }
    }

    mutating func cancel() throws {
        guard state != .cancelled else { return }
        let cleanupError = cleanupArtifacts(removeOutput: true)
        stagedFrames.removeAll()
        temporaryBytes = 0
        state = .cancelled
        if let cleanupError { throw cleanupError }
    }

    private func timingPlan(stopTime: CMTime?) throws -> [PlannedFrame] {
        let timestamps = try stagedFrames.map { try Self.readTimestamp(at: $0.timestampURL) }
        guard let start = timestamps.first, let last = timestamps.last else {
            throw RecordingError.gifEncodingFailed("No GIF frames were captured.")
        }
        let requestedStop = stopTime ?? CMTimeAdd(last, minimumFrameInterval)
        let rawStopSeconds = CMTimeGetSeconds(CMTimeSubtract(requestedStop, start))
        let boundedStopSeconds = min(
            CMTimeGetSeconds(maxDuration),
            max(0, rawStopSeconds.isFinite ? rawStopSeconds : 0)
        )
        let maximumCentiseconds = Int(
            floor(CMTimeGetSeconds(maxDuration) * 100 + 0.000_000_1)
        )
        let stopCentiseconds = min(
            maximumCentiseconds,
            max(2, Int(ceil(boundedStopSeconds * 100 - 0.000_000_1)))
        )

        var included: [(frame: StagedFrame, boundary: Int)] = []
        for (index, timestamp) in timestamps.enumerated() {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(timestamp, start))
            guard elapsed.isFinite, elapsed >= 0 else { continue }
            let boundary = Int(floor(elapsed * 100 + 0.000_000_1))
            guard index == 0 || boundary <= stopCentiseconds - 2 else { continue }
            guard included.last?.boundary != boundary else { continue }
            included.append((stagedFrames[index], boundary))
        }
        guard !included.isEmpty else {
            throw RecordingError.gifEncodingFailed("No decoder-safe GIF frames remained.")
        }

        return included.enumerated().map { index, item in
            let nextBoundary = index + 1 < included.count
                ? included[index + 1].boundary
                : stopCentiseconds
            let delayCentiseconds = max(2, nextBoundary - item.boundary)
            return PlannedFrame(
                stagedFrame: item.frame,
                delay: Double(delayCentiseconds) / 100
            )
        }
    }

    private mutating func failAndCleanup(_ error: RecordingError) throws -> Never {
        state = .failed
        let cleanupError = cleanupArtifacts(removeOutput: true)
        stagedFrames.removeAll()
        temporaryBytes = 0
        throw cleanupError ?? error
    }

    private func cleanupArtifacts(removeOutput: Bool) -> RecordingError? {
        var failures: [String] = []
        let urls = removeOutput ? [journalURL, outputURL] : [journalURL]
        for url in urls {
            do {
                try removeIfPresent(url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard !failures.isEmpty else { return nil }
        return .gifCleanupFailed(failures.joined(separator: "; "))
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try removeItem(url)
    }

    private static func writeStagedImage(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw RecordingError.gifStorageFailed("A staged frame destination could not be created.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RecordingError.gifStorageFailed("A staged frame could not be finalized.")
        }
    }

    private static func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw RecordingError.gifStorageFailed("A staged frame size could not be read.")
        }
        return size.intValue
    }

    private static func readTimestamp(at url: URL) throws -> CMTime {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RecordingError.gifStorageFailed("A staged frame timestamp is invalid.")
        }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let value = CMTimeValue(parts[0]),
              let timescale = CMTimeScale(parts[1]),
              timescale != 0 else {
            throw RecordingError.gifStorageFailed("A staged frame timestamp is invalid.")
        }
        return CMTime(value: value, timescale: timescale)
    }

    private static func boundedImage(_ image: CGImage, maxPixelSize: Int) throws -> CGImage {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > maxPixelSize else { return image }
        let scale = CGFloat(maxPixelSize) / CGFloat(longestEdge)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RecordingError.gifEncodingFailed("A bounded GIF frame could not be allocated.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bounded = context.makeImage() else {
            throw RecordingError.gifEncodingFailed("A bounded GIF frame could not be rendered.")
        }
        return bounded
    }
}

protocol GIFFrameEncoding: AnyObject, Sendable {
    func append(image: CGImage, presentationTime: CMTime) throws
    func finish(stopTime: CMTime?) throws
    func cancel() throws
}

final class IncrementalGIFFrameEncoder: GIFFrameEncoding, @unchecked Sendable {
    private var writer: GIFWriter

    init(writer: GIFWriter) {
        self.writer = writer
    }

    func append(image: CGImage, presentationTime: CMTime) throws {
        try writer.append(image: image, presentationTime: presentationTime)
    }

    func finish(stopTime: CMTime?) throws {
        try writer.finish(stopTime: stopTime)
    }

    func cancel() throws {
        try writer.cancel()
    }

    deinit {
        try? writer.cancel()
    }
}

enum RecordingVideoCodec: Equatable, Sendable {
    case h264
}

struct RecordingStreamPlan: Equatable, Sendable {
    let framesPerSecond: Int
    let pixelSize: PixelSize
    let videoCodec: RecordingVideoCodec
    let audioWriterInputCount: Int
    let mixesAudioSources: Bool
    let audioSampleRate: Int
    let audioChannelCount: Int

    init(request: RecordingRequest, pixelSize: PixelSize) throws {
        guard request.format == .mp4 else {
            throw RecordingError.unsupportedFormat(request.format)
        }
        guard (1...30).contains(request.framesPerSecond) else {
            throw RecordingError.invalidFrameRate(request.framesPerSecond)
        }
        let evenWidth = max(2, pixelSize.width - pixelSize.width % 2)
        let evenHeight = max(2, pixelSize.height - pixelSize.height % 2)
        framesPerSecond = request.framesPerSecond
        self.pixelSize = PixelSize(width: evenWidth, height: evenHeight)
        videoCodec = .h264
        audioWriterInputCount = request.includesSystemAudio || request.includesMicrophone ? 1 : 0
        mixesAudioSources = request.includesSystemAudio && request.includesMicrophone
        audioSampleRate = 48_000
        audioChannelCount = 2
    }
}

enum AudioFrameMixer {
    static func mix(system: [Float], microphone: [Float]) -> [Float] {
        let count = max(system.count, microphone.count)
        return (0..<count).map { index in
            let systemSample = index < system.count ? system[index] : 0
            let microphoneSample = index < microphone.count ? microphone[index] : 0
            return min(1, max(-1, systemSample + microphoneSample))
        }
    }
}

actor RecordingEngine {
    typealias SessionFactory = @Sendable (RecordingRequest) throws -> any RecordingSession

    private struct CleanupOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private(set) var state: RecordingState = .idle
    private let sessionFactory: SessionFactory
    private var session: (any RecordingSession)?
    private var operationID: UUID?
    private var failureMonitor: Task<Void, Never>?
    private var cleanupOperation: CleanupOperation?

    init(sessionFactory: @escaping SessionFactory) {
        self.sessionFactory = sessionFactory
    }

    init() {
        sessionFactory = { request in
            let locations = try RecordingFileLocations.default(
                identifier: UUID(),
                format: request.format
            )
            return try DefaultRecordingSessionFactory.makeSession(
                request: request,
                locations: locations
            )
        }
    }

    func start(request: RecordingRequest) async throws {
        try validate(request)
        guard [.idle, .completed, .failed].contains(state.kind) else {
            throw RecordingError.invalidTransition(.start, state.kind)
        }

        await consumeCleanupBeforeStart()
        guard [.idle, .completed, .failed].contains(state.kind) else {
            throw RecordingError.invalidTransition(.start, state.kind)
        }

        stopFailureMonitoring()
        let identifier = UUID()
        operationID = identifier
        state = .preparing

        let newSession: any RecordingSession
        do {
            newSession = try sessionFactory(request)
        } catch {
            operationID = nil
            state = .failed(error.localizedDescription)
            throw error
        }
        session = newSession
        monitorFailures(from: newSession, operationID: identifier)

        do {
            try await newSession.start()
        } catch {
            guard operationID == identifier else {
                await awaitCleanup(beginCleanup(for: newSession))
                throw CancellationError()
            }
            stopFailureMonitoring()
            operationID = nil
            session = nil
            state = .failed(error.localizedDescription)
            await awaitCleanup(beginCleanup(for: newSession))
            throw error
        }

        guard operationID == identifier, state.kind == .preparing else {
            await awaitCleanup(beginCleanup(for: newSession))
            throw CancellationError()
        }
        state = .recording(startedAt: .now)
    }

    func stop() async throws -> URL {
        guard state.kind == .recording, let session, let identifier = operationID else {
            throw RecordingError.invalidTransition(.stop, state.kind)
        }
        state = .stopping
        stopFailureMonitoring()

        do {
            let output = try await session.stop()
            guard operationID == identifier, state.kind == .stopping else {
                await joinCleanup()
                throw CancellationError()
            }
            operationID = nil
            self.session = nil
            state = .completed(output)
            return output
        } catch {
            guard operationID == identifier else {
                await joinCleanup()
                throw CancellationError()
            }
            operationID = nil
            self.session = nil
            state = .failed(error.localizedDescription)
            await awaitCleanup(beginCleanup(for: session))
            throw error
        }
    }

    func cancel() async {
        let activeSession = session
        stopFailureMonitoring()
        operationID = nil
        session = nil
        state = .idle
        await awaitCleanup(beginCleanup(for: activeSession))
    }

    private func monitorFailures(
        from session: any RecordingSession,
        operationID identifier: UUID
    ) {
        let events = session.failureEvents
        failureMonitor = Task { [weak self] in
            for await failure in events {
                guard !Task.isCancelled else { return }
                await self?.handleFailure(
                    failure,
                    operationID: identifier
                )
                return
            }
        }
    }

    private func handleFailure(
        _ failure: RecordingError,
        operationID identifier: UUID
    ) async {
        guard operationID == identifier,
              state.kind == .preparing || state.kind == .recording,
              let failedSession = session else { return }
        failureMonitor = nil
        operationID = nil
        session = nil
        state = .failed(failure.localizedDescription)
        await awaitCleanup(beginCleanup(for: failedSession))
    }

    private func stopFailureMonitoring() {
        failureMonitor?.cancel()
        failureMonitor = nil
    }

    private func beginCleanup(for activeSession: (any RecordingSession)?) -> CleanupOperation? {
        if let cleanupOperation { return cleanupOperation }
        guard let activeSession else { return nil }
        let operation = CleanupOperation(
            id: UUID(),
            task: Task { await activeSession.cancel() }
        )
        cleanupOperation = operation
        return operation
    }

    private func joinCleanup() async {
        await awaitCleanup(cleanupOperation)
    }

    private func consumeCleanupBeforeStart() async {
        guard let operation = cleanupOperation else { return }
        await operation.task.value
        if cleanupOperation?.id == operation.id {
            cleanupOperation = nil
        }
    }

    private func awaitCleanup(_ operation: CleanupOperation?) async {
        guard let operation else { return }
        await operation.task.value
    }

    private func validate(_ request: RecordingRequest) throws {
        switch request.format {
        case .mp4:
            guard (1...30).contains(request.framesPerSecond) else {
                throw RecordingError.invalidFrameRate(request.framesPerSecond)
            }
        case .gif:
            guard (1...10).contains(request.framesPerSecond) else {
                throw RecordingError.invalidGIFFrameRate(request.framesPerSecond)
            }
            guard !request.includesSystemAudio, !request.includesMicrophone else {
                throw RecordingError.gifAudioUnsupported
            }
        }
    }
}

enum DefaultRecordingSessionFactory {
    static func makeSession(
        request: RecordingRequest,
        locations: RecordingFileLocations
    ) throws -> any RecordingSession {
        switch request.format {
        case .mp4:
            return MP4RecordingSession(request: request, locations: locations)
        case .gif:
            return GIFRecordingSession(request: request, locations: locations)
        }
    }
}

struct GIFFrameMetadata: @unchecked Sendable {
    let contentRect: CGRect
    let contentScale: CGFloat
    let scaleFactor: CGFloat
}

enum GIFFrameGeometry {
    static func boundedPixelSize(
        contentRect: CGRect,
        pointPixelScale: CGFloat,
        maxPixelSize: Int
    ) -> PixelSize {
        let width = max(1, Int((contentRect.width * pointPixelScale).rounded()))
        let height = max(1, Int((contentRect.height * pointPixelScale).rounded()))
        let longestEdge = max(width, height)
        guard longestEdge > maxPixelSize else {
            return PixelSize(width: width, height: height)
        }
        let scale = Double(maxPixelSize) / Double(longestEdge)
        return PixelSize(
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }

    static func pixelCropRect(
        bufferSize: PixelSize,
        metadata: GIFFrameMetadata
    ) -> CGRect {
        let surfaceScale = metadata.contentScale * metadata.scaleFactor
        guard surfaceScale.isFinite, surfaceScale > 0 else { return .null }
        let scaled = CGRect(
            x: metadata.contentRect.origin.x * surfaceScale,
            y: metadata.contentRect.origin.y * surfaceScale,
            width: metadata.contentRect.width * surfaceScale,
            height: metadata.contentRect.height * surfaceScale
        ).standardized.integral
        let bufferBounds = CGRect(
            x: 0,
            y: 0,
            width: bufferSize.width,
            height: bufferSize.height
        )
        return scaled.intersection(bufferBounds)
    }

    static func crop(image: CGImage, metadata: GIFFrameMetadata) throws -> CGImage {
        let cropRect = pixelCropRect(
            bufferSize: PixelSize(width: image.width, height: image.height),
            metadata: metadata
        )
        guard !cropRect.isNull,
              cropRect.width > 0,
              cropRect.height > 0,
              let cropped = image.cropping(to: cropRect) else {
            throw RecordingError.gifEncodingFailed(
                "ScreenCaptureKit frame metadata did not describe visible content."
            )
        }
        return cropped
    }
}

final class GIFMediaWriter: @unchecked Sendable {
    private let encoder: any GIFFrameEncoding
    private let failureRelay: RecordingFailureRelay
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let failureLock = NSLock()
    private var failure: RecordingError?

    init(encoder: any GIFFrameEncoding, failureRelay: RecordingFailureRelay) {
        self.encoder = encoder
        self.failureRelay = failureRelay
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, sourceClock: CMClock?) {
        guard CMSampleBufferDataIsReady(sampleBuffer), sampleBuffer.hasCompleteScreenFrame else {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            recordFailure(
                RecordingError.gifEncodingFailed("A complete screen frame had no pixel buffer.")
            )
            return
        }
        guard let metadata = sampleBuffer.completeScreenFrameMetadata else {
            recordFailure(
                RecordingError.gifEncodingFailed(
                    "A complete screen frame had invalid content geometry metadata."
                )
            )
            return
        }
        var presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let sourceClock, presentationTime.isValid {
            presentationTime = CMSyncConvertTime(
                presentationTime,
                from: sourceClock,
                to: CMClockGetHostTimeClock()
            )
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let frame = imageContext.createCGImage(image, from: image.extent) else {
            recordFailure(
                RecordingError.gifEncodingFailed(
                    "A screen frame could not be converted for GIF encoding."
                )
            )
            return
        }
        do {
            let cropped = try GIFFrameGeometry.crop(image: frame, metadata: metadata)
            append(image: cropped, presentationTime: presentationTime)
        } catch {
            recordFailure(error)
        }
    }

    func append(image: CGImage, presentationTime: CMTime) {
        guard currentFailure == nil else { return }
        do {
            try encoder.append(image: image, presentationTime: presentationTime)
        } catch {
            recordFailure(error)
        }
    }

    func finish(stopTime: CMTime?) throws {
        if let failure = currentFailure { throw failure }
        do {
            try encoder.finish(stopTime: stopTime)
        } catch {
            let recordingError = Self.recordingError(from: error)
            _ = setFailureIfNeeded(recordingError)
            throw recordingError
        }
    }

    func cancel() throws {
        try encoder.cancel()
    }

    @discardableResult
    func recordFailure(_ error: Error) -> Bool {
        let recordingError = Self.recordingError(from: error)
        guard setFailureIfNeeded(recordingError) else { return false }
        return failureRelay.report(recordingError)
    }

    private var currentFailure: RecordingError? {
        failureLock.withLock { failure }
    }

    private func setFailureIfNeeded(_ error: RecordingError) -> Bool {
        failureLock.withLock {
            guard failure == nil else { return false }
            failure = error
            return true
        }
    }

    private static func recordingError(from error: Error) -> RecordingError {
        error as? RecordingError ?? .gifEncodingFailed(error.localizedDescription)
    }
}

protocol GIFCaptureResource: Sendable {
    func start() async throws
    func stop() async
}

actor GIFRecordingSession: RecordingSession {
    typealias CaptureFactory = @Sendable (
        RecordingRequest,
        DispatchQueue,
        GIFMediaWriter
    ) async throws -> any GIFCaptureResource
    typealias WriterFactory = @Sendable (
        URL,
        Int,
        RecordingFailureRelay
    ) throws -> GIFMediaWriter
    typealias StopTime = @Sendable () -> CMTime

    private struct CleanupOperation {
        let task: Task<RecordingError?, Never>
    }

    private enum Lifecycle {
        case idle
        case starting
        case running
        case stopping
        case cancelled
        case finished
        case failed
    }

    nonisolated let failureEvents: AsyncStream<RecordingError>
    let outputURL: URL

    private let request: RecordingRequest
    private let temporaryURL: URL
    private let transaction: RecordingOutputTransaction
    private let screenCaptureAuthorization: @Sendable () -> Bool
    private let captureFactory: CaptureFactory
    private let writerFactory: WriterFactory
    private let stopTime: StopTime
    private let failureRelay: RecordingFailureRelay
    private let mediaQueue = DispatchQueue(
        label: "com.bruno.takeashot.recording.gif.media",
        qos: .userInitiated
    )
    private var lifecycle: Lifecycle = .idle
    private var operationID: UUID?
    private var writer: GIFMediaWriter?
    private var resources: (any GIFCaptureResource)?
    private var cleanupOperation: CleanupOperation?

    init(
        request: RecordingRequest,
        locations: RecordingFileLocations,
        screenCaptureAuthorization: @escaping @Sendable () -> Bool = {
            CGPreflightScreenCaptureAccess()
        },
        captureFactory: @escaping CaptureFactory = { request, mediaQueue, writer in
            try await ScreenCaptureGIFResource.make(
                request: request,
                mediaQueue: mediaQueue,
                writer: writer
            )
        },
        writerFactory: @escaping WriterFactory = { url, maxFPS, failureRelay in
            let writer = try GIFWriter(
                url: url,
                maxFPS: maxFPS,
                maxPixelSize: 1_280,
                maxDuration: 60
            )
            return GIFMediaWriter(
                encoder: IncrementalGIFFrameEncoder(writer: writer),
                failureRelay: failureRelay
            )
        },
        stopTime: @escaping StopTime = {
            CMClockGetTime(CMClockGetHostTimeClock())
        }
    ) {
        let failureRelay = RecordingFailureRelay()
        failureEvents = failureRelay.events
        self.failureRelay = failureRelay
        self.request = request
        temporaryURL = locations.temporaryURL
        outputURL = locations.outputURL
        transaction = RecordingOutputTransaction(locations: locations)
        self.screenCaptureAuthorization = screenCaptureAuthorization
        self.captureFactory = captureFactory
        self.writerFactory = writerFactory
        self.stopTime = stopTime
    }

    func start() async throws {
        guard lifecycle == .idle else {
            throw RecordingError.invalidTransition(.start, .preparing)
        }
        guard request.format == .gif else {
            throw RecordingError.unsupportedFormat(request.format)
        }
        guard !request.includesSystemAudio, !request.includesMicrophone else {
            throw RecordingError.gifAudioUnsupported
        }
        guard (1...10).contains(request.framesPerSecond) else {
            throw RecordingError.invalidGIFFrameRate(request.framesPerSecond)
        }

        let identifier = UUID()
        operationID = identifier
        lifecycle = .starting
        do {
            guard screenCaptureAuthorization() else {
                throw RecordingError.screenRecordingPermissionDenied
            }
            try transaction.prepare()
            let writer = try writerFactory(
                temporaryURL,
                request.framesPerSecond,
                failureRelay
            )
            self.writer = writer
            let resources = try await captureFactory(request, mediaQueue, writer)
            guard operationID == identifier, lifecycle == .starting else {
                throw CancellationError()
            }
            self.resources = resources
            try await resources.start()
            guard operationID == identifier, lifecycle == .starting else {
                await resources.stop()
                throw CancellationError()
            }
            lifecycle = .running
        } catch {
            guard operationID == identifier else {
                if let cleanupError = await awaitCleanup(beginCleanup()) {
                    throw cleanupError
                }
                throw CancellationError()
            }
            operationID = nil
            lifecycle = error is CancellationError ? .cancelled : .failed
            let cleanupError = await awaitCleanup(beginCleanup())
            throw cleanupError ?? error
        }
    }

    func stop() async throws -> URL {
        guard lifecycle == .running, let operationID, let resources, let writer else {
            throw RecordingError.invalidTransition(.stop, .idle)
        }
        lifecycle = .stopping
        let identifier = operationID
        let finalStopTime = stopTime()

        do {
            await resources.stop()
            guard self.operationID == identifier, lifecycle == .stopping else {
                if let cleanupError = await awaitCleanup(beginCleanup()) {
                    throw cleanupError
                }
                throw CancellationError()
            }
            failureRelay.finish()
            await mediaQueue.drain()
            guard self.operationID == identifier, lifecycle == .stopping else {
                if let cleanupError = await awaitCleanup(beginCleanup()) {
                    throw cleanupError
                }
                throw CancellationError()
            }
            try await mediaQueue.performThrowing {
                try writer.finish(stopTime: finalStopTime)
            }
            guard self.operationID == identifier, lifecycle == .stopping else {
                if let cleanupError = await awaitCleanup(beginCleanup()) {
                    throw cleanupError
                }
                throw CancellationError()
            }
            try transaction.commit()
            self.operationID = nil
            self.resources = nil
            self.writer = nil
            lifecycle = .finished
            return outputURL
        } catch {
            guard self.operationID == identifier else {
                if let cleanupError = await awaitCleanup(beginCleanup()) {
                    throw cleanupError
                }
                throw CancellationError()
            }
            self.operationID = nil
            lifecycle = error is CancellationError ? .cancelled : .failed
            let cleanupError = await awaitCleanup(beginCleanup())
            throw cleanupError ?? error
        }
    }

    func cancel() async {
        let shouldRemoveCompletedOutput = lifecycle == .finished
        operationID = nil
        lifecycle = .cancelled
        _ = await awaitCleanup(beginCleanup(removeOutput: shouldRemoveCompletedOutput))
    }

    private func beginCleanup(removeOutput: Bool = false) -> CleanupOperation {
        if let cleanupOperation { return cleanupOperation }
        let resources = resources
        let writer = writer
        self.resources = nil
        self.writer = nil
        let mediaQueue = mediaQueue
        let failureRelay = failureRelay
        let transaction = transaction
        let operation = CleanupOperation(task: Task {
            var cleanupError: RecordingError?
            await resources?.stop()
            await mediaQueue.drain()
            do {
                try await mediaQueue.performThrowing { try writer?.cancel() }
            } catch {
                cleanupError = Self.recordingError(from: error)
            }
            do {
                try transaction.rollbackThrowing(removeOutput: removeOutput)
            } catch where cleanupError == nil {
                cleanupError = Self.recordingError(from: error)
            } catch {}
            if let cleanupError {
                failureRelay.report(cleanupError)
            }
            failureRelay.finish()
            return cleanupError
        })
        cleanupOperation = operation
        return operation
    }

    private func awaitCleanup(_ operation: CleanupOperation) async -> RecordingError? {
        await operation.task.value
    }

    private nonisolated static func recordingError(from error: Error) -> RecordingError {
        error as? RecordingError ?? .gifCleanupFailed(error.localizedDescription)
    }
}

private actor ScreenCaptureGIFResource: GIFCaptureResource {
    private let stream: SCStream
    private let delegate: GIFRecordingStreamDelegate
    private let teardown: SharedTeardown
    private var isStopped = false

    private init(stream: SCStream, delegate: GIFRecordingStreamDelegate) {
        self.stream = stream
        self.delegate = delegate
        teardown = SharedTeardown {
            delegate.invalidate()
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(delegate, type: .screen)
        }
    }

    static func make(
        request: RecordingRequest,
        mediaQueue: DispatchQueue,
        writer: GIFMediaWriter
    ) async throws -> ScreenCaptureGIFResource {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let filter: SCContentFilter
        switch request.target {
        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordingError.sourceUnavailable
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingError.sourceUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        let pixelSize = GIFFrameGeometry.boundedPixelSize(
            contentRect: filter.contentRect,
            pointPixelScale: CGFloat(filter.pointPixelScale),
            maxPixelSize: 1_280
        )

        let configuration = SCStreamConfiguration()
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(request.framesPerSecond)
        )
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let delegate = GIFRecordingStreamDelegate(writer: writer, mediaQueue: mediaQueue)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: mediaQueue)
        return ScreenCaptureGIFResource(stream: stream, delegate: delegate)
    }

    func start() async throws {
        guard !isStopped else { throw CancellationError() }
        try await stream.startCapture()
        guard !isStopped else {
            await stop()
            throw CancellationError()
        }
    }

    func stop() async {
        isStopped = true
        await teardown.run()
    }

}

private final class GIFRecordingStreamDelegate: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable {
    private let writer: GIFMediaWriter
    private let mediaQueue: DispatchQueue
    private let lock = NSLock()
    private var isActive = true

    init(writer: GIFMediaWriter, mediaQueue: DispatchQueue) {
        self.writer = writer
        self.mediaQueue = mediaQueue
    }

    func invalidate() {
        lock.withLock { isActive = false }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        writer.appendVideo(sampleBuffer, sourceClock: stream.synchronizationClock)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        mediaQueue.async { [weak self] in
            guard let self, self.lock.withLock({ self.isActive }) else { return }
            self.writer.recordFailure(RecordingError.recordingFailed(error.localizedDescription))
        }
    }
}

actor MP4RecordingSession: RecordingSession {
    private struct CleanupOperation {
        let task: Task<Void, Never>
    }

    private enum Lifecycle {
        case idle
        case starting
        case running
        case stopping
        case cancelled
        case finished
        case failed
    }

    nonisolated let failureEvents: AsyncStream<RecordingError>
    let outputURL: URL

    private let request: RecordingRequest
    private let locations: RecordingFileLocations
    private let transaction: RecordingOutputTransaction
    private let microphoneAuthorization: @Sendable () async -> Bool
    private let failureRelay: RecordingFailureRelay
    private let mediaQueue = DispatchQueue(label: "com.bruno.takeashot.recording.media", qos: .userInitiated)
    private var lifecycle: Lifecycle = .idle
    private var operationID: UUID?
    private var writer: MP4MediaWriter?
    private var resources: RecordingCaptureResources?
    private var cleanupOperation: CleanupOperation?

    init(
        request: RecordingRequest,
        locations: RecordingFileLocations,
        microphoneAuthorization: (@Sendable () async -> Bool)? = nil
    ) {
        let failureRelay = RecordingFailureRelay()
        failureEvents = failureRelay.events
        self.failureRelay = failureRelay
        self.request = request
        self.locations = locations
        outputURL = locations.outputURL
        transaction = RecordingOutputTransaction(locations: locations)
        self.microphoneAuthorization = microphoneAuthorization ?? {
            await Self.requestMicrophoneAuthorization()
        }
    }

    func start() async throws {
        guard lifecycle == .idle else {
            throw RecordingError.invalidTransition(.start, .preparing)
        }
        let identifier = UUID()
        operationID = identifier
        lifecycle = .starting

        do {
            if request.includesMicrophone, !(await microphoneAuthorization()) {
                throw RecordingError.microphonePermissionDenied
            }
            guard operationID == identifier, lifecycle == .starting else {
                throw CancellationError()
            }
            guard CGPreflightScreenCaptureAccess() else {
                throw RecordingError.screenRecordingPermissionDenied
            }

            try transaction.prepare()
            let setup = try await Self.makeStreamSetup(for: request)
            guard operationID == identifier, lifecycle == .starting else {
                throw CancellationError()
            }

            let streamPlan = try RecordingStreamPlan(
                request: request,
                pixelSize: setup.pixelSize
            )
            let writer = try MP4MediaWriter(
                temporaryURL: locations.temporaryURL,
                plan: streamPlan,
                includesSystemAudio: request.includesSystemAudio,
                includesMicrophone: request.includesMicrophone,
                failureRelay: failureRelay
            )
            self.writer = writer
            try await mediaQueue.performThrowing { try writer.start() }
            guard operationID == identifier, lifecycle == .starting else {
                throw CancellationError()
            }

            let delegate = RecordingStreamDelegate(
                writer: writer,
                mediaQueue: mediaQueue
            )
            let stream = SCStream(
                filter: setup.filter,
                configuration: Self.streamConfiguration(plan: streamPlan, request: request),
                delegate: delegate
            )
            try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: mediaQueue)
            if request.includesSystemAudio {
                try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: mediaQueue)
            }

            let microphone: MicrophoneCapture?
            if request.includesMicrophone {
                microphone = try MicrophoneCapture(mediaQueue: mediaQueue) { [writer] sampleBuffer, clock in
                    writer.appendAudio(sampleBuffer, source: .microphone, sourceClock: clock)
                }
            } else {
                microphone = nil
            }
            let resources = RecordingCaptureResources(
                stream: stream,
                streamDelegate: delegate,
                microphone: microphone,
                includesSystemAudio: request.includesSystemAudio
            )
            self.resources = resources

            try await resources.start()
            guard operationID == identifier, lifecycle == .starting else {
                await resources.stop()
                throw CancellationError()
            }
            lifecycle = .running
        } catch {
            guard operationID == identifier else {
                await awaitCleanup(beginCleanup())
                throw CancellationError()
            }
            operationID = nil
            lifecycle = error is CancellationError ? .cancelled : .failed
            await awaitCleanup(beginCleanup())
            throw error
        }
    }

    func stop() async throws -> URL {
        guard lifecycle == .running, let operationID, let resources, let writer else {
            throw RecordingError.invalidTransition(.stop, .idle)
        }
        lifecycle = .stopping
        let identifier = operationID

        do {
            await resources.stop()
            guard self.operationID == identifier, lifecycle == .stopping else {
                await awaitCleanup(beginCleanup())
                throw CancellationError()
            }
            failureRelay.finish()
            await mediaQueue.drain()
            guard self.operationID == identifier, lifecycle == .stopping else {
                await awaitCleanup(beginCleanup())
                throw CancellationError()
            }
            try await writer.finish(on: mediaQueue)
            guard self.operationID == identifier, lifecycle == .stopping else {
                await awaitCleanup(beginCleanup())
                throw CancellationError()
            }
            try transaction.commit()
            self.operationID = nil
            self.resources = nil
            self.writer = nil
            lifecycle = .finished
            return outputURL
        } catch {
            guard self.operationID == identifier else {
                await awaitCleanup(beginCleanup())
                throw CancellationError()
            }
            self.operationID = nil
            lifecycle = error is CancellationError ? .cancelled : .failed
            await awaitCleanup(beginCleanup())
            throw error
        }
    }

    func cancel() async {
        let shouldRemoveCompletedOutput = lifecycle == .finished
        operationID = nil
        lifecycle = .cancelled
        await awaitCleanup(beginCleanup(removeOutput: shouldRemoveCompletedOutput))
    }

    private func beginCleanup(removeOutput: Bool = false) -> CleanupOperation {
        if let cleanupOperation { return cleanupOperation }
        let resources = resources
        let writer = writer
        self.resources = nil
        self.writer = nil
        let mediaQueue = mediaQueue
        let failureRelay = failureRelay
        let transaction = transaction
        let operation = CleanupOperation(task: Task {
            await resources?.stop()
            await mediaQueue.drain()
            await mediaQueue.perform { writer?.cancel() }
            failureRelay.finish()
            transaction.rollback(removeOutput: removeOutput)
        })
        cleanupOperation = operation
        return operation
    }

    private func awaitCleanup(_ operation: CleanupOperation) async {
        await operation.task.value
    }

    private static func requestMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private struct StreamSetup {
        let filter: SCContentFilter
        let pixelSize: PixelSize
    }

    private static func makeStreamSetup(for request: RecordingRequest) async throws -> StreamSetup {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        switch request.target {
        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordingError.sourceUnavailable
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            return StreamSetup(
                filter: filter,
                pixelSize: PixelSize(
                    width: max(2, Int(display.frame.width * CGFloat(filter.pointPixelScale))),
                    height: max(2, Int(display.frame.height * CGFloat(filter.pointPixelScale)))
                )
            )
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingError.sourceUnavailable
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return StreamSetup(
                filter: filter,
                pixelSize: PixelSize(
                    width: max(2, Int(window.frame.width * CGFloat(filter.pointPixelScale))),
                    height: max(2, Int(window.frame.height * CGFloat(filter.pointPixelScale)))
                )
            )
        }
    }

    private static func streamConfiguration(
        plan: RecordingStreamPlan,
        request: RecordingRequest
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = plan.pixelSize.width
        configuration.height = plan.pixelSize.height
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(plan.framesPerSecond)
        )
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = request.includesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = plan.audioSampleRate
        configuration.channelCount = plan.audioChannelCount
        return configuration
    }
}

actor SharedTeardown {
    typealias Operation = @Sendable () async -> Void

    private var operation: Operation?
    private var task: Task<Void, Never>?

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func run() async {
        let task: Task<Void, Never>
        if let existing = self.task {
            task = existing
        } else if let operation {
            self.operation = nil
            task = Task { await operation() }
            self.task = task
        } else {
            return
        }
        await task.value
    }
}

private actor RecordingCaptureResources {
    private let stream: SCStream
    private let streamDelegate: RecordingStreamDelegate
    private let microphone: MicrophoneCapture?
    private let teardown: SharedTeardown
    private var isStopped = false

    init(
        stream: SCStream,
        streamDelegate: RecordingStreamDelegate,
        microphone: MicrophoneCapture?,
        includesSystemAudio: Bool
    ) {
        self.stream = stream
        self.streamDelegate = streamDelegate
        self.microphone = microphone
        teardown = SharedTeardown {
            streamDelegate.invalidate()
            try? await stream.stopCapture()
            await microphone?.stop()
            try? stream.removeStreamOutput(streamDelegate, type: .screen)
            if includesSystemAudio {
                try? stream.removeStreamOutput(streamDelegate, type: .audio)
            }
        }
    }

    func start() async throws {
        guard !isStopped else { throw CancellationError() }
        try await stream.startCapture()
        guard !isStopped else {
            await stop()
            throw CancellationError()
        }
        do {
            try await microphone?.start()
        } catch {
            await stop()
            throw error
        }
        guard !isStopped else {
            await stop()
            throw CancellationError()
        }
    }

    func stop() async {
        isStopped = true
        await teardown.run()
    }
}

private final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    typealias SampleHandler = @Sendable (CMSampleBuffer, CMClock?) -> Void

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let controlQueue = DispatchQueue(label: "com.bruno.takeashot.recording.microphone")
    private let sampleHandler: SampleHandler

    init(mediaQueue: DispatchQueue, sampleHandler: @escaping SampleHandler) throws {
        self.sampleHandler = sampleHandler
        super.init()

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw RecordingError.recordingFailed("No microphone is available.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
        ]

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw RecordingError.recordingFailed("The microphone capture session could not be configured.")
        }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: mediaQueue)
    }

    func start() async throws {
        try await controlQueue.performThrowing {
            self.session.startRunning()
            guard self.session.isRunning else {
                throw RecordingError.recordingFailed("The microphone did not start.")
            }
        }
    }

    func stop() async {
        await controlQueue.perform {
            self.output.setSampleBufferDelegate(nil, queue: nil)
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        sampleHandler(sampleBuffer, session.synchronizationClock)
    }
}

private final class RecordingStreamDelegate: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: MP4MediaWriter
    private let mediaQueue: DispatchQueue
    private let lock = NSLock()
    private var isActive = true

    init(
        writer: MP4MediaWriter,
        mediaQueue: DispatchQueue
    ) {
        self.writer = writer
        self.mediaQueue = mediaQueue
    }

    func invalidate() {
        lock.withLock { isActive = false }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        switch outputType {
        case .screen:
            writer.appendVideo(sampleBuffer, sourceClock: stream.synchronizationClock)
        case .audio:
            writer.appendAudio(sampleBuffer, source: .system, sourceClock: stream.synchronizationClock)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        mediaQueue.async { [weak self] in
            guard let self, self.lock.withLock({ self.isActive }) else { return }
            let failure = RecordingError.recordingFailed(error.localizedDescription)
            self.writer.recordFailure(failure)
        }
    }
}

enum RecordingAudioSource: Hashable, Sendable {
    case system
    case microphone
}

protocol RecordingAudioInput: AnyObject {
    var isReadyForMoreMediaData: Bool { get }
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool
}

extension AVAssetWriterInput: RecordingAudioInput {}

final class BufferedAudioAppender: @unchecked Sendable {
    private let input: any RecordingAudioInput
    private let capacity: Int
    private let writerError: () -> Error?
    private var buffers: [CMSampleBuffer] = []

    init(
        input: any RecordingAudioInput,
        capacity: Int,
        writerError: @escaping () -> Error?
    ) {
        precondition(capacity > 0)
        self.input = input
        self.capacity = capacity
        self.writerError = writerError
    }

    var count: Int { buffers.count }
    var isEmpty: Bool { buffers.isEmpty }

    func enqueue(_ sampleBuffer: CMSampleBuffer) throws {
        try drainReadyBuffers()
        guard buffers.count < capacity else {
            throw RecordingError.audioBackpressureOverflow(limit: capacity)
        }
        buffers.append(sampleBuffer)
        try drainReadyBuffers()
    }

    func drainUntilEmpty(
        on queue: DispatchQueue,
        timeout: Duration,
        pollInterval: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            try Task.checkCancellation()
            let isEmpty = try await queue.performThrowing { [self] in
                try drainReadyBuffers()
                return buffers.isEmpty
            }
            if isEmpty { return }
            guard clock.now < deadline else {
                throw RecordingError.audioBackpressureTimeout
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    func removeAll() {
        buffers.removeAll()
    }

    private func drainReadyBuffers() throws {
        if let error = writerError() {
            throw RecordingError.audioWriterFailed(error.localizedDescription)
        }
        while input.isReadyForMoreMediaData, let next = buffers.first {
            guard input.append(next) else {
                throw RecordingError.audioWriterFailed(
                    writerError()?.localizedDescription
                        ?? "An audio buffer could not be appended."
                )
            }
            buffers.removeFirst()
        }
    }
}

final class MP4MediaWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let audioAppender: BufferedAudioAppender?
    private var audioMixer: LiveAudioMixer?
    private var sessionStartTime: CMTime?
    private var pendingAudio: [CMSampleBuffer] = []
    private var failure: Error?
    private let failureRelay: RecordingFailureRelay

    init(
        temporaryURL: URL,
        plan: RecordingStreamPlan,
        includesSystemAudio: Bool,
        includesMicrophone: Bool,
        failureRelay: RecordingFailureRelay
    ) throws {
        self.failureRelay = failureRelay
        writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)

        let pixels = plan.pixelSize.width * plan.pixelSize.height
        let bitrate = min(24_000_000, max(4_000_000, pixels * 5))
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: plan.pixelSize.width,
                AVVideoHeightKey: plan.pixelSize.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: plan.framesPerSecond,
                    AVVideoMaxKeyFrameIntervalKey: plan.framesPerSecond * 2,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecordingError.writerSetupFailed("H.264 video input is unavailable.")
        }
        writer.add(videoInput)

        if plan.audioWriterInputCount == 1 {
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: plan.audioSampleRate,
                    AVNumberOfChannelsKey: plan.audioChannelCount,
                    AVEncoderBitRateKey: 192_000,
                ]
            )
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(audioInput) else {
                throw RecordingError.writerSetupFailed("AAC audio input is unavailable.")
            }
            writer.add(audioInput)
            self.audioInput = audioInput
            let assetWriter = writer
            audioAppender = BufferedAudioAppender(
                input: audioInput,
                capacity: 96,
                writerError: { assetWriter.error }
            )
            audioMixer = try LiveAudioMixer(
                includesSystemAudio: includesSystemAudio,
                includesMicrophone: includesMicrophone,
                sampleRate: plan.audioSampleRate,
                channelCount: plan.audioChannelCount
            )
        } else {
            audioInput = nil
            audioAppender = nil
            audioMixer = nil
        }
    }

    func start() throws {
        guard writer.startWriting() else {
            throw RecordingError.writerSetupFailed(
                writer.error?.localizedDescription ?? "AVAssetWriter could not start."
            )
        }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, sourceClock: CMClock?) {
        guard failure == nil,
              CMSampleBufferDataIsReady(sampleBuffer),
              sampleBuffer.hasCompleteScreenFrame else { return }
        do {
            let retimed = try sampleBuffer.retimedToHostClock(from: sourceClock)
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(retimed)
            guard presentationTime.isValid else { return }

            if sessionStartTime == nil {
                writer.startSession(atSourceTime: presentationTime)
                sessionStartTime = presentationTime
                try flushPendingAudio()
            }
            if let error = writer.error {
                throw error
            }
            guard videoInput.isReadyForMoreMediaData else { return }
            guard videoInput.append(retimed) else {
                throw writer.error ?? RecordingError.recordingFailed("A video frame could not be written.")
            }
        } catch {
            recordFailure(error)
        }
    }

    func appendAudio(
        _ sampleBuffer: CMSampleBuffer,
        source: RecordingAudioSource,
        sourceClock: CMClock?
    ) {
        guard failure == nil, let audioMixer else { return }
        do {
            let buffers = try audioMixer.append(
                sampleBuffer,
                source: source,
                sourceClock: sourceClock
            )
            for buffer in buffers {
                try appendMixedAudio(buffer)
            }
        } catch {
            recordFailure(error)
        }
    }

    @discardableResult
    func recordFailure(_ error: Error) -> Bool {
        guard failure == nil else { return false }
        let recordingError = error as? RecordingError
            ?? RecordingError.recordingFailed(error.localizedDescription)
        failure = recordingError
        return failureRelay.report(recordingError)
    }

    func finish(on queue: DispatchQueue) async throws {
        do {
            try await queue.performThrowing { [self] in
                if let failure { throw failure }
                guard sessionStartTime != nil else {
                    throw RecordingError.recordingFailed("No video frames were captured.")
                }
                if let audioMixer {
                    for buffer in try audioMixer.finish() {
                        try appendMixedAudio(buffer)
                    }
                }
                if let failure { throw failure }
            }
            if let audioAppender {
                try await audioAppender.drainUntilEmpty(
                    on: queue,
                    timeout: .seconds(2),
                    pollInterval: .milliseconds(5)
                )
            }
            try await queue.performThrowing { [self] in
                if let failure { throw failure }
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
            }
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    writer.finishWriting {
                        if self.writer.status == .completed {
                            continuation.resume()
                        } else {
                            continuation.resume(
                                throwing: self.writer.error
                                    ?? RecordingError.recordingFailed("AVAssetWriter did not finish successfully.")
                            )
                        }
                    }
                }
            }
        } catch {
            await queue.perform { [self] in writer.cancelWriting() }
            throw error
        }
    }

    func cancel() {
        pendingAudio.removeAll()
        audioAppender?.removeAll()
        audioMixer?.reset()
        if writer.status == .writing || writer.status == .unknown {
            writer.cancelWriting()
        }
    }

    private func appendMixedAudio(_ sampleBuffer: CMSampleBuffer) throws {
        guard let audioAppender else { return }
        guard let sessionStartTime else {
            guard pendingAudio.count < 96 else {
                throw RecordingError.audioBackpressureOverflow(limit: 96)
            }
            pendingAudio.append(sampleBuffer)
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime >= sessionStartTime else { return }
        try audioAppender.enqueue(sampleBuffer)
    }

    private func flushPendingAudio() throws {
        let buffered = pendingAudio
        pendingAudio.removeAll()
        for buffer in buffered {
            try appendMixedAudio(buffer)
        }
    }
}

final class LiveAudioMixer {
    private final class Bucket {
        var system: [Float]
        var microphone: [Float]
        var validFrames: Int

        init(system: [Float], microphone: [Float], validFrames: Int) {
            self.system = system
            self.microphone = microphone
            self.validFrames = validFrames
        }
    }

    private struct ConverterState {
        let inputFormat: AVAudioFormat
        let converter: AVAudioConverter
    }

    private let includesSystemAudio: Bool
    private let includesMicrophone: Bool
    private let sampleRate: Int
    private let channelCount: Int
    private let blockFrames = 1_024
    private let maximumBufferedBlocks = 96
    private let targetFormat: AVAudioFormat
    private let outputFormatDescription: CMAudioFormatDescription
    private var converters: [RecordingAudioSource: ConverterState] = [:]
    private var buckets: [Int64: Bucket] = [:]
    private var latestEnds: [RecordingAudioSource: Int64] = [:]

    init(
        includesSystemAudio: Bool,
        includesMicrophone: Bool,
        sampleRate: Int,
        channelCount: Int
    ) throws {
        self.includesSystemAudio = includesSystemAudio
        self.includesMicrophone = includesMicrophone
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channelCount)
        ) else {
            throw RecordingError.writerSetupFailed("The audio mix format is unavailable.")
        }
        self.targetFormat = targetFormat

        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw RecordingError.writerSetupFailed("The mixed audio description could not be created (\(status)).")
        }
        outputFormatDescription = formatDescription
    }

    func append(
        _ sampleBuffer: CMSampleBuffer,
        source: RecordingAudioSource,
        sourceClock: CMClock?
    ) throws -> [CMSampleBuffer] {
        let converted = try convertedSamples(from: sampleBuffer, source: source)
        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime: CMTime
        if let sourceClock {
            hostTime = CMSyncConvertTime(
                sourceTime,
                from: sourceClock,
                to: CMClockGetHostTimeClock()
            )
        } else {
            hostTime = sourceTime
        }
        guard hostTime.isValid else { return [] }
        let startSample = CMTimeConvertScale(
            hostTime,
            timescale: CMTimeScale(sampleRate),
            method: .default
        ).value
        insert(converted, source: source, startSample: startSample)

        var ready = try flushReadyBuckets()
        while buckets.count > maximumBufferedBlocks, let oldest = buckets.keys.min() {
            if let sample = try flushBucket(start: oldest) {
                ready.append(sample)
            }
        }
        return ready
    }

    func finish() throws -> [CMSampleBuffer] {
        try buckets.keys.sorted().compactMap(flushBucket)
    }

    func reset() {
        buckets.removeAll()
        latestEnds.removeAll()
        converters.removeAll()
    }

    private func insert(
        _ channels: [[Float]],
        source: RecordingAudioSource,
        startSample: Int64
    ) {
        let frameCount = channels.first?.count ?? 0
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            let absoluteSample = startSample + Int64(frame)
            let blockStart = absoluteSample - absoluteSample.quotientAndRemainder(
                dividingBy: Int64(blockFrames)
            ).remainder
            let frameOffset = Int(absoluteSample - blockStart)
            let bucket = buckets[blockStart] ?? Bucket(
                system: Array(repeating: 0, count: blockFrames * channelCount),
                microphone: Array(repeating: 0, count: blockFrames * channelCount),
                validFrames: 0
            )
            for channel in 0..<channelCount {
                let value = channels[min(channel, channels.count - 1)][frame]
                let index = frameOffset * channelCount + channel
                switch source {
                case .system:
                    bucket.system[index] += value
                case .microphone:
                    bucket.microphone[index] += value
                }
            }
            bucket.validFrames = max(bucket.validFrames, frameOffset + 1)
            buckets[blockStart] = bucket
        }
        latestEnds[source] = max(latestEnds[source] ?? .min, startSample + Int64(frameCount))
    }

    private func flushReadyBuckets() throws -> [CMSampleBuffer] {
        let cutoff: Int64?
        if includesSystemAudio && includesMicrophone {
            if let systemEnd = latestEnds[.system], let microphoneEnd = latestEnds[.microphone] {
                cutoff = min(systemEnd, microphoneEnd)
            } else {
                cutoff = nil
            }
        } else if includesSystemAudio {
            cutoff = latestEnds[.system]
        } else {
            cutoff = latestEnds[.microphone]
        }
        guard let cutoff else { return [] }
        let readyStarts = buckets.keys
            .filter { $0 + Int64(blockFrames) <= cutoff }
            .sorted()
        return try readyStarts.compactMap(flushBucket)
    }

    private func flushBucket(start: Int64) throws -> CMSampleBuffer? {
        guard let bucket = buckets.removeValue(forKey: start), bucket.validFrames > 0 else {
            return nil
        }
        let sampleCount = bucket.validFrames * channelCount
        let mixed = AudioFrameMixer.mix(
            system: Array(bucket.system.prefix(sampleCount)),
            microphone: Array(bucket.microphone.prefix(sampleCount))
        )
        return try makeSampleBuffer(samples: mixed, frameCount: bucket.validFrames, start: start)
    }

    private func convertedSamples(
        from sampleBuffer: CMSampleBuffer,
        source: RecordingAudioSource
    ) throws -> [[Float]] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let inputFormat = AVAudioFormat(streamDescription: streamDescription) else {
            throw RecordingError.recordingFailed("An audio sample had no readable format.")
        }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return []
        }
        try copyAudioData(from: sampleBuffer, into: inputBuffer, frameCount: frameCount)

        let state: ConverterState
        if let existing = converters[source], existing.inputFormat == inputFormat {
            state = existing
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw RecordingError.recordingFailed("An audio source could not be converted for mixing.")
            }
            state = ConverterState(inputFormat: inputFormat, converter: converter)
            converters[source] = state
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw RecordingError.recordingFailed("The audio mix buffer could not be allocated.")
        }
        var suppliedInput = false
        var conversionError: NSError?
        let conversionStatus = state.converter.convert(to: outputBuffer, error: &conversionError) {
            _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return inputBuffer
        }
        guard conversionStatus != .error, conversionError == nil else {
            throw conversionError
                ?? RecordingError.recordingFailed("An audio source could not be converted.")
        }
        guard let channelData = outputBuffer.floatChannelData else {
            throw RecordingError.recordingFailed("Converted audio was not floating-point PCM.")
        }
        let outputFrames = Int(outputBuffer.frameLength)
        return (0..<channelCount).map { channel in
            Array(UnsafeBufferPointer(start: channelData[channel], count: outputFrames))
        }
    }

    private func copyAudioData(
        from sampleBuffer: CMSampleBuffer,
        into target: AVAudioPCMBuffer,
        frameCount: AVAudioFrameCount
    ) throws {
        var listSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, listSize >= MemoryLayout<AudioBufferList>.size else {
            throw RecordingError.recordingFailed("Audio buffer sizing failed (\(sizeStatus)).")
        }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else {
            throw RecordingError.recordingFailed("Audio data could not be read (\(status)).")
        }
        target.frameLength = frameCount
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(list)
        let targetBuffers = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        for index in 0..<min(sourceBuffers.count, targetBuffers.count) {
            guard let sourceData = sourceBuffers[index].mData,
                  let targetData = targetBuffers[index].mData else { continue }
            let byteCount = min(
                Int(sourceBuffers[index].mDataByteSize),
                Int(targetBuffers[index].mDataByteSize)
            )
            memcpy(targetData, sourceData, byteCount)
        }
        withExtendedLifetime(retainedBlockBuffer) {}
    }

    private func makeSampleBuffer(
        samples: [Float],
        frameCount: Int,
        start: Int64
    ) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw RecordingError.recordingFailed("A mixed audio block could not be allocated (\(status)).")
        }
        status = samples.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw RecordingError.recordingFailed("Mixed audio data could not be copied (\(status)).")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: outputFormatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw RecordingError.recordingFailed("A mixed audio sample could not be created (\(status)).")
        }
        return sampleBuffer
    }
}

private extension CMSampleBuffer {
    var completeScreenFrameMetadata: GIFFrameMetadata? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            self,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let values = attachments.first,
        let rawStatus = values[.status] as? Int,
        SCFrameStatus(rawValue: rawStatus) == .complete,
        let rawContentRect = values[.contentRect] as CFTypeRef?,
        CFGetTypeID(rawContentRect) == CFDictionaryGetTypeID(),
        let contentRectDictionary = rawContentRect as? NSDictionary,
        let contentRect = CGRect(dictionaryRepresentation: contentRectDictionary),
        let contentScale = values[.contentScale] as? CGFloat,
        let scaleFactor = values[.scaleFactor] as? CGFloat else {
            return nil
        }
        return GIFFrameMetadata(
            contentRect: contentRect,
            contentScale: contentScale,
            scaleFactor: scaleFactor
        )
    }

    var hasCompleteScreenFrame: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            self,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let rawValue = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: rawValue) else {
            return false
        }
        return status == .complete
    }

    func retimedToHostClock(from sourceClock: CMClock?) throws -> CMSampleBuffer {
        guard let sourceClock else { return self }
        var timingCount = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(
            self,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        guard status == noErr else {
            throw RecordingError.recordingFailed("Video timing could not be read (\(status)).")
        }
        var timings = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: timingCount
        )
        status = CMSampleBufferGetSampleTimingInfoArray(
            self,
            entryCount: timingCount,
            arrayToFill: &timings,
            entriesNeededOut: &timingCount
        )
        guard status == noErr else {
            throw RecordingError.recordingFailed("Video timing could not be copied (\(status)).")
        }
        let hostClock = CMClockGetHostTimeClock()
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMSyncConvertTime(
                    timings[index].presentationTimeStamp,
                    from: sourceClock,
                    to: hostClock
                )
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMSyncConvertTime(
                    timings[index].decodeTimeStamp,
                    from: sourceClock,
                    to: hostClock
                )
            }
        }
        var retimed: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: self,
            sampleTimingEntryCount: timings.count,
            sampleTimingArray: &timings,
            sampleBufferOut: &retimed
        )
        guard status == noErr, let retimed else {
            throw RecordingError.recordingFailed("Video timing could not be synchronized (\(status)).")
        }
        return retimed
    }
}

private extension DispatchQueue {
    func performThrowing<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func perform<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            async {
                continuation.resume(returning: operation())
            }
        }
    }

    func drain() async {
        await perform {}
    }
}
