import AVFoundation
import XCTest
@testable import TakeAShot

final class RecordingStateTests: XCTestCase {
    func testSuccessfulRecordingTransitionsAndPublishesOutput() async throws {
        let session = RecordingSessionSpy()
        let engine = RecordingEngine(sessionFactory: { _ in session })

        try await engine.start(request: .testMP4)
        guard case .recording = await engine.state else {
            return XCTFail("Expected recording state")
        }

        let output = try await engine.stop()
        let sessionOutput = session.outputURL
        let completedState = await engine.state

        XCTAssertEqual(output, sessionOutput)
        XCTAssertEqual(completedState, .completed(output))
    }

    func testCancellationRemovesTemporaryOutputAndReturnsToIdle() async throws {
        let session = RecordingSessionSpy()
        let engine = RecordingEngine(sessionFactory: { _ in session })
        try await engine.start(request: .testMP4)

        await engine.cancel()
        let removedTemporaryOutput = await session.removedTemporaryOutput
        let state = await engine.state

        XCTAssertTrue(removedTemporaryOutput)
        XCTAssertEqual(state, .idle)
    }

    func testMicrophoneDenialBecomesTypedFailure() async {
        let session = RecordingSessionSpy(startError: .microphonePermissionDenied)
        let engine = RecordingEngine(sessionFactory: { _ in session })

        do {
            try await engine.start(request: .testMP4WithMicrophone)
            XCTFail("Expected microphone permission denial")
        } catch {
            XCTAssertEqual(error as? RecordingError, .microphonePermissionDenied)
        }

        let state = await engine.state
        let removedTemporaryOutput = await session.removedTemporaryOutput
        XCTAssertEqual(
            state,
            .failed(RecordingError.microphonePermissionDenied.localizedDescription)
        )
        XCTAssertTrue(removedTemporaryOutput)
    }

    func testStopFailureCleansUpAndBecomesFailedState() async throws {
        let failure = RecordingError.recordingFailed("disk full")
        let session = RecordingSessionSpy(stopError: failure)
        let engine = RecordingEngine(sessionFactory: { _ in session })
        try await engine.start(request: .testMP4)

        do {
            _ = try await engine.stop()
            XCTFail("Expected stop failure")
        } catch {
            XCTAssertEqual(error as? RecordingError, failure)
        }

        let state = await engine.state
        let removedTemporaryOutput = await session.removedTemporaryOutput
        XCTAssertEqual(state, .failed(failure.localizedDescription))
        XCTAssertTrue(removedTemporaryOutput)
    }

    func testSecondStartWhilePreparingIsRejectedAndLateStartCannotOverwriteCancellation() async throws {
        let gate = AsyncGate()
        let session = RecordingSessionSpy(startGate: gate)
        let engine = RecordingEngine(sessionFactory: { _ in session })
        let firstStart = Task { try await engine.start(request: .testMP4) }
        await session.waitUntilStartEntered()

        await XCTAssertThrowsRecordingError(.invalidTransition(.start, .preparing)) {
            try await engine.start(request: .testMP4)
        }

        await engine.cancel()
        await gate.open()
        do {
            try await firstStart.value
            XCTFail("Expected cancelled start")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let state = await engine.state
        let removedTemporaryOutput = await session.removedTemporaryOutput
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(removedTemporaryOutput)
    }

    func testStopWhilePreparingIsRejectedWithoutChangingPreparation() async throws {
        let gate = AsyncGate()
        let session = RecordingSessionSpy(startGate: gate)
        let engine = RecordingEngine(sessionFactory: { _ in session })
        let start = Task { try await engine.start(request: .testMP4) }
        await session.waitUntilStartEntered()

        await XCTAssertThrowsRecordingError(.invalidTransition(.stop, .preparing)) {
            _ = try await engine.stop()
        }
        let state = await engine.state
        XCTAssertEqual(state, .preparing)

        await engine.cancel()
        await gate.open()
        _ = try? await start.value
    }

    func testCancellationWhileStoppingPreventsLateCompletionPublishingOutput() async throws {
        let gate = AsyncGate()
        let session = RecordingSessionSpy(stopGate: gate)
        let engine = RecordingEngine(sessionFactory: { _ in session })
        try await engine.start(request: .testMP4)
        let stop = Task { try await engine.stop() }
        await session.waitUntilStopEntered()

        await engine.cancel()
        await gate.open()
        do {
            _ = try await stop.value
            XCTFail("Expected cancelled stop")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let state = await engine.state
        let removedTemporaryOutput = await session.removedTemporaryOutput
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(removedTemporaryOutput)
    }

    func testSecondStopWhileStoppingIsRejected() async throws {
        let gate = AsyncGate()
        let session = RecordingSessionSpy(stopGate: gate)
        let engine = RecordingEngine(sessionFactory: { _ in session })
        try await engine.start(request: .testMP4)
        let firstStop = Task { try await engine.stop() }
        await session.waitUntilStopEntered()

        await XCTAssertThrowsRecordingError(.invalidTransition(.stop, .stopping)) {
            _ = try await engine.stop()
        }

        await gate.open()
        _ = try await firstStop.value
    }

    func testStartAfterCompletedCreatesANewSession() async throws {
        let factory = RecordingSessionFactorySpy()
        let engine = RecordingEngine(sessionFactory: { request in
            try factory.makeSession(request: request)
        })

        try await engine.start(request: .testMP4)
        _ = try await engine.stop()
        try await engine.start(request: .testMP4)

        XCTAssertEqual(factory.requestCount, 2)
        guard case .recording = await engine.state else {
            return XCTFail("Expected a new recording")
        }
        await engine.cancel()
    }

    func testRequestRejectsInvalidFrameRatesAndUnsupportedFormat() async {
        let engine = RecordingEngine(sessionFactory: { _ in RecordingSessionSpy() })

        await XCTAssertThrowsRecordingError(.invalidFrameRate(0)) {
            try await engine.start(request: .testMP4.withFrameRate(0))
        }
        await XCTAssertThrowsRecordingError(.invalidFrameRate(31)) {
            try await engine.start(request: .testMP4.withFrameRate(31))
        }
        await XCTAssertThrowsRecordingError(.unsupportedFormat(.gif)) {
            try await engine.start(request: .testGIF)
        }
    }

    func testFileLocationsKeepTemporaryAndCompletedFilesInLibraryRoot() throws {
        let root = URL(fileURLWithPath: "/Library/Application Support/TakeAShot", isDirectory: true)
        let locations = RecordingFileLocations(rootURL: root, identifier: UUID())

        XCTAssertEqual(
            locations.temporaryURL.deletingLastPathComponent().path,
            root.appendingPathComponent("temporary").path
        )
        XCTAssertEqual(
            locations.outputURL.deletingLastPathComponent().path,
            root.appendingPathComponent("originals").path
        )
        XCTAssertEqual(locations.temporaryURL.pathExtension, "mp4")
        XCTAssertEqual(locations.outputURL.pathExtension, "mp4")
        XCTAssertNotEqual(locations.temporaryURL, locations.outputURL)
    }

    func testDefaultFileLocationsUseApplicationSupportLibrary() throws {
        let locations = try RecordingFileLocations.default(identifier: UUID())

        XCTAssertTrue(locations.outputURL.path.contains("/Application Support/TakeAShot/originals/"))
        XCTAssertTrue(locations.temporaryURL.path.contains("/Application Support/TakeAShot/temporary/"))
    }

    func testOutputTransactionMovesCompletedFileAndRollsBackTemporaryFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let committed = RecordingFileLocations(rootURL: root, identifier: UUID())
        let transaction = RecordingOutputTransaction(locations: committed)
        try transaction.prepare()
        try Data("complete".utf8).write(to: committed.temporaryURL)

        try transaction.commit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.temporaryURL.path))
        XCTAssertEqual(try Data(contentsOf: committed.outputURL), Data("complete".utf8))

        let cancelled = RecordingFileLocations(rootURL: root, identifier: UUID())
        let cancelledTransaction = RecordingOutputTransaction(locations: cancelled)
        try cancelledTransaction.prepare()
        try Data("partial".utf8).write(to: cancelled.temporaryURL)

        cancelledTransaction.rollback()

        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.outputURL.path))
    }

    func testMP4StreamPlanUsesBoundedH264AndOneMixedAACTrack() throws {
        let request = RecordingRequest(
            target: .display(1),
            format: .mp4,
            includesSystemAudio: true,
            includesMicrophone: true,
            framesPerSecond: 30
        )

        let plan = try RecordingStreamPlan(
            request: request,
            pixelSize: PixelSize(width: 2561, height: 1441)
        )

        XCTAssertEqual(plan.framesPerSecond, 30)
        XCTAssertEqual(plan.pixelSize, PixelSize(width: 2560, height: 1440))
        XCTAssertEqual(plan.videoCodec, .h264)
        XCTAssertEqual(plan.audioWriterInputCount, 1)
        XCTAssertTrue(plan.mixesAudioSources)
        XCTAssertEqual(plan.audioSampleRate, 48_000)
        XCTAssertEqual(plan.audioChannelCount, 2)
    }

    func testAudioFrameMixerMakesBothSourcesAudibleAndClampsOverflow() {
        let mixed = AudioFrameMixer.mix(
            system: [0.25, -0.25, 0.8, -0.8],
            microphone: [0.5, -0.9, 0.5, -0.5]
        )

        XCTAssertEqual(mixed, [0.75, -1, 1, -1])
    }

    func testLiveAudioMixerEmitsOneBufferContainingBothSources() throws {
        let mixer = try LiveAudioMixer(
            includesSystemAudio: true,
            includesMicrophone: true,
            sampleRate: 48_000,
            channelCount: 2
        )
        let system = try makePCMSampleBuffer(
            samples: Array(repeating: 0.25, count: 2_048),
            frameCount: 1_024,
            presentationTime: .zero
        )
        let microphone = try makePCMSampleBuffer(
            samples: Array(repeating: 0.5, count: 2_048),
            frameCount: 1_024,
            presentationTime: .zero
        )

        XCTAssertTrue(try mixer.append(system, source: .system, sourceClock: nil).isEmpty)
        let mixedBuffers = try mixer.append(
            microphone,
            source: .microphone,
            sourceClock: nil
        )

        XCTAssertEqual(mixedBuffers.count, 1)
        let mixedSamples = try pcmSamples(from: XCTUnwrap(mixedBuffers.first), count: 2_048)
        XCTAssertEqual(mixedSamples[0], 0.75, accuracy: 0.0001)
        XCTAssertEqual(mixedSamples[1], 0.75, accuracy: 0.0001)
    }

    func testGeneratedInfoPlistExplainsRecordingPermissions() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
            "Take a Shot uses the microphone only when you enable microphone audio for a recording."
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") as? String,
            "Take a Shot needs Screen Recording access to capture the display or a selected window."
        )
    }

    func testProductionSessionSurfacesMicrophoneDenialWithoutFallback() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = RecordingFileLocations(rootURL: root, identifier: UUID())
        let session = MP4RecordingSession(
            request: .testMP4WithMicrophone,
            locations: locations,
            microphoneAuthorization: { false }
        )

        do {
            try await session.start()
            XCTFail("Expected microphone permission denial")
        } catch {
            XCTAssertEqual(error as? RecordingError, .microphonePermissionDenied)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.outputURL.path))
    }
}

private extension RecordingRequest {
    static let testMP4 = RecordingRequest(
        target: .display(1),
        format: .mp4,
        includesSystemAudio: false,
        includesMicrophone: false,
        framesPerSecond: 30
    )

    static let testMP4WithMicrophone = RecordingRequest(
        target: .display(1),
        format: .mp4,
        includesSystemAudio: false,
        includesMicrophone: true,
        framesPerSecond: 30
    )

    static let testGIF = RecordingRequest(
        target: .display(1),
        format: .gif,
        includesSystemAudio: false,
        includesMicrophone: false,
        framesPerSecond: 10
    )

    func withFrameRate(_ frameRate: Int) -> RecordingRequest {
        RecordingRequest(
            target: target,
            format: format,
            includesSystemAudio: includesSystemAudio,
            includesMicrophone: includesMicrophone,
            framesPerSecond: frameRate
        )
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor RecordingSessionSpy: RecordingSession {
    let outputURL = URL(fileURLWithPath: "/tmp/test-recording.mp4")
    private(set) var removedTemporaryOutput = false
    private let startError: RecordingError?
    private let stopError: RecordingError?
    private let startGate: AsyncGate?
    private let stopGate: AsyncGate?
    private var startEnteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var stopEnteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var didEnterStart = false
    private var didEnterStop = false

    init(
        startError: RecordingError? = nil,
        stopError: RecordingError? = nil,
        startGate: AsyncGate? = nil,
        stopGate: AsyncGate? = nil
    ) {
        self.startError = startError
        self.stopError = stopError
        self.startGate = startGate
        self.stopGate = stopGate
    }

    func start() async throws {
        didEnterStart = true
        startEnteredContinuations.forEach { $0.resume() }
        startEnteredContinuations.removeAll()
        if let startGate { await startGate.wait() }
        if let startError { throw startError }
    }

    func stop() async throws -> URL {
        didEnterStop = true
        stopEnteredContinuations.forEach { $0.resume() }
        stopEnteredContinuations.removeAll()
        if let stopGate { await stopGate.wait() }
        if let stopError { throw stopError }
        return outputURL
    }

    func cancel() async {
        removedTemporaryOutput = true
    }

    func waitUntilStartEntered() async {
        guard !didEnterStart else { return }
        await withCheckedContinuation { continuation in
            startEnteredContinuations.append(continuation)
        }
    }

    func waitUntilStopEntered() async {
        guard !didEnterStop else { return }
        await withCheckedContinuation { continuation in
            stopEnteredContinuations.append(continuation)
        }
    }
}

private final class RecordingSessionFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RecordingRequest] = []

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    func makeSession(request: RecordingRequest) throws -> any RecordingSession {
        lock.withLock { requests.append(request) }
        return RecordingSessionSpy()
    }
}

private extension XCTestCase {
    func XCTAssertThrowsRecordingError(
        _ expected: RecordingError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RecordingError, expected, file: file, line: line)
        }
    }
}

private func makePCMSampleBuffer(
    samples: [Float],
    frameCount: Int,
    presentationTime: CMTime
) throws -> CMSampleBuffer {
    var description = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    XCTAssertEqual(
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ),
        noErr
    )
    let format = try XCTUnwrap(formatDescription)
    let byteCount = samples.count * MemoryLayout<Float>.size
    var blockBuffer: CMBlockBuffer?
    XCTAssertEqual(
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ),
        kCMBlockBufferNoErr
    )
    let block = try XCTUnwrap(blockBuffer)
    let copyStatus = samples.withUnsafeBytes { bytes -> OSStatus in
        guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
        return CMBlockBufferReplaceDataBytes(
            with: baseAddress,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
    }
    XCTAssertEqual(copyStatus, kCMBlockBufferNoErr)

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    XCTAssertEqual(
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ),
        noErr
    )
    return try XCTUnwrap(sampleBuffer)
}

private func pcmSamples(from sampleBuffer: CMSampleBuffer, count: Int) throws -> [Float] {
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sampleBuffer))
    var samples = Array(repeating: Float.zero, count: count)
    let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
        guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
        return CMBlockBufferCopyDataBytes(
            block,
            atOffset: 0,
            dataLength: bytes.count,
            destination: baseAddress
        )
    }
    XCTAssertEqual(status, kCMBlockBufferNoErr)
    return samples
}
