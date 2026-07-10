import AVFoundation
import ImageIO
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

    func testUnexpectedSessionFailureImmediatelyFailsEngineAndCleansUp() async throws {
        let session = RecordingSessionSpy()
        let engine = RecordingEngine(sessionFactory: { _ in session })
        try await engine.start(request: .testMP4)
        let failure = RecordingError.recordingFailed("SCStream stopped")

        await session.emitFailure(failure)

        let didFail = await waitForState(.failed(failure.localizedDescription), in: engine)
        let removedTemporaryOutput = await session.removedTemporaryOutput
        XCTAssertTrue(didFail)
        XCTAssertTrue(removedTemporaryOutput)
    }

    func testFailureEventDuringIntentionalStopDoesNotOverwriteCompletion() async throws {
        let gate = AsyncGate()
        let session = RecordingSessionSpy(stopGate: gate)
        let engine = RecordingEngine(sessionFactory: { _ in session })
        try await engine.start(request: .testMP4)
        let stop = Task { try await engine.stop() }
        await session.waitUntilStopEntered()

        await session.emitFailure(.recordingFailed("expected teardown callback"))
        try await Task.sleep(for: .milliseconds(20))
        let stoppingState = await engine.state
        XCTAssertEqual(stoppingState, .stopping)

        await gate.open()
        let output = try await stop.value
        let completedState = await engine.state
        XCTAssertEqual(completedState, .completed(output))
    }

    func testLateFailureFromPreviousSessionCannotFailRestartedRecording() async throws {
        let first = RecordingSessionSpy()
        let second = RecordingSessionSpy()
        let factory = RecordingSessionSequenceFactory(sessions: [first, second])
        let engine = RecordingEngine(sessionFactory: { request in
            try factory.makeSession(request: request)
        })
        try await engine.start(request: .testMP4)
        _ = try await engine.stop()
        try await engine.start(request: .testMP4)

        await first.emitFailure(.recordingFailed("late old stream callback"))
        try await Task.sleep(for: .milliseconds(20))

        guard case .recording = await engine.state else {
            return XCTFail("Late failure changed the new recording state")
        }
        let secondSessionRemovedOutput = await second.removedTemporaryOutput
        XCTAssertFalse(secondSessionRemovedOutput)
        await engine.cancel()
    }

    func testFailureAfterCancellationIsIgnored() async throws {
        let session = RecordingSessionSpy()
        let engine = RecordingEngine(sessionFactory: { _ in session })
        try await engine.start(request: .testMP4)
        await engine.cancel()

        await session.emitFailure(.recordingFailed("late cancellation callback"))
        try await Task.sleep(for: .milliseconds(20))

        let state = await engine.state
        XCTAssertEqual(state, .idle)
    }

    func testCaptureFailureRelayTransitionsEngineAndCleansUpOnFirstWriterFailure() async throws {
        let cleanupGate = AsyncGate()
        let relay = RecordingFailureRelay()
        let writer = try MP4MediaWriter(
            temporaryURL: temporaryDirectory().appendingPathComponent("relay-writer.mp4"),
            plan: RecordingStreamPlan(
                request: .testMP4,
                pixelSize: PixelSize(width: 640, height: 480)
            ),
            includesSystemAudio: false,
            includesMicrophone: false,
            failureRelay: relay
        )
        defer { writer.cancel() }
        let session = RecordingSessionSpy(
            cancelGate: cleanupGate,
            failureEvents: relay.events
        )
        let engine = RecordingEngine(sessionFactory: { _ in session })
        try await engine.start(request: .testMP4)
        let failure = RecordingError.audioBackpressureOverflow(limit: 96)

        XCTAssertTrue(writer.recordFailure(failure))
        XCTAssertFalse(
            writer.recordFailure(RecordingError.recordingFailed("duplicate writer callback"))
        )
        await session.waitUntilCancelEntered()

        let state = await engine.state
        let cleanupCallCount = await session.cancelCallCount
        XCTAssertEqual(state, .failed(failure.localizedDescription))
        XCTAssertEqual(cleanupCallCount, 1)

        await cleanupGate.open()
        let removedOutput = await waitForRemovedOutput(in: session)
        XCTAssertTrue(removedOutput)
    }

    func testCaptureFailureRelayRejectsReportsAfterFinishing() async {
        let relay = RecordingFailureRelay()
        relay.finish()

        XCTAssertFalse(relay.report(.recordingFailed("stale writer callback")))
        var iterator = relay.events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertNil(event)
    }

    func testConcurrentEngineCancelCallersAwaitTheSameSessionCleanup() async throws {
        let cleanupGate = AsyncGate()
        let session = RecordingSessionSpy(cancelGate: cleanupGate)
        let probe = TeardownProbe()
        let engine = RecordingEngine(sessionFactory: { _ in session })
        try await engine.start(request: .testMP4)

        let firstCancel = Task {
            await engine.cancel()
            await probe.record("first-cancel-returned")
        }
        await session.waitUntilCancelEntered()
        let secondCancel = Task {
            await engine.cancel()
            await probe.record("second-cancel-returned")
        }
        try await Task.sleep(for: .milliseconds(20))

        let suspendedEvents = await probe.events
        let cleanupCallCount = await session.cancelCallCount
        XCTAssertTrue(suspendedEvents.isEmpty)
        XCTAssertEqual(cleanupCallCount, 1)

        await cleanupGate.open()
        await firstCancel.value
        await secondCancel.value
        let completedEvents = await probe.events
        XCTAssertEqual(Set(completedEvents), Set(["first-cancel-returned", "second-cancel-returned"]))
    }

    func testRestartWaitsForPriorEngineCleanupBeforeCreatingSession() async throws {
        let cleanupGate = AsyncGate()
        let first = RecordingSessionSpy(cancelGate: cleanupGate)
        let second = RecordingSessionSpy()
        let factory = RecordingSessionSequenceFactory(sessions: [first, second])
        let probe = TeardownProbe()
        let engine = RecordingEngine(sessionFactory: { request in
            try factory.makeSession(request: request)
        })
        try await engine.start(request: .testMP4)

        let cancel = Task { await engine.cancel() }
        await first.waitUntilCancelEntered()
        let restart = Task {
            try await engine.start(request: .testMP4)
            await probe.record("restart-returned")
        }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(factory.requestCount, 1)
        let suspendedEvents = await probe.events
        XCTAssertTrue(suspendedEvents.isEmpty)

        await cleanupGate.open()
        await cancel.value
        try await restart.value
        XCTAssertEqual(factory.requestCount, 2)
        guard case .recording = await engine.state else {
            return XCTFail("Expected restarted recording")
        }
        await engine.cancel()
    }

    func testEngineStopAndCancelBothAwaitCancellationCleanupBeforeReturning() async throws {
        let stopGate = AsyncGate()
        let cleanupGate = AsyncGate()
        let session = RecordingSessionSpy(stopGate: stopGate, cancelGate: cleanupGate)
        let probe = TeardownProbe()
        let engine = RecordingEngine(sessionFactory: { _ in session })
        try await engine.start(request: .testMP4)

        let stop = Task {
            do {
                _ = try await engine.stop()
                await probe.record("stop-returned")
            } catch {
                await probe.record("stop-returned")
                throw error
            }
        }
        await session.waitUntilStopEntered()
        let cancel = Task {
            await engine.cancel()
            await probe.record("cancel-returned")
        }
        await session.waitUntilCancelEntered()
        await stopGate.open()
        try await Task.sleep(for: .milliseconds(20))

        let suspendedEvents = await probe.events
        XCTAssertTrue(suspendedEvents.isEmpty)

        await cleanupGate.open()
        await cancel.value
        do {
            _ = try await stop.value
            XCTFail("Expected cancelled stop")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let completedEvents = await probe.events
        XCTAssertEqual(Set(completedEvents), Set(["stop-returned", "cancel-returned"]))
    }

    func testLosingStartJoinsTheSingleEngineCleanupBeforeReturning() async throws {
        let startGate = AsyncGate()
        let cleanupGate = AsyncGate()
        let session = RecordingSessionSpy(startGate: startGate, cancelGate: cleanupGate)
        let probe = TeardownProbe()
        let engine = RecordingEngine(sessionFactory: { _ in session })
        let start = Task {
            do {
                try await engine.start(request: .testMP4)
                await probe.record("start-returned")
            } catch {
                await probe.record("start-returned")
                throw error
            }
        }
        await session.waitUntilStartEntered()

        let cancel = Task { await engine.cancel() }
        await session.waitUntilCancelEntered()
        await startGate.open()
        try await Task.sleep(for: .milliseconds(20))

        let cleanupCallCount = await session.cancelCallCount
        let suspendedEvents = await probe.events
        XCTAssertEqual(cleanupCallCount, 1)
        XCTAssertTrue(suspendedEvents.isEmpty)

        await cleanupGate.open()
        await cancel.value
        do {
            try await start.value
            XCTFail("Expected cancelled start")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let completedCleanupCallCount = await session.cancelCallCount
        XCTAssertEqual(completedCleanupCallCount, 1)
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

    func testRequestRejectsFormatSpecificFrameRates() async {
        let factory = RecordingSessionFactorySpy()
        let engine = RecordingEngine(sessionFactory: { request in
            try factory.makeSession(request: request)
        })

        await XCTAssertThrowsRecordingError(.invalidFrameRate(0)) {
            try await engine.start(request: .testMP4.withFrameRate(0))
        }
        await XCTAssertThrowsRecordingError(.invalidFrameRate(31)) {
            try await engine.start(request: .testMP4.withFrameRate(31))
        }
        await XCTAssertThrowsRecordingError(.invalidGIFFrameRate(11)) {
            try await engine.start(request: .testGIF.withFrameRate(11))
        }
        XCTAssertEqual(factory.requestCount, 0)
    }

    func testGIFRequestRejectsSystemOrMicrophoneAudioWithTypedError() async {
        let factory = RecordingSessionFactorySpy()
        let engine = RecordingEngine(sessionFactory: { request in
            try factory.makeSession(request: request)
        })

        await XCTAssertThrowsRecordingError(.gifAudioUnsupported) {
            try await engine.start(request: .testGIF.withAudio(system: true, microphone: false))
        }
        await XCTAssertThrowsRecordingError(.gifAudioUnsupported) {
            try await engine.start(request: .testGIF.withAudio(system: false, microphone: true))
        }
        XCTAssertEqual(factory.requestCount, 0)
    }

    func testGIFWriterFinalizesUnknownAcceptedFrameCountWithLoopAndUnclampedDelays() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.gif")
        var writer = try GIFWriter(url: url, maxFPS: 10, maxPixelSize: 1_280, maxDuration: 60)

        try writer.append(
            image: TestImage.solid(width: 20, height: 20, color: .red),
            presentationTime: .zero
        )
        try writer.append(
            image: TestImage.solid(width: 20, height: 20, color: .blue),
            presentationTime: CMTime(seconds: 0.25, preferredTimescale: 600)
        )
        try writer.finish()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let fileGIF = try gifProperties(CGImageSourceCopyProperties(source, nil))
        XCTAssertEqual((fileGIF[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 0)
        let firstFrameGIF = try gifProperties(CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        XCTAssertEqual(
            try XCTUnwrap(
                (firstFrameGIF[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ),
            0.25,
            accuracy: 0.001
        )
    }

    func testGIFWriterDropsFramesAboveMaximumFPS() throws {
        let url = temporaryDirectory().appendingPathComponent("limited.gif")
        var writer = try GIFWriter(url: url, maxFPS: 10, maxPixelSize: 1_280, maxDuration: 60)
        let frame = try TestImage.solid(width: 20, height: 20, color: .red)

        try writer.append(image: frame, presentationTime: .zero)
        try writer.append(image: frame, presentationTime: CMTime(seconds: 0.02, preferredTimescale: 600))
        try writer.append(image: frame, presentationTime: CMTime(seconds: 0.10, preferredTimescale: 600))
        try writer.finish()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
    }

    func testGIFWriterCapsLongestEdgeAt1280Pixels() throws {
        let url = temporaryDirectory().appendingPathComponent("scaled.gif")
        var writer = try GIFWriter(url: url, maxFPS: 10, maxPixelSize: 1_280, maxDuration: 60)

        try writer.append(
            image: TestImage.solid(width: 2_000, height: 1_000, color: .red),
            presentationTime: .zero
        )
        try writer.finish()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 1_280)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 640)
    }

    func testGIFWriterDropsFramesAfterDurationLimit() throws {
        let url = temporaryDirectory().appendingPathComponent("duration.gif")
        var writer = try GIFWriter(url: url, maxFPS: 10, maxPixelSize: 1_280, maxDuration: 60)
        let frame = try TestImage.solid(width: 20, height: 20, color: .red)

        try writer.append(image: frame, presentationTime: .zero)
        try writer.append(image: frame, presentationTime: CMTime(seconds: 60, preferredTimescale: 600))
        try writer.append(image: frame, presentationTime: CMTime(seconds: 60.1, preferredTimescale: 600))
        try writer.finish()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
    }

    func testGIFWriterFinalDelayDoesNotExtendPlaybackPastDurationLimit() throws {
        let url = temporaryDirectory().appendingPathComponent("duration-delay.gif")
        var writer = try GIFWriter(url: url, maxFPS: 10, maxPixelSize: 1_280, maxDuration: 60)
        let frame = try TestImage.solid(width: 20, height: 20, color: .red)

        try writer.append(image: frame, presentationTime: .zero)
        try writer.append(image: frame, presentationTime: CMTime(seconds: 60, preferredTimescale: 600))
        try writer.finish()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let playbackDuration = (0..<CGImageSourceGetCount(source)).reduce(0.0) { duration, index in
            let properties = try? gifProperties(
                CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            )
            let delay = (properties?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? 0
            return duration + delay
        }
        XCTAssertLessThanOrEqual(playbackDuration, 60.001)
    }

    func testGIFWriterIgnoresNonMonotonicPresentationTimes() throws {
        let url = temporaryDirectory().appendingPathComponent("monotonic.gif")
        var writer = try GIFWriter(url: url, maxFPS: 10, maxPixelSize: 1_280, maxDuration: 60)
        let frame = try TestImage.solid(width: 20, height: 20, color: .red)

        try writer.append(image: frame, presentationTime: CMTime(seconds: 1, preferredTimescale: 600))
        try writer.append(image: frame, presentationTime: CMTime(seconds: 0.5, preferredTimescale: 600))
        try writer.append(image: frame, presentationTime: CMTime(seconds: 1.1, preferredTimescale: 600))
        try writer.finish()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let firstFrameGIF = try gifProperties(CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        XCTAssertEqual(
            try XCTUnwrap(
                (firstFrameGIF[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ),
            0.1,
            accuracy: 0.001
        )
    }

    func testGIFWriterFinishIsDeterministicForEmptyAndAlreadyFinalizedOutput() throws {
        let emptyURL = temporaryDirectory().appendingPathComponent("empty.gif")
        var empty = try GIFWriter(url: emptyURL, maxFPS: 10, maxPixelSize: 1_280, maxDuration: 60)
        XCTAssertThrowsError(try empty.finish()) { error in
            XCTAssertEqual(error as? RecordingError, .gifEncodingFailed("No GIF frames were captured."))
        }

        let finishedURL = temporaryDirectory().appendingPathComponent("finished.gif")
        var finished = try GIFWriter(url: finishedURL, maxFPS: 10, maxPixelSize: 1_280, maxDuration: 60)
        try finished.append(
            image: TestImage.solid(width: 20, height: 20, color: .red),
            presentationTime: .zero
        )
        try finished.finish()
        XCTAssertThrowsError(try finished.finish()) { error in
            XCTAssertEqual(
                error as? RecordingError,
                .gifEncodingFailed("The GIF writer is already finalized.")
            )
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

    func testGIFFileLocationsUseGIFExtensionUnderTheSameLibraryRoot() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = RecordingFileLocations(rootURL: root, identifier: UUID(), format: .gif)

        XCTAssertEqual(locations.temporaryURL.pathExtension, "gif")
        XCTAssertEqual(locations.outputURL.pathExtension, "gif")
        XCTAssertEqual(locations.outputURL.deletingLastPathComponent().lastPathComponent, "originals")
    }

    func testDefaultSessionFactorySelectsGIFAndKeepsMP4Behavior() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gifLocations = RecordingFileLocations(rootURL: root, identifier: UUID(), format: .gif)
        let mp4Locations = RecordingFileLocations(rootURL: root, identifier: UUID(), format: .mp4)

        let gif = try DefaultRecordingSessionFactory.makeSession(
            request: .testGIF,
            locations: gifLocations
        )
        let mp4 = try DefaultRecordingSessionFactory.makeSession(
            request: .testMP4,
            locations: mp4Locations
        )

        XCTAssertTrue(gif is GIFRecordingSession)
        XCTAssertTrue(mp4 is MP4RecordingSession)
    }

    func testGIFRecordingSessionStopFinalizesAndCommitsRealGIF() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = RecordingFileLocations(rootURL: root, identifier: UUID(), format: .gif)
        let frames = [
            GIFTestFrame(
                image: try TestImage.solid(width: 30, height: 20, color: .red),
                presentationTime: .zero
            ),
            GIFTestFrame(
                image: try TestImage.solid(width: 30, height: 20, color: .blue),
                presentationTime: CMTime(seconds: 0.1, preferredTimescale: 600)
            ),
        ]
        let session = GIFRecordingSession(
            request: .testGIF,
            locations: locations,
            screenCaptureAuthorization: { true },
            captureFactory: { _, mediaQueue, writer in
                GIFCaptureResourceSpy(mediaQueue: mediaQueue, writer: writer, frames: frames)
            }
        )

        try await session.start()
        let output = try await session.stop()

        XCTAssertEqual(output, locations.outputURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.temporaryURL.path))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
    }

    func testGIFRecordingSessionWriterHonorsRequestedFrameRateBelowTenFPS() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = RecordingRequest.testGIF.withFrameRate(5)
        let locations = RecordingFileLocations(rootURL: root, identifier: UUID(), format: .gif)
        let image = try TestImage.solid(width: 30, height: 20, color: .red)
        let frames = [
            GIFTestFrame(image: image, presentationTime: .zero),
            GIFTestFrame(
                image: image,
                presentationTime: CMTime(seconds: 0.1, preferredTimescale: 600)
            ),
            GIFTestFrame(
                image: image,
                presentationTime: CMTime(seconds: 0.2, preferredTimescale: 600)
            ),
        ]
        let session = GIFRecordingSession(
            request: request,
            locations: locations,
            screenCaptureAuthorization: { true },
            captureFactory: { _, mediaQueue, writer in
                GIFCaptureResourceSpy(mediaQueue: mediaQueue, writer: writer, frames: frames)
            }
        )

        try await session.start()
        let output = try await session.stop()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
    }

    func testGIFRecordingSessionCancelRemovesTemporaryAndCompletedOutput() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = RecordingFileLocations(rootURL: root, identifier: UUID(), format: .gif)
        let frame = GIFTestFrame(
            image: try TestImage.solid(width: 30, height: 20, color: .red),
            presentationTime: .zero
        )
        let session = GIFRecordingSession(
            request: .testGIF,
            locations: locations,
            screenCaptureAuthorization: { true },
            captureFactory: { _, mediaQueue, writer in
                GIFCaptureResourceSpy(mediaQueue: mediaQueue, writer: writer, frames: [frame])
            }
        )

        try await session.start()
        await session.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.outputURL.path))
    }

    func testGIFTargetDisappearanceBecomesEngineFailureAndCleansTemporaryOutput() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = RecordingFileLocations(rootURL: root, identifier: UUID(), format: .gif)
        let session = GIFRecordingSession(
            request: .testGIF,
            locations: locations,
            screenCaptureAuthorization: { true },
            captureFactory: { _, _, _ in throw RecordingError.sourceUnavailable }
        )
        let engine = RecordingEngine(sessionFactory: { _ in session })

        await XCTAssertThrowsRecordingError(.sourceUnavailable) {
            try await engine.start(request: .testGIF)
        }

        let state = await engine.state
        XCTAssertEqual(state, .failed(RecordingError.sourceUnavailable.localizedDescription))
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.outputURL.path))
    }

    func testGIFCaptureTimeEncoderFailureReachesEngineOnceAndCleansTemporaryOutput() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = RecordingFileLocations(rootURL: root, identifier: UUID(), format: .gif)
        let failure = RecordingError.gifEncodingFailed("Synthetic capture-time failure.")
        let encoder = GIFFrameEncoderSpy(appendError: failure)
        let frame = GIFTestFrame(
            image: try TestImage.solid(width: 30, height: 20, color: .red),
            presentationTime: .zero
        )
        let session = GIFRecordingSession(
            request: .testGIF,
            locations: locations,
            screenCaptureAuthorization: { true },
            captureFactory: { _, mediaQueue, writer in
                GIFCaptureResourceSpy(mediaQueue: mediaQueue, writer: writer, frames: [frame])
            },
            writerFactory: { _, _, relay in
                GIFMediaWriter(encoder: encoder, failureRelay: relay)
            }
        )
        let engine = RecordingEngine(sessionFactory: { _ in session })

        _ = try? await engine.start(request: .testGIF)

        let didFail = await waitForState(.failed(failure.localizedDescription), in: engine)
        XCTAssertTrue(didFail)
        XCTAssertEqual(encoder.appendCallCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.temporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.outputURL.path))
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

    func testBackpressuredAudioTailIsAppendedBeforeDrainCompletes() async throws {
        let input = ControlledAudioInput(isReady: false)
        let appender = BufferedAudioAppender(
            input: input,
            capacity: 4,
            writerError: { nil }
        )
        let sample = try makePCMSampleBuffer(
            samples: [0.25, 0.25],
            frameCount: 1,
            presentationTime: .zero
        )
        try appender.enqueue(sample)
        let queue = DispatchQueue(label: "RecordingStateTests.audio-tail")
        let drain = Task {
            try await appender.drainUntilEmpty(
                on: queue,
                timeout: .seconds(1),
                pollInterval: .milliseconds(2)
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(input.appendedCount, 0)

        input.setReady(true)
        try await drain.value

        XCTAssertEqual(input.appendedCount, 1)
        XCTAssertTrue(appender.isEmpty)
    }

    func testAudioBackpressureOverflowIsTypedInsteadOfDroppingOldestBuffer() throws {
        let input = ControlledAudioInput(isReady: false)
        let appender = BufferedAudioAppender(
            input: input,
            capacity: 1,
            writerError: { nil }
        )
        let sample = try makePCMSampleBuffer(
            samples: [0.25, 0.25],
            frameCount: 1,
            presentationTime: .zero
        )
        try appender.enqueue(sample)

        XCTAssertThrowsError(try appender.enqueue(sample)) { error in
            XCTAssertEqual(error as? RecordingError, .audioBackpressureOverflow(limit: 1))
        }
        XCTAssertEqual(appender.count, 1)
    }

    func testAudioAppendFailureIsTyped() throws {
        let input = ControlledAudioInput(isReady: true, appendSucceeds: false)
        let appender = BufferedAudioAppender(
            input: input,
            capacity: 1,
            writerError: { NSError(domain: "RecordingStateTests", code: 28) }
        )
        let sample = try makePCMSampleBuffer(
            samples: [0.25, 0.25],
            frameCount: 1,
            presentationTime: .zero
        )

        XCTAssertThrowsError(try appender.enqueue(sample)) { error in
            XCTAssertEqual(
                error as? RecordingError,
                .audioWriterFailed(NSError(domain: "RecordingStateTests", code: 28).localizedDescription)
            )
        }
    }

    func testAudioBackpressureTimeoutIsTypedAndEngineCleansUp() async throws {
        let input = ControlledAudioInput(isReady: false)
        let appender = BufferedAudioAppender(
            input: input,
            capacity: 2,
            writerError: { nil }
        )
        let sample = try makePCMSampleBuffer(
            samples: [0.25, 0.25],
            frameCount: 1,
            presentationTime: .zero
        )
        try appender.enqueue(sample)
        do {
            try await appender.drainUntilEmpty(
                on: DispatchQueue(label: "RecordingStateTests.audio-timeout"),
                timeout: .milliseconds(20),
                pollInterval: .milliseconds(2)
            )
            XCTFail("Expected backpressure timeout")
        } catch {
            XCTAssertEqual(error as? RecordingError, .audioBackpressureTimeout)
        }

        let session = RecordingSessionSpy(stopError: .audioBackpressureTimeout)
        let engine = RecordingEngine(sessionFactory: { _ in session })
        try await engine.start(request: .testMP4)
        _ = try? await engine.stop()
        let state = await engine.state
        let removedTemporaryOutput = await session.removedTemporaryOutput
        XCTAssertEqual(
            state,
            .failed(RecordingError.audioBackpressureTimeout.localizedDescription)
        )
        XCTAssertTrue(removedTemporaryOutput)
    }

    func testConcurrentTeardownCallersAwaitOneSuspendedOperationBeforeFinalizingWriter() async throws {
        let gate = AsyncGate()
        let probe = TeardownProbe()
        let teardown = SharedTeardown {
            await probe.record("teardown-started")
            await gate.wait()
            await probe.record("callbacks-ended")
        }
        let stop = Task {
            await teardown.run()
            await probe.record("writer-finished")
        }
        await probe.waitUntilStarted()
        let cancel = Task {
            await teardown.run()
            await probe.record("writer-cancelled")
        }
        try await Task.sleep(for: .milliseconds(20))

        let suspendedEvents = await probe.events
        XCTAssertEqual(suspendedEvents, ["teardown-started"])

        await gate.open()
        await stop.value
        await cancel.value
        let events = await probe.events
        XCTAssertEqual(events.filter { $0 == "teardown-started" }.count, 1)
        let callbacksEnded = try XCTUnwrap(events.firstIndex(of: "callbacks-ended"))
        XCTAssertGreaterThan(try XCTUnwrap(events.firstIndex(of: "writer-finished")), callbacksEnded)
        XCTAssertGreaterThan(try XCTUnwrap(events.firstIndex(of: "writer-cancelled")), callbacksEnded)
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

    func withAudio(system: Bool, microphone: Bool) -> RecordingRequest {
        RecordingRequest(
            target: target,
            format: format,
            includesSystemAudio: system,
            includesMicrophone: microphone,
            framesPerSecond: framesPerSecond
        )
    }
}

private struct GIFTestFrame: @unchecked Sendable {
    let image: CGImage
    let presentationTime: CMTime
}

private final class GIFCaptureResourceSpy: GIFCaptureResource, @unchecked Sendable {
    private let mediaQueue: DispatchQueue
    private let writer: GIFMediaWriter
    private let frames: [GIFTestFrame]

    init(mediaQueue: DispatchQueue, writer: GIFMediaWriter, frames: [GIFTestFrame]) {
        self.mediaQueue = mediaQueue
        self.writer = writer
        self.frames = frames
    }

    func start() async throws {
        await withCheckedContinuation { continuation in
            mediaQueue.async { [writer, frames] in
                frames.forEach {
                    writer.append(image: $0.image, presentationTime: $0.presentationTime)
                }
                continuation.resume()
            }
        }
    }

    func stop() async {}
}

private final class GIFFrameEncoderSpy: GIFFrameEncoding, @unchecked Sendable {
    private let lock = NSLock()
    private let appendError: RecordingError?
    private var appendCalls = 0

    init(appendError: RecordingError? = nil) {
        self.appendError = appendError
    }

    var appendCallCount: Int {
        lock.withLock { appendCalls }
    }

    func append(image: CGImage, presentationTime: CMTime) throws {
        try lock.withLock {
            appendCalls += 1
            if let appendError { throw appendError }
        }
    }

    func finish() throws {}
    func cancel() {}
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
    nonisolated let failureEvents: AsyncStream<RecordingError>
    let outputURL = URL(fileURLWithPath: "/tmp/test-recording.mp4")
    private(set) var removedTemporaryOutput = false
    private let failureContinuation: AsyncStream<RecordingError>.Continuation?
    private let startError: RecordingError?
    private let stopError: RecordingError?
    private let startGate: AsyncGate?
    private let stopGate: AsyncGate?
    private let cancelGate: AsyncGate?
    private var startEnteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var stopEnteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var cancelEnteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var didEnterStart = false
    private var didEnterStop = false
    private var didEnterCancel = false
    private(set) var cancelCallCount = 0

    init(
        startError: RecordingError? = nil,
        stopError: RecordingError? = nil,
        startGate: AsyncGate? = nil,
        stopGate: AsyncGate? = nil,
        cancelGate: AsyncGate? = nil,
        failureEvents: AsyncStream<RecordingError>? = nil
    ) {
        if let failureEvents {
            self.failureEvents = failureEvents
            failureContinuation = nil
        } else {
            let failures = AsyncStream.makeStream(
                of: RecordingError.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            self.failureEvents = failures.stream
            failureContinuation = failures.continuation
        }
        self.startError = startError
        self.stopError = stopError
        self.startGate = startGate
        self.stopGate = stopGate
        self.cancelGate = cancelGate
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
        cancelCallCount += 1
        didEnterCancel = true
        cancelEnteredContinuations.forEach { $0.resume() }
        cancelEnteredContinuations.removeAll()
        if let cancelGate { await cancelGate.wait() }
        removedTemporaryOutput = true
    }

    func emitFailure(_ error: RecordingError) {
        failureContinuation?.yield(error)
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

    func waitUntilCancelEntered() async {
        guard !didEnterCancel else { return }
        await withCheckedContinuation { continuation in
            cancelEnteredContinuations.append(continuation)
        }
    }
}

private final class RecordingSessionSequenceFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let sessions: [RecordingSessionSpy]
    private var nextIndex = 0

    init(sessions: [RecordingSessionSpy]) {
        self.sessions = sessions
    }

    var requestCount: Int {
        lock.withLock { nextIndex }
    }

    func makeSession(request: RecordingRequest) throws -> any RecordingSession {
        try lock.withLock {
            guard nextIndex < sessions.count else {
                throw RecordingError.writerSetupFailed("No recording session remains.")
            }
            defer { nextIndex += 1 }
            return sessions[nextIndex]
        }
    }
}

private final class ControlledAudioInput: RecordingAudioInput, @unchecked Sendable {
    private let lock = NSLock()
    private var ready: Bool
    private let appendSucceeds: Bool
    private var appended: [CMSampleBuffer] = []

    init(isReady: Bool, appendSucceeds: Bool = true) {
        ready = isReady
        self.appendSucceeds = appendSucceeds
    }

    var isReadyForMoreMediaData: Bool {
        lock.withLock { ready }
    }

    var appendedCount: Int {
        lock.withLock { appended.count }
    }

    func setReady(_ isReady: Bool) {
        lock.withLock { ready = isReady }
    }

    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        lock.withLock {
            guard appendSucceeds else { return false }
            appended.append(sampleBuffer)
            return true
        }
    }
}

private actor TeardownProbe {
    private(set) var events: [String] = []
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []

    func record(_ event: String) {
        events.append(event)
        guard event == "teardown-started" else { return }
        startedContinuations.forEach { $0.resume() }
        startedContinuations.removeAll()
    }

    func waitUntilStarted() async {
        guard events.contains("teardown-started") else {
            return await withCheckedContinuation { continuation in
                startedContinuations.append(continuation)
            }
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

private func waitForState(
    _ expected: RecordingState,
    in engine: RecordingEngine,
    timeout: Duration = .seconds(1)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await engine.state == expected {
            return true
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await engine.state == expected
}

private func waitForRemovedOutput(
    in session: RecordingSessionSpy,
    timeout: Duration = .seconds(1)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await session.removedTemporaryOutput {
            return true
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await session.removedTemporaryOutput
}

private func gifProperties(_ properties: CFDictionary?) throws -> [CFString: Any] {
    let dictionary = try XCTUnwrap(properties as? [CFString: Any])
    return try XCTUnwrap(dictionary[kCGImagePropertyGIFDictionary] as? [CFString: Any])
}
