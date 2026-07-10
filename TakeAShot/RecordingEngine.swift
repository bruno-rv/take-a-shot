import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

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

    init(rootURL: URL, identifier: UUID) {
        let filename = "\(identifier.uuidString).mp4"
        temporaryURL = rootURL
            .appendingPathComponent("temporary", isDirectory: true)
            .appendingPathComponent(filename)
        outputURL = rootURL
            .appendingPathComponent("originals", isDirectory: true)
            .appendingPathComponent(filename)
    }

    static func `default`(identifier: UUID) throws -> RecordingFileLocations {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return RecordingFileLocations(
            rootURL: applicationSupport.appendingPathComponent("TakeAShot", isDirectory: true),
            identifier: identifier
        )
    }
}

final class RecordingOutputTransaction: @unchecked Sendable {
    private let locations: RecordingFileLocations
    private let fileManager: FileManager

    init(locations: RecordingFileLocations, fileManager: FileManager = .default) {
        self.locations = locations
        self.fileManager = fileManager
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
            try fileManager.removeItem(at: locations.temporaryURL)
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
        try? fileManager.removeItem(at: locations.temporaryURL)
        if removeOutput {
            try? fileManager.removeItem(at: locations.outputURL)
        }
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

    private(set) var state: RecordingState = .idle
    private let sessionFactory: SessionFactory
    private var session: (any RecordingSession)?
    private var operationID: UUID?
    private var failureMonitor: Task<Void, Never>?

    init(sessionFactory: @escaping SessionFactory) {
        self.sessionFactory = sessionFactory
    }

    init() {
        sessionFactory = { request in
            let locations = try RecordingFileLocations.default(identifier: UUID())
            return MP4RecordingSession(request: request, locations: locations)
        }
    }

    func start(request: RecordingRequest) async throws {
        try validate(request)
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
                await newSession.cancel()
                throw CancellationError()
            }
            stopFailureMonitoring()
            operationID = nil
            session = nil
            state = .failed(error.localizedDescription)
            await newSession.cancel()
            throw error
        }

        guard operationID == identifier, state.kind == .preparing else {
            await newSession.cancel()
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
                throw CancellationError()
            }
            operationID = nil
            self.session = nil
            state = .completed(output)
            return output
        } catch {
            guard operationID == identifier else {
                throw CancellationError()
            }
            operationID = nil
            self.session = nil
            state = .failed(error.localizedDescription)
            await session.cancel()
            throw error
        }
    }

    func cancel() async {
        let activeSession = session
        stopFailureMonitoring()
        operationID = nil
        session = nil
        state = .idle
        await activeSession?.cancel()
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
        await failedSession.cancel()
    }

    private func stopFailureMonitoring() {
        failureMonitor?.cancel()
        failureMonitor = nil
    }

    private func validate(_ request: RecordingRequest) throws {
        guard (1...30).contains(request.framesPerSecond) else {
            throw RecordingError.invalidFrameRate(request.framesPerSecond)
        }
        guard request.format == .mp4 else {
            throw RecordingError.unsupportedFormat(request.format)
        }
    }
}

actor MP4RecordingSession: RecordingSession {
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
    private let failureContinuation: AsyncStream<RecordingError>.Continuation
    private let mediaQueue = DispatchQueue(label: "com.bruno.takeashot.recording.media", qos: .userInitiated)
    private var lifecycle: Lifecycle = .idle
    private var operationID: UUID?
    private var writer: MP4MediaWriter?
    private var resources: RecordingCaptureResources?

    init(
        request: RecordingRequest,
        locations: RecordingFileLocations,
        microphoneAuthorization: (@Sendable () async -> Bool)? = nil
    ) {
        let failures = AsyncStream.makeStream(
            of: RecordingError.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        failureEvents = failures.stream
        failureContinuation = failures.continuation
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
                includesMicrophone: request.includesMicrophone
            )
            try await mediaQueue.performThrowing { try writer.start() }
            guard operationID == identifier, lifecycle == .starting else {
                await mediaQueue.perform { writer.cancel() }
                throw CancellationError()
            }
            self.writer = writer

            let delegate = RecordingStreamDelegate(
                writer: writer,
                mediaQueue: mediaQueue,
                failureContinuation: failureContinuation
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
                throw CancellationError()
            }
            operationID = nil
            lifecycle = error is CancellationError ? .cancelled : .failed
            let resources = self.resources
            let writer = self.writer
            self.resources = nil
            self.writer = nil
            await resources?.stop()
            failureContinuation.finish()
            await mediaQueue.perform { writer?.cancel() }
            transaction.rollback()
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
            failureContinuation.finish()
            await mediaQueue.drain()
            try await writer.finish(on: mediaQueue)
            guard self.operationID == identifier, lifecycle == .stopping else {
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
                throw CancellationError()
            }
            self.operationID = nil
            self.resources = nil
            self.writer = nil
            lifecycle = error is CancellationError ? .cancelled : .failed
            await resources.stop()
            failureContinuation.finish()
            await mediaQueue.perform { writer.cancel() }
            transaction.rollback()
            throw error
        }
    }

    func cancel() async {
        let shouldRemoveCompletedOutput = lifecycle == .finished
        operationID = nil
        lifecycle = .cancelled
        let resources = self.resources
        let writer = self.writer
        self.resources = nil
        self.writer = nil
        await resources?.stop()
        failureContinuation.finish()
        await mediaQueue.drain()
        await mediaQueue.perform { writer?.cancel() }
        transaction.rollback(removeOutput: shouldRemoveCompletedOutput)
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
    private let failureContinuation: AsyncStream<RecordingError>.Continuation
    private let lock = NSLock()
    private var isActive = true

    init(
        writer: MP4MediaWriter,
        mediaQueue: DispatchQueue,
        failureContinuation: AsyncStream<RecordingError>.Continuation
    ) {
        self.writer = writer
        self.mediaQueue = mediaQueue
        self.failureContinuation = failureContinuation
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
            self.failureContinuation.yield(failure)
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

private final class MP4MediaWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let audioAppender: BufferedAudioAppender?
    private var audioMixer: LiveAudioMixer?
    private var sessionStartTime: CMTime?
    private var pendingAudio: [CMSampleBuffer] = []
    private var failure: Error?

    init(
        temporaryURL: URL,
        plan: RecordingStreamPlan,
        includesSystemAudio: Bool,
        includesMicrophone: Bool
    ) throws {
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

    func recordFailure(_ error: Error) {
        if failure == nil {
            failure = error
        }
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
