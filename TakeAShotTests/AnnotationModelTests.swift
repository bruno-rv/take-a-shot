import AVFoundation
import Foundation
import CoreGraphics
import CoreVideo
import XCTest
@testable import TakeAShot

final class AnnotationModelTests: XCTestCase {
    func testFinalAnnotationUIUsesDurableLifecyclePixelPreviewAndRealShortcuts() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ui = try String(contentsOf: projectRoot.appendingPathComponent("TakeAShot/MacContentView.swift"))
        let editor = try String(contentsOf: projectRoot.appendingPathComponent("TakeAShot/AnnotationEditor.swift"))
        let app = try String(contentsOf: projectRoot.appendingPathComponent("TakeAShot/TakeAShotApp.swift"))

        XCTAssertTrue(ui.contains("modifiers: [.control, .option]"))
        XCTAssertTrue(ui.contains("case .area: \"⌃⌥A\""))
        XCTAssertTrue(ui.contains(".onChange(of: tagsFieldIsFocused)"))
        XCTAssertTrue(ui.contains("appState.cancelCaptureOperation"))
        XCTAssertTrue(ui.contains("appState.cancelRecording"))
        XCTAssertFalse(ui.contains("Button(action: appState.cancelCurrentOperation)"))
        XCTAssertFalse(ui.contains("@State private var tagsText"))
        XCTAssertTrue(editor.contains("AnnotationPreviewService"))
        XCTAssertFalse(editor.contains(".fill(.ultraThinMaterial)"))
        XCTAssertFalse(editor.contains("Image(systemName: \"drop.degreesign\")"))
        XCTAssertTrue(app.contains("applicationShouldTerminate"))
        XCTAssertTrue(app.contains(".terminateLater"))
        XCTAssertTrue(app.contains("reply(toApplicationShouldTerminate: shouldTerminate)"))
        XCTAssertTrue(app.contains("Could Not Quit Safely"))
    }

    @MainActor
    func testTerminationWaitsForLatestAnnotationSaveBeforeReplying() async throws {
        let library = GatedAnnotationSaveLibrary()
        let state = makeAppState(library: library, exporter: AppCaptureExporterSpy(copyError: nil))
        let capture = try makeCapture()
        state.receiveCapture(capture)
        state.annotationEditor.commitText("Last edit", at: NormalizedPoint(x: 0.2, y: 0.3))
        await fulfillment(of: [library.saveStarted], timeout: 1)

        let reply = LockedValue<Bool?>(nil)
        let coordinator = ApplicationTerminationCoordinator(
            flush: state.flushPendingAnnotations,
            onFailure: { _ in XCTFail("Unexpected persistence failure") }
        )
        coordinator.beginTermination { shouldTerminate in
            reply.withValue { $0 = shouldTerminate }
        }

        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(reply.value)
        await library.finishSave()
        try await waitUntil { reply.value != nil }
        XCTAssertEqual(reply.value, true)
        let savedDocuments = await library.savedDocuments
        XCTAssertEqual(savedDocuments, [state.annotationEditor.document])
    }

    @MainActor
    func testTerminationCancelsQuitAndSurfacesAnnotationPersistenceFailure() async throws {
        let library = GatedAnnotationSaveLibrary(saveError: AnnotationPersistenceTestError.failed)
        let state = makeAppState(library: library, exporter: AppCaptureExporterSpy(copyError: nil))
        let capture = try makeCapture()
        state.receiveCapture(capture)
        state.annotationEditor.commitText("Unsaved", at: NormalizedPoint(x: 0.2, y: 0.3))
        await fulfillment(of: [library.saveStarted], timeout: 1)

        let reply = LockedValue<Bool?>(nil)
        let surfacedError = LockedValue<Error?>(nil)
        let coordinator = ApplicationTerminationCoordinator(
            flush: state.flushPendingAnnotations,
            onFailure: { error in surfacedError.withValue { $0 = error } }
        )
        coordinator.beginTermination { shouldTerminate in
            reply.withValue { $0 = shouldTerminate }
        }
        await library.finishSave()

        try await waitUntil { reply.value != nil }
        XCTAssertEqual(reply.value, false)
        XCTAssertTrue(surfacedError.value is AnnotationPersistenceTestError)
    }

    @MainActor
    func testTerminationResolvesPendingInlineTextBeforeSaving() async throws {
        let library = GatedAnnotationSaveLibrary()
        let state = makeAppState(library: library, exporter: AppCaptureExporterSpy(copyError: nil))
        let capture = try makeCapture()
        state.receiveCapture(capture)
        state.annotationEditor.beginText(at: NormalizedPoint(x: 0.25, y: 0.35))
        state.annotationEditor.updatePendingText("Typed immediately before quit")

        let reply = LockedValue<Bool?>(nil)
        let coordinator = ApplicationTerminationCoordinator(
            flush: state.flushPendingAnnotations,
            onFailure: { _ in XCTFail("Unexpected persistence failure") }
        )
        coordinator.beginTermination { shouldTerminate in
            reply.withValue { $0 = shouldTerminate }
        }
        await fulfillment(of: [library.saveStarted], timeout: 1)
        XCTAssertNil(reply.value)
        await library.finishSave()

        try await waitUntil { reply.value != nil }
        let savedDocuments = await library.savedDocuments
        let savedDocument = try XCTUnwrap(savedDocuments.last)
        guard case .text(let text) = try XCTUnwrap(savedDocument.items.last) else {
            return XCTFail("Expected pending text to be committed")
        }
        XCTAssertEqual(text.text, "Typed immediately before quit")
        XCTAssertEqual(reply.value, true)
    }

    @MainActor
    func testPersistenceSubscriptionIgnoresSelectionFocusAndPendingKeystrokes() async throws {
        let library = CountingAnnotationLibrary()
        let state = makeAppState(library: library, exporter: AppCaptureExporterSpy(copyError: nil))
        let capture = try makeCapture()
        state.receiveCapture(capture)

        state.annotationEditor.beginText(at: NormalizedPoint(x: 0.2, y: 0.3))
        state.annotationEditor.updatePendingText("a")
        state.annotationEditor.updatePendingText("ab")
        state.annotationEditor.updatePendingText("abc")
        state.annotationEditor.cancelPendingText()
        state.annotationEditor.select(nil)
        try await Task.sleep(for: .milliseconds(30))
        let countBeforeDurableEdit = await library.saveCount
        XCTAssertEqual(countBeforeDurableEdit, 0)

        state.annotationEditor.commitText("Durable", at: NormalizedPoint(x: 0.4, y: 0.5))
        try await waitUntil { await library.saveCount == 1 }
        let itemID = try XCTUnwrap(state.annotationEditor.document.items.last?.id)
        state.annotationEditor.select(itemID)
        state.annotationEditor.select(nil)
        try await Task.sleep(for: .milliseconds(30))
        let countAfterSelection = await library.saveCount
        XCTAssertEqual(countAfterSelection, 1)
    }

    @MainActor
    func testPreviewServiceSerializesAndCoalescesRapidRequests() async throws {
        let capture = try makeCapture()
        let probe = PreviewOperationProbe()
        let service = AnnotationPreviewService { source, document, _ in
            try await probe.render(source: source, marker: document.items.count)
        }
        let first = Task {
            try await service.render(
                capture: capture,
                document: previewDocument(captureID: capture.id, itemCount: 1),
                maxPixelSize: 64
            )
        }
        try await waitUntil { await probe.startedMarkers.count == 1 }
        let second = Task {
            try await service.render(
                capture: capture,
                document: previewDocument(captureID: capture.id, itemCount: 2),
                maxPixelSize: 64
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        let third = Task {
            try await service.render(
                capture: capture,
                document: previewDocument(captureID: capture.id, itemCount: 3),
                maxPixelSize: 64
            )
        }

        guard case .failure(let secondError) = await second.result else {
            return XCTFail("Expected the superseded request to be coalesced")
        }
        XCTAssertTrue(secondError is CancellationError)
        await probe.releaseNext()
        _ = try await first.value
        try await waitUntil { await probe.startedMarkers.count == 2 }
        await probe.releaseNext()
        _ = try await third.value

        let startedMarkers = await probe.startedMarkers
        let maximumConcurrency = await probe.maximumConcurrency
        XCTAssertEqual(startedMarkers, [1, 3])
        XCTAssertEqual(maximumConcurrency, 1)
    }

    @MainActor
    func testEditorLoadsPersistedDocumentAsNewHistoryRoot() throws {
        let capture = try makeCapture()
        let document = reviewAnnotationDocument(captureID: capture.id)
        let editor = AnnotationEditorModel()

        editor.load(capture, document: document)

        XCTAssertEqual(editor.document, document)
        XCTAssertFalse(editor.canUndo)
        XCTAssertFalse(editor.canRedo)
    }

    @MainActor
    func testAppStatePersistsEditsBeforeSwitchAndRelaunchReopensAndExportsSavedDocument() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CaptureLibraryStore(rootURL: root, ocr: AppStateOCR())
        let first = try makeCapture()
        let second = CapturedImage(
            id: UUID(),
            kind: .area,
            title: "Second",
            createdAt: .now,
            image: try TestImage.solid(width: 20, height: 20, color: .green),
            pixelSize: PixelSize(width: 20, height: 20)
        )
        _ = try await library.persist(image: first)
        _ = try await library.persist(image: second)
        let exporter = AppCaptureExporterSpy(copyError: nil)
        let state = makeAppState(library: library, exporter: exporter)
        try await waitUntil { state.records.count == 2 }

        state.openRecord(first.id)
        try await waitUntil { state.activeCapture?.id == first.id }
        state.annotationEditor.applyDrag(
            tool: .blur,
            from: NormalizedPoint(x: 0.1, y: 0.1),
            to: NormalizedPoint(x: 0.3, y: 0.3)
        )
        state.annotationEditor.commitText("Saved text", at: NormalizedPoint(x: 0.4, y: 0.4))
        state.annotationEditor.applyDrag(
            tool: .crop,
            from: NormalizedPoint(x: 0.05, y: 0.05),
            to: NormalizedPoint(x: 0.9, y: 0.9)
        )
        let editedDocument = state.annotationEditor.document

        state.openRecord(second.id)
        try await waitUntil { state.activeCapture?.id == second.id }

        let relaunchedExporter = AppCaptureExporterSpy(copyError: nil)
        let relaunched = makeAppState(
            library: CaptureLibraryStore(rootURL: root, ocr: AppStateOCR()),
            exporter: relaunchedExporter
        )
        try await waitUntil { relaunched.records.count == 2 }
        relaunched.openRecord(first.id)
        try await waitUntil { relaunched.activeCapture?.id == first.id }
        XCTAssertEqual(relaunched.annotationEditor.document, editedDocument)

        relaunched.copyRecord(first.id)
        await fulfillment(of: [relaunchedExporter.copyExpectation], timeout: 1)
        let copiedDocument = await relaunchedExporter.copySnapshot?.document
        XCTAssertEqual(copiedDocument, editedDocument)
        relaunched.exportRecord(first.id, format: .png)
        await fulfillment(of: [relaunchedExporter.saveExpectation], timeout: 1)
        let savedDocument = await relaunchedExporter.saveSnapshot?.document
        XCTAssertEqual(savedDocument, editedDocument)
        let reloadedRecords = try await library.load()
        XCTAssertNotNil(reloadedRecords.first(where: { $0.id == first.id })?.annotationFilename)
        XCTAssertGreaterThan(
            reloadedRecords.first(where: { $0.id == first.id })?.lastEditedAt ?? .distantPast,
            first.createdAt
        )
    }

    @MainActor
    func testRecordingIsPreparingDuringPickerAndCancelBlocksRestartUntilCleanupAndPickerFinish() async throws {
        let library = InMemoryAppLibrary()
        let recording = GatedAppRecordingController()
        let picker = GatedAppRecordingPicker()
        let state = AppState(
            library: library,
            recording: recording,
            exporter: AppCaptureExporterSpy(copyError: nil),
            captureAction: { _, _, completion in completion() },
            cancelCaptureAction: {},
            recordingTargetPicker: { await picker.pick() }
        )

        state.startRecording(format: .mp4, includesSystemAudio: true, includesMicrophone: false)
        XCTAssertEqual(state.recordingState.kind, .preparing)
        XCTAssertFalse(state.canStartRecording)
        await fulfillment(of: [picker.started], timeout: 1)
        state.cancelRecording()
        state.startRecording(format: .gif, includesSystemAudio: false, includesMicrophone: false)
        XCTAssertFalse(state.canStartRecording)
        let pickerCallCount = await picker.callCount
        XCTAssertEqual(pickerCallCount, 1)
        await picker.resume(.display(7))
        try await waitUntil { state.canStartRecording }

        let startRequests = await recording.startRequests
        let cancelCount = await recording.cancelCount
        XCTAssertEqual(startRequests, [])
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(state.recordingState.kind, .idle)
    }

    @MainActor
    func testCancelDuringEngineStartCannotPublishRecordingOrOverwriteRestart() async throws {
        let recording = GatedAppRecordingController(gatesFirstStart: true)
        let pickerCalls = LockedValue(0)
        let state = AppState(
            library: InMemoryAppLibrary(),
            recording: recording,
            exporter: AppCaptureExporterSpy(copyError: nil),
            captureAction: { _, _, completion in completion() },
            cancelCaptureAction: {},
            recordingTargetPicker: {
                pickerCalls.withValue { $0 += 1 }
                return .window(42)
            }
        )

        state.startRecording(format: .mp4, includesSystemAudio: false, includesMicrophone: false)
        await fulfillment(of: [recording.startEntered], timeout: 1)
        state.cancelRecording()
        XCTAssertFalse(state.canStartRecording)
        await recording.releaseFirstStart()
        try await waitUntil { state.canStartRecording }
        state.startRecording(format: .gif, includesSystemAudio: false, includesMicrophone: false)
        try await waitUntil { state.recordingState.kind == .recording }

        let requestCount = await recording.startRequests.count
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(state.recordingState.kind, .recording)
        XCTAssertEqual(pickerCalls.value, 2)
    }

    @MainActor
    func testStoppingCannotBeCancelledAndPublishesOnlyAfterInspectionAndRegistration() async throws {
        let library = GatedRegistrationLibrary()
        let recording = GatedAppRecordingController()
        let exporter = GatedMediaExporter()
        let state = AppState(
            library: library,
            recording: recording,
            exporter: exporter,
            captureAction: { _, _, completion in completion() },
            cancelCaptureAction: {},
            recordingTargetPicker: { .display(1) }
        )
        state.startRecording(format: .mp4, includesSystemAudio: false, includesMicrophone: false)
        try await waitUntil { state.recordingState.kind == .recording }

        state.stopRecording()
        await fulfillment(of: [exporter.inspectExpectation], timeout: 1)
        state.cancelRecording()
        XCTAssertEqual(state.recordingState.kind, .stopping)
        let cancelCount = await recording.cancelCount
        XCTAssertEqual(cancelCount, 0)
        let outputURL = await recording.outputURL
        let media = try reviewRecordedMedia(url: outputURL)
        await exporter.resume(media)
        await fulfillment(of: [library.registrationStarted], timeout: 1)
        XCTAssertEqual(state.recordingState.kind, .stopping)
        await library.resumeRegistration()
        try await waitUntil { state.recordingState.kind == .completed }
        let registeredIDs = await library.registeredIDs
        XCTAssertEqual(registeredIDs, [media.id])
    }

    @MainActor
    func testInspectionFailureDiscardsOrphanAndAllowsCleanImmediateRestart() async throws {
        let recording = GatedAppRecordingController()
        let exporter = FailingInspectionExporter()
        let state = AppState(
            library: InMemoryAppLibrary(),
            recording: recording,
            exporter: exporter,
            captureAction: { _, _, completion in completion() },
            cancelCaptureAction: {},
            recordingTargetPicker: { .display(1) }
        )
        state.startRecording(format: .mp4, includesSystemAudio: false, includesMicrophone: false)
        try await waitUntil { state.recordingState.kind == .recording }

        state.stopRecording()
        await fulfillment(of: [exporter.discarded], timeout: 1)
        try await waitUntil { state.recordingState.kind == .failed && state.canStartRecording }
        state.startRecording(format: .gif, includesSystemAudio: false, includesMicrophone: false)
        try await waitUntil { state.recordingState.kind == .recording }

        let discardedURLs = await exporter.discardedURLs
        let requestCount = await recording.startRequests.count
        let outputURL = await recording.outputURL
        XCTAssertEqual(discardedURLs, [outputURL])
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testRegistrationFailureRetainsInspectedOutputForRelaunchRecovery() async throws {
        let recording = GatedAppRecordingController()
        let exporter = AppCaptureExporterSpy(copyError: nil)
        let state = AppState(
            library: FailingRegistrationLibrary(),
            recording: recording,
            exporter: exporter,
            captureAction: { _, _, completion in completion() },
            cancelCaptureAction: {},
            recordingTargetPicker: { .display(1) }
        )
        let outputURL = await recording.outputURL
        try Data("valid inspected media".utf8).write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        state.startRecording(format: .mp4, includesSystemAudio: false, includesMicrophone: false)
        try await waitUntil { state.recordingState.kind == .recording }
        state.stopRecording()
        try await waitUntil { state.recordingState.kind == .failed && state.canStartRecording }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let discardedURLs = await exporter.discardedURLs
        XCTAssertTrue(discardedURLs.isEmpty)
    }

    @MainActor
    func testCaptureActivityBlocksRecordingUntilInjectedCompletion() async throws {
        let capture = GatedCaptureActionRecorder()
        let pickerCalls = LockedValue(0)
        let recording = GatedAppRecordingController()
        let state = AppState(
            library: InMemoryAppLibrary(),
            recording: recording,
            exporter: AppCaptureExporterSpy(copyError: nil),
            captureAction: { mode, _, completion in capture.begin(mode, completion: completion) },
            cancelCaptureAction: {},
            recordingTargetPicker: {
                pickerCalls.withValue { $0 += 1 }
                return .display(1)
            }
        )

        state.capture(mode: .window, options: CaptureOptions())
        XCTAssertTrue(state.isCaptureActive)
        XCTAssertFalse(state.canStartRecording)
        state.startRecording(format: .mp4, includesSystemAudio: false, includesMicrophone: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pickerCalls.value, 0)

        capture.complete()
        try await waitUntil { state.canStartRecording }
        state.startRecording(format: .mp4, includesSystemAudio: false, includesMicrophone: false)
        try await waitUntil { state.recordingState.kind == .recording }
        XCTAssertEqual(pickerCalls.value, 1)
    }

    @MainActor
    func testScrollingStatusEndDoesNotCompleteCaptureBeforeExactCallback() async throws {
        let capture = GatedCaptureActionRecorder()
        let state = AppState(
            library: InMemoryAppLibrary(),
            recording: GatedAppRecordingController(),
            exporter: AppCaptureExporterSpy(copyError: nil),
            captureAction: { mode, _, completion in capture.begin(mode, completion: completion) },
            cancelCaptureAction: {},
            recordingTargetPicker: { .display(1) }
        )
        state.capture(mode: .scrolling, options: CaptureOptions())
        state.beginScrollingCapture()

        state.endScrollingCapture()

        XCTAssertTrue(state.isCaptureActive)
        XCTAssertFalse(state.isScrollingCaptureActive)
        capture.complete()
        try await waitUntil { !state.isCaptureActive }
    }

    @MainActor
    func testRecordingActivityBlocksCaptureDispatch() async throws {
        let capture = GatedCaptureActionRecorder(completesImmediately: true)
        let recording = GatedAppRecordingController()
        let state = AppState(
            library: InMemoryAppLibrary(),
            recording: recording,
            exporter: AppCaptureExporterSpy(copyError: nil),
            captureAction: { mode, _, completion in capture.begin(mode, completion: completion) },
            cancelCaptureAction: {},
            recordingTargetPicker: { .display(1) }
        )
        state.startRecording(format: .mp4, includesSystemAudio: false, includesMicrophone: false)
        try await waitUntil { state.recordingState.kind == .recording }

        state.capture(mode: .area, options: CaptureOptions())

        XCTAssertFalse(state.canStartCapture)
        XCTAssertTrue(capture.modes.isEmpty)
    }

    @MainActor
    func testTerminationWaitsForCaptureAndRecordingCleanup() async throws {
        let capture = GatedCaptureActionRecorder()
        let captureCancellation = GatedAsyncOperation()
        let recording = GatedCancellationRecordingController()
        let state = AppState(
            library: InMemoryAppLibrary(),
            recording: recording,
            exporter: AppCaptureExporterSpy(copyError: nil),
            captureAction: { mode, _, completion in capture.begin(mode, completion: completion) },
            cancelCaptureAction: { try await captureCancellation.run() },
            recordingTargetPicker: { .display(1) }
        )
        state.capture(mode: .scrolling, options: CaptureOptions())

        let captureReply = LockedValue<Bool?>(nil)
        let captureCoordinator = ApplicationTerminationCoordinator(
            flush: state.prepareForTermination,
            onFailure: { _ in XCTFail("Unexpected capture cleanup failure") }
        )
        captureCoordinator.beginTermination { shouldTerminate in
            captureReply.withValue { $0 = shouldTerminate }
        }
        await fulfillment(of: [captureCancellation.started], timeout: 1)
        XCTAssertNil(captureReply.value)
        XCTAssertTrue(state.isCaptureActive)
        await captureCancellation.release()
        try await waitUntil { captureReply.value == true }

        state.startRecording(format: .mp4, includesSystemAudio: false, includesMicrophone: false)
        try await waitUntil { state.recordingState.kind == .recording }
        let recordingReply = LockedValue<Bool?>(nil)
        let recordingCoordinator = ApplicationTerminationCoordinator(
            flush: state.prepareForTermination,
            onFailure: { _ in XCTFail("Unexpected recording cleanup failure") }
        )
        recordingCoordinator.beginTermination { shouldTerminate in
            recordingReply.withValue { $0 = shouldTerminate }
        }
        await fulfillment(of: [recording.cancelStarted], timeout: 1)
        XCTAssertNil(recordingReply.value)
        await recording.releaseCancel()
        try await waitUntil { recordingReply.value == true }
    }

    @MainActor
    func testTerminationPersistsFocusedAppStateTagDraftBeforeReplying() async throws {
        let record = CaptureRecord.reviewRecord(title: "Tagged")
        let library = GatedTagLibrary(record: record)
        let state = makeAppState(library: library, exporter: AppCaptureExporterSpy(copyError: nil))
        try await waitUntil { state.records == [record] }
        state.beginTagDraft(for: record)
        state.setTagDraft("urgent, launch", for: record.id)

        let reply = LockedValue<Bool?>(nil)
        let coordinator = ApplicationTerminationCoordinator(
            flush: state.prepareForTermination,
            onFailure: { _ in XCTFail("Unexpected tag persistence failure") }
        )
        coordinator.beginTermination { shouldTerminate in
            reply.withValue { $0 = shouldTerminate }
        }
        await fulfillment(of: [library.updateStarted], timeout: 1)
        XCTAssertNil(reply.value)
        await library.releaseUpdate()
        try await waitUntil { reply.value == true }

        let updates = await library.updates
        XCTAssertEqual(updates, [.init(id: record.id, tags: ["urgent", "launch"])])
    }

    @MainActor
    func testPermissionErrorsExposeExecutableRecoveryAndMicrophoneFallbackReusesTarget() async throws {
        let opened = LockedValue<[PresentedErrorRecovery]>([])
        let recording = MicrophoneFallbackRecordingController()
        let pickerCalls = LockedValue(0)
        let state = AppState(
            library: InMemoryAppLibrary(),
            recording: recording,
            exporter: AppCaptureExporterSpy(copyError: nil),
            captureAction: { _, _, completion in completion() },
            cancelCaptureAction: {},
            recordingTargetPicker: {
                pickerCalls.withValue { $0 += 1 }
                return .window(77)
            },
            recoveryAction: { recovery in opened.withValue { $0.append(recovery) } }
        )

        state.present(CaptureError.permissionDenied, title: "Capture Failed")
        XCTAssertEqual(state.presentedError?.recovery, .openScreenRecordingSettings)
        state.performPresentedErrorRecovery()
        XCTAssertEqual(opened.value, [.openScreenRecordingSettings])

        state.present(ScrollingCaptureError.accessibilityDenied, title: "Capture Failed")
        XCTAssertEqual(state.presentedError?.recovery, .openAccessibilitySettings)
        state.performPresentedErrorRecovery()
        XCTAssertEqual(
            opened.value,
            [.openScreenRecordingSettings, .openAccessibilitySettings]
        )

        state.startRecording(format: .mp4, includesSystemAudio: true, includesMicrophone: true)
        try await waitUntil { state.presentedError?.recovery == .recordWithoutMicrophone }
        state.performPresentedErrorRecovery()
        try await waitUntil { state.recordingState.kind == .recording }
        let requests = await recording.startRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].target, .window(77))
        XCTAssertTrue(requests[0].includesSystemAudio)
        XCTAssertTrue(requests[0].includesMicrophone)
        XCTAssertEqual(requests[1].target, .window(77))
        XCTAssertTrue(requests[1].includesSystemAudio)
        XCTAssertFalse(requests[1].includesMicrophone)
        XCTAssertEqual(pickerCalls.value, 1)
        let fallbackCancelCount = await recording.cancelCount
        XCTAssertEqual(fallbackCancelCount, 1)
    }

    @MainActor
    func testLibrarySearchIsLastQueryWinsAndReloadPreservesCurrentFilter() async throws {
        let library = OutOfOrderSearchLibrary()
        let state = AppState(
            library: library,
            recording: GatedAppRecordingController(),
            exporter: AppCaptureExporterSpy(copyError: nil),
            captureAction: { _, _, completion in completion() },
            cancelCaptureAction: {},
            recordingTargetPicker: { nil }
        )
        await fulfillment(of: [library.initialLoad], timeout: 1)
        state.search("old")
        state.search("new")
        await fulfillment(of: [library.twoSearches], timeout: 1)
        await library.resume(query: "new", records: [.reviewRecord(title: "new")])
        try await waitUntil { state.records.first?.title == "new" }
        await library.resume(query: "old", records: [.reviewRecord(title: "old")])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(state.searchText, "new")
        XCTAssertEqual(state.records.map(\.title), ["new"])

        state.receiveCapture(try makeCapture())
        try await waitUntil { await library.loadQueries.contains("new") }
        XCTAssertEqual(state.searchText, "new")
        XCTAssertFalse(state.records.contains(where: { $0.title == "old" }))
    }

    @MainActor
    func testLibraryLoadIssuesPresentWarningWhileKeepingValidRecords() async throws {
        let record = CaptureRecord.reviewRecord(title: "Valid capture")
        let corruptID = UUID()
        let library = IssueReportingLibrary(
            records: [record],
            issues: [CaptureLibraryLoadIssue(recordID: corruptID, reason: .corruptOriginal)]
        )
        let state = AppState(
            library: library,
            recording: GatedAppRecordingController(),
            exporter: AppCaptureExporterSpy(copyError: nil),
            captureAction: { _, _, completion in completion() },
            cancelCaptureAction: {},
            recordingTargetPicker: { nil }
        )

        try await waitUntil {
            state.records == [record] && state.presentedError?.title == "Library Warning"
        }

        XCTAssertEqual(state.records, [record])
        XCTAssertTrue(state.presentedError?.message.contains("1") == true)
        XCTAssertTrue(state.presentedError?.message.contains("skipped") == true)
        XCTAssertNil(state.presentedError?.recovery)
        let requestedIssueCount = await library.requestedIssueCount
        XCTAssertEqual(requestedIssueCount, 1)
    }
    @MainActor
    func testAppOwnedStateRetainsCaptureAndUsesOneAnnotationHistorySource() async throws {
        let image = try TestImage.solid(width: 320, height: 180, color: .blue)
        let capture = CapturedImage(
            id: UUID(),
            kind: .window,
            title: "Settings",
            createdAt: Date(),
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height)
        )
        let harness = try AppStateHarness()

        harness.state.receiveCapture(capture)
        harness.state.annotationEditor.applyDrag(
            tool: .highlight,
            from: NormalizedPoint(x: 0.1, y: 0.2),
            to: NormalizedPoint(x: 0.8, y: 0.7)
        )
        await Task.yield()

        XCTAssertEqual(harness.state.activeCapture?.id, capture.id)
        XCTAssertEqual(harness.state.annotationHistory, harness.state.annotationEditor.document)
        XCTAssertEqual(harness.state.annotationHistory.items.count, 1)

        harness.state.undoAnnotation()

        XCTAssertTrue(harness.state.annotationEditor.document.items.isEmpty)
        XCTAssertTrue(harness.state.annotationHistory.items.isEmpty)
    }

    @MainActor
    func testAppStateDispatchesEachCaptureModeWithoutCollapsingIntent() throws {
        let harness = try AppStateHarness()

        let screenshotModes = CaptureMode.allCases.filter { $0 != .record }
        for mode in CaptureMode.allCases {
            harness.state.capture(mode: mode, options: CaptureOptions())
        }

        XCTAssertEqual(harness.captureRecorder.modes, screenshotModes)
    }

    @MainActor
    func testCopyUsesImmutableActiveCaptureAndAnnotationSnapshot() async throws {
        let harness = try AppStateHarness()
        let capture = try makeCapture()
        harness.state.receiveCapture(capture)
        harness.state.annotationEditor.applyDrag(
            tool: .arrow,
            from: NormalizedPoint(x: 0.1, y: 0.1),
            to: NormalizedPoint(x: 0.8, y: 0.8)
        )

        harness.state.copyActiveCapture()
        await fulfillment(of: [harness.exporter.copyExpectation], timeout: 1)

        let storedSnapshot = await harness.exporter.copySnapshot
        let snapshot = try XCTUnwrap(storedSnapshot)
        XCTAssertEqual(snapshot.captureID, capture.id)
        XCTAssertEqual(snapshot.document.captureID, capture.id)
        XCTAssertEqual(snapshot.document.items.count, 1)
    }

    @MainActor
    func testGIFRecordingIsDistinctAndForcesAudioOff() async throws {
        let harness = try AppStateHarness()

        harness.state.startRecording(
            format: .gif,
            includesSystemAudio: true,
            includesMicrophone: true
        )
        await fulfillment(of: [harness.recordingRequests.expectation], timeout: 1)

        let request = try XCTUnwrap(harness.recordingRequests.requests.first)
        XCTAssertEqual(request.format, .gif)
        XCTAssertFalse(request.includesSystemAudio)
        XCTAssertFalse(request.includesMicrophone)
        XCTAssertEqual(request.target, .display(1))
    }

    @MainActor
    func testStoppingRecordingRegistersCommittedOutputInLibrary() async throws {
        let harness = try AppStateHarness()

        harness.state.startRecording(
            format: .mp4,
            includesSystemAudio: true,
            includesMicrophone: false
        )
        await fulfillment(of: [harness.recordingRequests.expectation], timeout: 1)
        harness.state.stopRecording()

        for _ in 0..<100 where harness.state.records.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(harness.state.records.count, 1)
        XCTAssertEqual(harness.state.records.first?.kind, .video)
        XCTAssertEqual(
            harness.state.records.first?.originalFilename,
            "originals/\(harness.outputURL.deletingPathExtension().lastPathComponent).mp4"
        )
        XCTAssertGreaterThan(try Data(contentsOf: harness.outputURL).count, 0)
    }

    @MainActor
    func testAsynchronousRecordingFailureUpdatesPresentedState() async throws {
        let root = temporaryDirectory()
        let session = AppStateFailureRecordingSession(
            outputURL: root.appendingPathComponent("originals/failure.mp4")
        )
        let requests = RecordingRequestRecorder()
        let state = AppState(
            library: CaptureLibraryStore(rootURL: root, ocr: AppStateOCR()),
            recording: RecordingEngine(sessionFactory: { request in
                requests.record(request)
                return session
            }),
            exporter: AppCaptureExporterSpy(copyError: nil),
            captureAction: { _, _, completion in completion() },
            cancelCaptureAction: {},
            recordingTargetPicker: { .window(42) }
        )
        state.startRecording(
            format: .mp4,
            includesSystemAudio: false,
            includesMicrophone: false
        )
        await fulfillment(of: [requests.expectation], timeout: 1)

        await session.fail(.recordingFailed("source disappeared"))
        for _ in 0..<100 where state.recordingState.kind != .failed {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(state.recordingState.kind, .failed)
        XCTAssertEqual(state.presentedError?.title, "Recording Failed")
        XCTAssertTrue(state.presentedError?.message.contains("source disappeared") == true)
    }

    @MainActor
    func testRecordingDoesNotPublishCompletedBeforeLibraryRegistration() async throws {
        let root = temporaryDirectory()
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let outputURL = originals.appendingPathComponent("output.mp4")
        try Data("media".utf8).write(to: outputURL)
        let session = AppStateRecordingSession(outputURL: outputURL)
        let requests = RecordingRequestRecorder()
        let exporter = GatedMediaExporter()
        let state = AppState(
            library: CaptureLibraryStore(rootURL: root, ocr: AppStateOCR()),
            recording: RecordingEngine(sessionFactory: { request in
                requests.record(request)
                return session
            }),
            exporter: exporter,
            captureAction: { _, _, completion in completion() },
            cancelCaptureAction: {},
            recordingTargetPicker: { .display(1) }
        )
        state.startRecording(
            format: .mp4,
            includesSystemAudio: false,
            includesMicrophone: false
        )
        await fulfillment(of: [requests.expectation], timeout: 1)

        state.stopRecording()
        await fulfillment(of: [exporter.inspectExpectation], timeout: 1)
        try await Task.sleep(for: .milliseconds(120))
        let stateBeforeRegistration = state.recordingState.kind
        await exporter.resume(
            RecordedMedia(
                id: UUID(),
                kind: .video,
                title: "output.mp4",
                createdAt: .now,
                pixelSize: PixelSize(width: 1, height: 1),
                duration: 1,
                originalURL: outputURL,
                thumbnail: try TestImage.solid(width: 1, height: 1, color: .black)
            )
        )

        XCTAssertEqual(stateBeforeRegistration, .stopping)
    }

    func testAspectFitTransformMapsLetterboxedPointIntoImageSpace() {
        let transform = CanvasTransform(
            canvasSize: CGSize(width: 1_000, height: 800),
            imageSize: CGSize(width: 1_000, height: 500),
            zoom: 1
        )

        XCTAssertEqual(
            transform.normalizedPoint(from: CGPoint(x: 500, y: 400)),
            NormalizedPoint(x: 0.5, y: 0.5)
        )
        XCTAssertNil(transform.normalizedPoint(from: CGPoint(x: 500, y: 50)))
    }

    func testCanvasTransformMapsNormalizedGeometryAtZoom() {
        let transform = CanvasTransform(
            canvasSize: CGSize(width: 1_000, height: 800),
            imageSize: CGSize(width: 1_000, height: 500),
            zoom: 2
        )

        XCTAssertEqual(transform.imageRect, CGRect(x: -500, y: -100, width: 2_000, height: 1_000))
        XCTAssertEqual(
            transform.canvasPoint(from: NormalizedPoint(x: 0.25, y: 0.75)),
            CGPoint(x: 0, y: 650)
        )
        XCTAssertEqual(
            transform.canvasRect(from: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
            CGRect(x: -300, y: 100, width: 600, height: 400)
        )
    }

    @MainActor
    func testEditorModelClampsZoomToSupportedRange() {
        let model = AnnotationEditorModel()

        model.zoom = 5
        XCTAssertEqual(model.zoom, 4)

        model.zoom = 0.1
        XCTAssertEqual(model.zoom, 0.25)
    }

    func testSelectIsTheOnlyToolThatAllowsItemManipulation() {
        XCTAssertEqual(AnnotationTool.allCases.first, .select)
        XCTAssertTrue(AnnotationTool.select.allowsItemManipulation)

        for tool in AnnotationTool.allCases where tool != .select {
            XCTAssertFalse(tool.allowsItemManipulation, "\(tool) must create instead of manipulating")
        }
    }

    func testSelectDragDoesNotCreateAnAnnotation() {
        var editor = makeEditor()

        editor.applyDrag(
            tool: .select,
            from: NormalizedPoint(x: 0.1, y: 0.2),
            to: NormalizedPoint(x: 0.8, y: 0.7),
            style: makeStyle()
        )

        XCTAssertTrue(editor.document.items.isEmpty)
    }

    func testResolvingPendingTextCommitsNonEmptyAndCancelsEmptyText() throws {
        var editor = makeEditor()
        let style = makeStyle()

        editor.beginText(at: NormalizedPoint(x: 0.2, y: 0.3), style: style)
        editor.updatePendingText("Review this")
        editor.resolvePendingText(style: style)

        guard case .text(let text) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected committed text")
        }
        XCTAssertEqual(text.text, "Review this")
        XCTAssertNil(editor.pendingText)

        editor.beginText(at: NormalizedPoint(x: 0.4, y: 0.5), style: style)
        editor.updatePendingText("   ")
        editor.resolvePendingText(style: style)

        XCTAssertEqual(editor.document.items.count, 1)
        XCTAssertNil(editor.pendingText)
    }

    func testBeginningTextAtSecondLocationCommitsCurrentDraft() throws {
        var editor = makeEditor()
        let style = makeStyle()
        let secondAnchor = NormalizedPoint(x: 0.7, y: 0.6)

        editor.beginText(at: NormalizedPoint(x: 0.2, y: 0.3), style: style)
        editor.updatePendingText("First note")
        editor.beginText(at: secondAnchor, style: style)

        guard case .text(let text) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected first draft to commit")
        }
        XCTAssertEqual(text.text, "First note")
        XCTAssertEqual(editor.pendingText?.anchor, secondAnchor)
        XCTAssertEqual(editor.pendingText?.text, "")
    }

    func testSelectingItemCommitsPendingTextBeforeSelectionChanges() throws {
        let arrowID = UUID()
        let style = makeStyle()
        var editor = makeEditor(items: [
            .arrow(.init(
                id: arrowID,
                start: NormalizedPoint(x: 0.1, y: 0.1),
                end: NormalizedPoint(x: 0.8, y: 0.8),
                color: .red,
                strokeWidth: 4
            )),
        ])

        editor.beginText(at: NormalizedPoint(x: 0.3, y: 0.4), style: style)
        editor.updatePendingText("Resolve me")
        editor.select(arrowID, style: style)

        XCTAssertEqual(editor.document.items.count, 2)
        guard case .text(let text) = editor.document.items.last else {
            return XCTFail("Expected pending text to commit")
        }
        XCTAssertEqual(text.text, "Resolve me")
        XCTAssertEqual(editor.selectedItemID, arrowID)
        XCTAssertNil(editor.pendingText)
    }

    func testHorizontalArrowResizeCanGainVerticalExtent() throws {
        let arrowID = UUID()
        var editor = makeEditor(items: [
            .arrow(.init(
                id: arrowID,
                start: NormalizedPoint(x: 0.2, y: 0.5),
                end: NormalizedPoint(x: 0.8, y: 0.5),
                color: .red,
                strokeWidth: 4
            )),
        ])

        editor.select(arrowID)
        editor.resizeSelection(
            handle: .topLeading,
            to: NormalizedPoint(x: 0.1, y: 0.2)
        )

        guard case .arrow(let arrow) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected arrow")
        }
        XCTAssertEqual(arrow.start, NormalizedPoint(x: 0.1, y: 0.2))
        XCTAssertEqual(arrow.end, NormalizedPoint(x: 0.8, y: 0.5))
    }

    func testVerticalArrowResizeCanGainHorizontalExtent() throws {
        let arrowID = UUID()
        var editor = makeEditor(items: [
            .arrow(.init(
                id: arrowID,
                start: NormalizedPoint(x: 0.5, y: 0.2),
                end: NormalizedPoint(x: 0.5, y: 0.8),
                color: .red,
                strokeWidth: 4
            )),
        ])

        editor.select(arrowID)
        editor.resizeSelection(
            handle: .topTrailing,
            to: NormalizedPoint(x: 0.8, y: 0.1)
        )

        guard case .arrow(let arrow) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected arrow")
        }
        XCTAssertEqual(arrow.start, NormalizedPoint(x: 0.8, y: 0.1))
        XCTAssertEqual(arrow.end, NormalizedPoint(x: 0.5, y: 0.8))
    }

    func testEdgeClampedNoOpMoveDoesNotConsumeUndo() throws {
        let itemID = UUID()
        let originalRect = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        var editor = makeEditor(items: [
            .highlight(.init(
                id: itemID,
                rect: originalRect,
                color: .red,
                amount: 0.5
            )),
        ])

        editor.select(itemID)
        editor.moveSelection(dx: 0.4, dy: 0)
        editor.moveSelection(dx: 0.1, dy: 0)
        editor.undo()

        guard case .highlight(let highlight) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected highlight")
        }
        assertEqual(highlight.rect, originalRect)
    }

    func testNoOpResizeDoesNotConsumeUndo() throws {
        let itemID = UUID()
        let originalRect = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        var editor = makeEditor(items: [
            .blur(.init(id: itemID, rect: originalRect, color: .red, amount: 8)),
        ])

        editor.select(itemID)
        editor.resizeSelection(
            handle: .bottomTrailing,
            to: NormalizedPoint(x: 0.8, y: 0.8)
        )
        editor.resizeSelection(
            handle: .bottomTrailing,
            to: NormalizedPoint(x: 0.8, y: 0.8)
        )
        editor.undo()

        guard case .blur(let blur) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected blur")
        }
        assertEqual(blur.rect, originalRect)
    }

    func testNoOpCropDoesNotConsumeUndo() {
        var editor = makeEditor()
        let start = NormalizedPoint(x: 0.1, y: 0.2)
        let end = NormalizedPoint(x: 0.8, y: 0.9)

        editor.applyDrag(tool: .crop, from: start, to: end, style: makeStyle())
        editor.applyDrag(tool: .crop, from: start, to: end, style: makeStyle())
        editor.undo()

        XCTAssertNil(editor.document.cropRect)
    }

    func testCropCanBeSelectedMovedAndUndoneWithoutChangingItsSize() throws {
        let original = NormalizedRect(x: 0.15, y: 0.2, width: 0.4, height: 0.3)
        var editor = AnnotationEditorState(
            document: AnnotationDocument(captureID: UUID(), cropRect: original)
        )

        editor.selectCrop()
        editor.moveCrop(dx: 0.8, dy: -0.5)

        XCTAssertTrue(editor.isCropSelected)
        assertEqual(
            editor.document.cropRect,
            NormalizedRect(x: 0.6, y: 0, width: 0.4, height: 0.3)
        )
        editor.undo()
        assertEqual(editor.document.cropRect, original)
    }

    func testCropEdgeAndCornerHandlesResizeUndoably() {
        let original = NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        var editor = AnnotationEditorState(
            document: AnnotationDocument(captureID: UUID(), cropRect: original)
        )

        editor.selectCrop()
        editor.resizeCrop(handle: .leading, to: NormalizedPoint(x: 0.1, y: 0.9))
        assertEqual(
            editor.document.cropRect,
            NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        )
        editor.resizeCrop(handle: .bottomTrailing, to: NormalizedPoint(x: 0.9, y: 0.85))
        assertEqual(
            editor.document.cropRect,
            NormalizedRect(x: 0.1, y: 0.2, width: 0.8, height: 0.65)
        )
        editor.undo()
        assertEqual(
            editor.document.cropRect,
            NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        )
        XCTAssertEqual(AnnotationResizeHandle.allCases.count, 8)
    }

    func testDirectTranslationClampsOneDeltaAndPreservesArrowShapeAtEdges() throws {
        let item = AnnotationItem.arrow(.init(
            id: UUID(),
            start: NormalizedPoint(x: 0.75, y: 0.2),
            end: NormalizedPoint(x: 0.95, y: 0.7),
            color: .red,
            strokeWidth: 4
        ))

        guard case .arrow(let arrow) = item.translated(dx: 0.4, dy: -0.5) else {
            return XCTFail("Expected arrow")
        }

        XCTAssertEqual(arrow.start.x, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(arrow.start.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(arrow.end.x, 1, accuracy: 0.000_001)
        XCTAssertEqual(arrow.end.y, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(arrow.end.x - arrow.start.x, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(arrow.end.y - arrow.start.y, 0.5, accuracy: 0.000_001)
    }

    @MainActor
    func testDetachedRendererPerformsWorkOffMainThread() async throws {
        let capture = try makeCapture()
        let recorder = RenderThreadRecorder()
        let service = DetachedAnnotationRenderService { source, _ in
            recorder.record(isMainThread: Thread.isMainThread)
            return source
        }

        let rendered = try await service.render(
            capture: capture,
            document: AnnotationDocument(captureID: capture.id)
        )

        XCTAssertEqual(rendered.width, capture.image.width)
        XCTAssertEqual(recorder.wasMainThread, false)
    }

    @MainActor
    func testExportFailureLeavesClipboardPublisherUntouched() async throws {
        let capture = try makeCapture()
        let clipboard = RecordingAnnotationClipboard()
        let coordinator = AnnotationExportCoordinator(
            renderService: FailingAnnotationRenderService(),
            clipboard: clipboard
        )

        do {
            try await coordinator.copy(
                capture: capture,
                document: AnnotationDocument(captureID: capture.id)
            )
            XCTFail("Expected rendering to fail")
        } catch TestAnnotationExportError.rendering {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(clipboard.publishCount, 0)
    }

    @MainActor
    func testAppStateSurfacesAndClearsPresentedExportError() async throws {
        let harness = try AppStateHarness(exportError: TestAnnotationExportError.rendering)
        harness.state.receiveCapture(try makeCapture())

        harness.state.copyActiveCapture()
        await fulfillment(of: [harness.exporter.copyExpectation], timeout: 1)
        for _ in 0..<10 where harness.state.presentedError == nil { await Task.yield() }

        XCTAssertEqual(harness.state.presentedError?.title, "Copy Failed")

        harness.state.dismissPresentedError()
        XCTAssertNil(harness.state.presentedError)
    }

    func testEditorCreatesArrowWithActiveStyle() throws {
        var editor = makeEditor()
        let style = makeStyle()

        editor.applyDrag(
            tool: .arrow,
            from: NormalizedPoint(x: 0.1, y: 0.2),
            to: NormalizedPoint(x: 0.8, y: 0.7),
            style: style
        )

        guard case .arrow(let arrow) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected an arrow")
        }
        XCTAssertEqual(arrow.start, NormalizedPoint(x: 0.1, y: 0.2))
        XCTAssertEqual(arrow.end, NormalizedPoint(x: 0.8, y: 0.7))
        XCTAssertEqual(arrow.color, style.color)
        XCTAssertEqual(arrow.strokeWidth, style.strokeWidth)
        XCTAssertEqual(editor.selectedItemID, arrow.id)
    }

    func testEditorCreatesHighlightRectangleWithActiveStyle() throws {
        var editor = makeEditor()
        let style = makeStyle()

        editor.applyDrag(
            tool: .highlight,
            from: NormalizedPoint(x: 0.8, y: 0.7),
            to: NormalizedPoint(x: 0.2, y: 0.3),
            style: style
        )

        guard case .highlight(let highlight) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected a highlight")
        }
        assertEqual(
            highlight.rect,
            NormalizedRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        )
        XCTAssertEqual(highlight.color, style.color)
        XCTAssertEqual(highlight.amount, style.opacity)
    }

    func testEditorCreatesBlurRectangleWithActiveRadius() throws {
        var editor = makeEditor()
        let style = makeStyle()

        editor.applyDrag(
            tool: .blur,
            from: NormalizedPoint(x: 0.15, y: 0.25),
            to: NormalizedPoint(x: 0.45, y: 0.55),
            style: style
        )

        guard case .blur(let blur) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected a blur")
        }
        assertEqual(
            blur.rect,
            NormalizedRect(x: 0.15, y: 0.25, width: 0.3, height: 0.3)
        )
        XCTAssertEqual(blur.amount, style.blurRadius)
    }

    func testEditorAppliesCropWithoutAddingAnAnnotation() {
        var editor = makeEditor()

        editor.applyDrag(
            tool: .crop,
            from: NormalizedPoint(x: 0.9, y: 0.85),
            to: NormalizedPoint(x: 0.1, y: 0.15),
            style: makeStyle()
        )

        XCTAssertTrue(editor.document.items.isEmpty)
        assertEqual(
            editor.document.cropRect,
            NormalizedRect(x: 0.1, y: 0.15, width: 0.8, height: 0.7)
        )
    }

    func testEditorCommitsInlineTextAtAnchor() throws {
        var editor = makeEditor()
        let style = makeStyle()

        editor.commitText(
            "Review this",
            at: NormalizedPoint(x: 0.75, y: 0.85),
            style: style
        )

        guard case .text(let text) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected text")
        }
        XCTAssertEqual(text.text, "Review this")
        assertEqual(
            text.bounds,
            NormalizedRect(x: 0.75, y: 0.85, width: 0.25, height: 0.12)
        )
        XCTAssertEqual(text.fontSize, style.fontSize)
        XCTAssertEqual(text.color, style.color)
    }

    func testEditorMovesSelectedItemAndPreservesItsSize() throws {
        let itemID = UUID()
        var editor = makeEditor(items: [
            .highlight(.init(
                id: itemID,
                rect: NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2),
                color: .red,
                amount: 0.5
            )),
        ])

        editor.select(itemID)
        editor.moveSelection(dx: 0.3, dy: 0.4)

        guard case .highlight(let highlight) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected a highlight")
        }
        assertEqual(
            highlight.rect,
            NormalizedRect(x: 0.5, y: 0.7, width: 0.4, height: 0.2)
        )
    }

    func testEditorResizesSelectedItemToNewBounds() throws {
        let itemID = UUID()
        var editor = makeEditor(items: [
            .blur(.init(
                id: itemID,
                rect: NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2),
                color: .red,
                amount: 8
            )),
        ])

        editor.select(itemID)
        editor.resizeSelection(to: NormalizedRect(x: 0.1, y: 0.15, width: 0.7, height: 0.6))

        guard case .blur(let blur) = try XCTUnwrap(editor.document.items.first) else {
            return XCTFail("Expected a blur")
        }
        assertEqual(
            blur.rect,
            NormalizedRect(x: 0.1, y: 0.15, width: 0.7, height: 0.6)
        )
    }

    func testEditorDeletesSelectionAndClearsSelection() {
        let itemID = UUID()
        var editor = makeEditor(items: [
            .arrow(.init(
                id: itemID,
                start: NormalizedPoint(x: 0.1, y: 0.1),
                end: NormalizedPoint(x: 0.8, y: 0.8),
                color: .red,
                strokeWidth: 4
            )),
        ])

        editor.select(itemID)
        editor.deleteSelection()

        XCTAssertTrue(editor.document.items.isEmpty)
        XCTAssertNil(editor.selectedItemID)
    }

    func testEditorUndoAndRedoWireThroughDocumentHistory() {
        var editor = makeEditor()

        editor.applyDrag(
            tool: .arrow,
            from: NormalizedPoint(x: 0.1, y: 0.1),
            to: NormalizedPoint(x: 0.8, y: 0.8),
            style: makeStyle()
        )
        editor.undo()
        XCTAssertTrue(editor.document.items.isEmpty)

        editor.redo()
        XCTAssertEqual(editor.document.items.count, 1)
    }

    func testUndoAndRedoRestoreWholeDocument() {
        let initial = AnnotationDocument(captureID: UUID())
        var history = AnnotationHistory(initial: initial, limit: 50)
        let arrow = AnnotationItem.arrow(.init(
            id: UUID(),
            start: .init(x: 0.1, y: 0.2),
            end: .init(x: 0.8, y: 0.7),
            color: .red,
            strokeWidth: 4
        ))

        history.commit { $0.items.append(arrow) }
        XCTAssertEqual(history.document.items, [arrow])

        history.undo()
        XCTAssertTrue(history.document.items.isEmpty)

        history.redo()
        XCTAssertEqual(history.document.items, [arrow])
    }

    func testDocumentCodableRoundTripPreservesAnnotationsAndCrop() throws {
        let document = AnnotationDocument(
            captureID: UUID(),
            items: [
                .arrow(.init(
                    id: UUID(),
                    start: .init(x: 0.1, y: 0.2),
                    end: .init(x: 0.8, y: 0.7),
                    color: .red,
                    strokeWidth: 4
                )),
                .text(.init(
                    id: UUID(),
                    bounds: .init(x: 0.2, y: 0.3, width: 0.4, height: 0.2),
                    text: "Review this",
                    fontSize: 18,
                    color: .red
                )),
                .highlight(.init(
                    id: UUID(),
                    rect: .init(x: 0.1, y: 0.5, width: 0.6, height: 0.25),
                    color: .red,
                    amount: 0.5
                )),
                .blur(.init(
                    id: UUID(),
                    rect: .init(x: 0.6, y: 0.1, width: 0.3, height: 0.3),
                    color: .red,
                    amount: 8
                )),
            ],
            cropRect: .init(x: 0.05, y: 0.1, width: 0.9, height: 0.8)
        )

        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: encoded)

        XCTAssertEqual(decoded, document)
    }

    func testNormalizedGeometryClampsToImageBounds() {
        XCTAssertEqual(NormalizedPoint(x: -0.25, y: 1.4), NormalizedPoint(x: 0, y: 1))
        XCTAssertEqual(
            NormalizedRect(x: 0.75, y: -0.2, width: 0.5, height: 1.5),
            NormalizedRect(x: 0.75, y: 0, width: 0.25, height: 1)
        )
        XCTAssertEqual(
            NormalizedRect(x: 0.2, y: 0.3, width: -1, height: -1),
            NormalizedRect(x: 0.2, y: 0.3, width: 0, height: 0)
        )
    }

    private func makeEditor(items: [AnnotationItem] = []) -> AnnotationEditorState {
        AnnotationEditorState(
            document: AnnotationDocument(captureID: UUID(), items: items),
            historyLimit: 50
        )
    }

    private func makeStyle() -> AnnotationStyle {
        AnnotationStyle(
            color: RGBAColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),
            strokeWidth: 6,
            opacity: 0.4,
            blurRadius: 12,
            fontSize: 22
        )
    }

    private func makeCapture() throws -> CapturedImage {
        let image = try TestImage.solid(width: 32, height: 18, color: .blue)
        return CapturedImage(
            id: UUID(),
            kind: .window,
            title: "Export",
            createdAt: Date(),
            image: image,
            pixelSize: PixelSize(width: image.width, height: image.height)
        )
    }

    private func assertEqual(
        _ actual: NormalizedRect?,
        _ expected: NormalizedRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("Expected normalized rectangle", file: file, line: line)
        }
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.000_001, file: file, line: line)
    }
}

private final class RenderThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWasMainThread: Bool?

    var wasMainThread: Bool? {
        lock.withLock { storedWasMainThread }
    }

    func record(isMainThread: Bool) {
        lock.withLock { storedWasMainThread = isMainThread }
    }
}

private enum TestAnnotationExportError: Error {
    case rendering
}

private struct FailingAnnotationRenderService: AnnotationRenderServicing {
    func render(
        capture: CapturedImage,
        document: AnnotationDocument
    ) async throws -> CGImage {
        throw TestAnnotationExportError.rendering
    }
}

@MainActor
private final class RecordingAnnotationClipboard: AnnotationClipboardPublishing {
    private(set) var publishCount = 0

    func publish(_ image: CGImage) {
        publishCount += 1
    }
}

private func writeAnnotationTestMP4(to url: URL) throws {
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
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(
        nil,
        32,
        24,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    ) == kCVReturnSuccess, let pixelBuffer else {
        throw CocoaError(.fileWriteUnknown)
    }
    guard adaptor.append(pixelBuffer, withPresentationTime: .zero),
          adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: 1, timescale: 30))
    else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.endSession(atSourceTime: CMTime(value: 2, timescale: 30))
    input.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    guard finished.wait(timeout: .now() + 5) == .success,
          writer.status == .completed else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
}

@MainActor
private struct AppStateHarness {
    let state: AppState
    let captureRecorder: AppCaptureActionRecorder
    let exporter: AppCaptureExporterSpy
    let recordingRequests: RecordingRequestRecorder
    let outputURL: URL

    init(exportError: Error? = nil) throws {
        let root = temporaryDirectory()
        let library = CaptureLibraryStore(rootURL: root, ocr: AppStateOCR())
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        outputURL = originals.appendingPathComponent("\(UUID().uuidString).mp4")
        try writeAnnotationTestMP4(to: outputURL)
        let session = AppStateRecordingSession(
            outputURL: outputURL
        )
        captureRecorder = AppCaptureActionRecorder()
        recordingRequests = RecordingRequestRecorder()
        exporter = AppCaptureExporterSpy(copyError: exportError)
        state = AppState(
            library: library,
            recording: RecordingEngine(sessionFactory: { [recordingRequests] request in
                recordingRequests.record(request)
                return session
            }),
            exporter: exporter,
            captureAction: { [captureRecorder] mode, _, completion in
                captureRecorder.record(mode)
                completion()
            },
            cancelCaptureAction: {},
            recordingTargetPicker: { .display(1) }
        )
    }
}

private final class RecordingRequestRecorder: @unchecked Sendable {
    let expectation = XCTestExpectation(description: "recording requested")
    private let lock = NSLock()
    private var storedRequests: [RecordingRequest] = []

    var requests: [RecordingRequest] {
        lock.withLock { storedRequests }
    }

    func record(_ request: RecordingRequest) {
        lock.withLock { storedRequests.append(request) }
        expectation.fulfill()
    }
}

@MainActor
private final class AppCaptureActionRecorder {
    private(set) var modes: [CaptureMode] = []

    func record(_ mode: CaptureMode) {
        modes.append(mode)
    }
}

private actor AppCaptureExporterSpy: AppCaptureExporting {
    struct CopySnapshot {
        let captureID: UUID
        let document: AnnotationDocument
    }

    nonisolated let copyExpectation = XCTestExpectation(description: "copy attempted")
    nonisolated let saveExpectation = XCTestExpectation(description: "save attempted")
    private let copyError: Error?
    private(set) var copySnapshot: CopySnapshot?
    private(set) var saveSnapshot: CopySnapshot?
    private(set) var discardedURLs: [URL] = []

    init(copyError: Error?) {
        self.copyError = copyError
    }

    func copy(capture: CapturedImage, document: AnnotationDocument) async throws {
        copySnapshot = CopySnapshot(captureID: capture.id, document: document)
        copyExpectation.fulfill()
        if let copyError { throw copyError }
    }

    func save(
        capture: CapturedImage,
        document: AnnotationDocument,
        format: ExportFormat
    ) async throws {
        saveSnapshot = CopySnapshot(captureID: capture.id, document: document)
        saveExpectation.fulfill()
    }

    func copyFile(at url: URL) async throws {}
    func saveFile(at url: URL) async throws {}
    func discardFile(at url: URL) async throws { discardedURLs.append(url) }

    func inspectRecording(
        at url: URL,
        format: RecordingFormat,
        createdAt: Date
    ) async throws -> RecordedMedia {
        RecordedMedia(
            id: UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID(),
            kind: format == .mp4 ? .video : .gif,
            title: url.lastPathComponent,
            createdAt: createdAt,
            pixelSize: PixelSize(width: 1, height: 1),
            duration: 1,
            originalURL: url,
            thumbnail: try TestImage.solid(width: 1, height: 1, color: .black)
        )
    }
}

private actor GatedMediaExporter: AppCaptureExporting {
    nonisolated let inspectExpectation = XCTestExpectation(description: "inspection started")
    private var continuation: CheckedContinuation<RecordedMedia, Never>?

    func copy(capture: CapturedImage, document: AnnotationDocument) async throws {}
    func save(capture: CapturedImage, document: AnnotationDocument, format: ExportFormat) async throws {}
    func copyFile(at url: URL) async throws {}
    func saveFile(at url: URL) async throws {}
    func discardFile(at url: URL) async throws {}

    func inspectRecording(
        at url: URL,
        format: RecordingFormat,
        createdAt: Date
    ) async throws -> RecordedMedia {
        inspectExpectation.fulfill()
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ media: RecordedMedia) {
        continuation?.resume(returning: media)
        continuation = nil
    }
}

private actor FailingInspectionExporter: AppCaptureExporting {
    nonisolated let discarded = XCTestExpectation(description: "orphan recording discarded")
    private(set) var discardedURLs: [URL] = []

    func copy(capture: CapturedImage, document: AnnotationDocument) async throws {}
    func save(capture: CapturedImage, document: AnnotationDocument, format: ExportFormat) async throws {}
    func copyFile(at url: URL) async throws {}
    func saveFile(at url: URL) async throws {}
    func inspectRecording(
        at url: URL,
        format: RecordingFormat,
        createdAt: Date
    ) async throws -> RecordedMedia {
        throw RecordingError.recordingFailed("inspection failed")
    }
    func discardFile(at url: URL) async throws {
        discardedURLs.append(url)
        discarded.fulfill()
    }
}

private actor AppStateRecordingSession: RecordingSession {
    nonisolated let failureEvents: AsyncStream<RecordingError> = AsyncStream { $0.finish() }
    let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() async throws {}
    func stop() async throws -> URL { outputURL }
    func cancel() async {}
}

private actor AppStateFailureRecordingSession: RecordingSession {
    nonisolated let failureEvents: AsyncStream<RecordingError>
    let outputURL: URL
    private let continuation: AsyncStream<RecordingError>.Continuation

    init(outputURL: URL) {
        self.outputURL = outputURL
        let stream = AsyncStream.makeStream(of: RecordingError.self)
        failureEvents = stream.stream
        continuation = stream.continuation
    }

    func start() async throws {}
    func stop() async throws -> URL { outputURL }
    func cancel() async { continuation.finish() }
    func fail(_ error: RecordingError) { continuation.yield(error) }
}

private struct AppStateOCR: OCRRecognizing {
    func recognizeText(in image: CGImage) async throws -> String { "" }
}

private enum AnnotationPersistenceTestError: Error {
    case failed
}

private actor GatedAnnotationSaveLibrary: AppLibraryServing {
    nonisolated let saveStarted = XCTestExpectation(description: "annotation save started")
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private(set) var savedDocuments: [AnnotationDocument] = []
    private let saveError: Error?

    init(saveError: Error? = nil) {
        self.saveError = saveError
    }

    func load(matching query: String) async throws -> [CaptureRecord] { [] }
    func search(_ query: String) async -> [CaptureRecord] { [] }
    func register(media: RecordedMedia) async throws -> CaptureRecord { .reviewRecord() }

    func saveAnnotations(
        _ document: AnnotationDocument,
        for id: UUID,
        editedAt: Date
    ) async throws {
        saveStarted.fulfill()
        await withCheckedContinuation { saveContinuation = $0 }
        if let saveError { throw saveError }
        savedDocuments.append(document)
    }

    func finishSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }

    func loadAnnotations(for id: UUID) async throws -> AnnotationDocument { .init(captureID: id) }
    func delete(id: UUID) async throws {}
    func updateTags(id: UUID, tags: [String]) async throws {}
    func originalURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func thumbnailURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func loadCapture(id: UUID) async throws -> CapturedImage { throw CocoaError(.fileNoSuchFile) }
}

private actor CountingAnnotationLibrary: AppLibraryServing {
    private(set) var saveCount = 0

    func load(matching query: String) async throws -> [CaptureRecord] { [] }
    func search(_ query: String) async -> [CaptureRecord] { [] }
    func register(media: RecordedMedia) async throws -> CaptureRecord { .reviewRecord() }
    func saveAnnotations(_ document: AnnotationDocument, for id: UUID, editedAt: Date) async throws {
        saveCount += 1
    }
    func loadAnnotations(for id: UUID) async throws -> AnnotationDocument { .init(captureID: id) }
    func delete(id: UUID) async throws {}
    func updateTags(id: UUID, tags: [String]) async throws {}
    func originalURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func thumbnailURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func loadCapture(id: UUID) async throws -> CapturedImage { throw CocoaError(.fileNoSuchFile) }
}

private actor PreviewOperationProbe {
    private(set) var startedMarkers: [Int] = []
    private(set) var maximumConcurrency = 0
    private var activeCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func render(source: CGImage, marker: Int) async throws -> CGImage {
        activeCount += 1
        maximumConcurrency = max(maximumConcurrency, activeCount)
        startedMarkers.append(marker)
        await withCheckedContinuation { continuations.append($0) }
        activeCount -= 1
        return source
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private func previewDocument(captureID: UUID, itemCount: Int) -> AnnotationDocument {
    AnnotationDocument(
        captureID: captureID,
        items: (0..<itemCount).map { index in
            .text(TextAnnotation(
                id: UUID(),
                bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2),
                text: "\(index)",
                fontSize: 12,
                color: .red
            ))
        }
    )
}

private func reviewAnnotationDocument(captureID: UUID) -> AnnotationDocument {
    AnnotationDocument(
        captureID: captureID,
        items: [
            .text(TextAnnotation(
                id: UUID(),
                bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.2),
                text: "Saved",
                fontSize: 18,
                color: .red
            )),
            .blur(RectAnnotation(
                id: UUID(),
                rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                color: .red,
                amount: 9
            )),
        ],
        cropRect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    )
}

@MainActor
private func makeAppState(
    library: any AppLibraryServing,
    exporter: any AppCaptureExporting
) -> AppState {
    AppState(
        library: library,
        recording: GatedAppRecordingController(),
        exporter: exporter,
        captureAction: { _, _, completion in completion() },
        cancelCaptureAction: {},
        recordingTargetPicker: { nil }
    )
}

@MainActor
private func waitUntil(
    attempts: Int = 200,
    _ condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.coderValueNotFound)
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func withValue<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.withLock { operation(&stored) }
    }
}

private actor GatedAppRecordingPicker {
    nonisolated let started = XCTestExpectation(description: "recording picker started")
    private var continuation: CheckedContinuation<RecordingTarget?, Never>?
    private(set) var callCount = 0

    func pick() async -> RecordingTarget? {
        callCount += 1
        started.fulfill()
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ target: RecordingTarget?) {
        continuation?.resume(returning: target)
        continuation = nil
    }
}

private actor GatedAppRecordingController: AppRecordingControlling {
    nonisolated let startEntered = XCTestExpectation(description: "recording start entered")
    private(set) var startRequests: [RecordingRequest] = []
    private(set) var cancelCount = 0
    private var currentState: RecordingState
    private var firstStartContinuation: CheckedContinuation<Void, Never>?
    private let gatesFirstStart: Bool
    let outputURL: URL

    init(gatesFirstStart: Bool = false) {
        self.gatesFirstStart = gatesFirstStart
        currentState = .idle
        outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).mp4")
    }

    var state: RecordingState { currentState }

    func start(request: RecordingRequest) async throws {
        startRequests.append(request)
        if gatesFirstStart && startRequests.count == 1 {
            startEntered.fulfill()
            await withCheckedContinuation { firstStartContinuation = $0 }
        }
        currentState = .recording(startedAt: .now)
    }

    func releaseFirstStart() {
        firstStartContinuation?.resume()
        firstStartContinuation = nil
    }

    func stop() async throws -> URL {
        currentState = .completed(outputURL)
        return outputURL
    }

    func cancel() async {
        cancelCount += 1
        currentState = .idle
    }
}

private actor MicrophoneFallbackRecordingController: AppRecordingControlling {
    private(set) var startRequests: [RecordingRequest] = []
    private(set) var cancelCount = 0
    private var currentState: RecordingState = .idle

    var state: RecordingState { currentState }

    func start(request: RecordingRequest) async throws {
        startRequests.append(request)
        if startRequests.count == 1 { throw RecordingError.microphonePermissionDenied }
        currentState = .recording(startedAt: .now)
    }

    func stop() async throws -> URL { throw RecordingError.recordingFailed("unused") }
    func cancel() async { cancelCount += 1; currentState = .idle }
}

private actor InMemoryAppLibrary: AppLibraryServing {
    private var records: [CaptureRecord] = []

    func load(matching query: String) async throws -> [CaptureRecord] { records }
    func search(_ query: String) async -> [CaptureRecord] { records }
    func register(media: RecordedMedia) async throws -> CaptureRecord {
        let record = CaptureRecord.reviewRecord(id: media.id, title: media.title, kind: media.kind)
        records.append(record)
        return record
    }
    func saveAnnotations(_ document: AnnotationDocument, for id: UUID, editedAt: Date) async throws {}
    func loadAnnotations(for id: UUID) async throws -> AnnotationDocument {
        AnnotationDocument(captureID: id)
    }
    func delete(id: UUID) async throws { records.removeAll { $0.id == id } }
    func updateTags(id: UUID, tags: [String]) async throws {}
    func originalURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func thumbnailURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func loadCapture(id: UUID) async throws -> CapturedImage { throw CocoaError(.fileNoSuchFile) }
}

private actor IssueReportingLibrary: AppLibraryServing {
    let records: [CaptureRecord]
    let issues: [CaptureLibraryLoadIssue]
    private(set) var requestedIssueCount = 0

    init(records: [CaptureRecord], issues: [CaptureLibraryLoadIssue]) {
        self.records = records
        self.issues = issues
    }

    func load(matching query: String) async throws -> [CaptureRecord] { records }
    func loadIssues() -> [CaptureLibraryLoadIssue] {
        requestedIssueCount += 1
        return issues
    }
    func search(_ query: String) async -> [CaptureRecord] { records }
    func register(media: RecordedMedia) async throws -> CaptureRecord { .reviewRecord() }
    func saveAnnotations(_ document: AnnotationDocument, for id: UUID, editedAt: Date) async throws {}
    func loadAnnotations(for id: UUID) async throws -> AnnotationDocument { .init(captureID: id) }
    func delete(id: UUID) async throws {}
    func updateTags(id: UUID, tags: [String]) async throws {}
    func originalURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func thumbnailURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func loadCapture(id: UUID) async throws -> CapturedImage { throw CocoaError(.fileNoSuchFile) }
}

private actor GatedRegistrationLibrary: AppLibraryServing {
    nonisolated let registrationStarted = XCTestExpectation(description: "registration started")
    private var registrationContinuation: CheckedContinuation<Void, Never>?
    private(set) var registeredIDs: [UUID] = []
    private var records: [CaptureRecord] = []

    func load(matching query: String) async throws -> [CaptureRecord] { records }
    func search(_ query: String) async -> [CaptureRecord] { records }
    func register(media: RecordedMedia) async throws -> CaptureRecord {
        registrationStarted.fulfill()
        await withCheckedContinuation { registrationContinuation = $0 }
        registeredIDs.append(media.id)
        let record = CaptureRecord.reviewRecord(id: media.id, title: media.title, kind: media.kind)
        records.append(record)
        return record
    }
    func resumeRegistration() { registrationContinuation?.resume(); registrationContinuation = nil }
    func saveAnnotations(_ document: AnnotationDocument, for id: UUID, editedAt: Date) async throws {}
    func loadAnnotations(for id: UUID) async throws -> AnnotationDocument { .init(captureID: id) }
    func delete(id: UUID) async throws {}
    func updateTags(id: UUID, tags: [String]) async throws {}
    func originalURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func thumbnailURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func loadCapture(id: UUID) async throws -> CapturedImage { throw CocoaError(.fileNoSuchFile) }
}

private actor OutOfOrderSearchLibrary: AppLibraryServing {
    nonisolated let initialLoad = XCTestExpectation(description: "initial load")
    nonisolated let twoSearches: XCTestExpectation = {
        let expectation = XCTestExpectation(description: "two searches")
        expectation.expectedFulfillmentCount = 2
        return expectation
    }()
    private var continuations: [String: CheckedContinuation<[CaptureRecord], Never>] = [:]
    private(set) var loadQueries: [String] = []

    func load(matching query: String) async throws -> [CaptureRecord] {
        loadQueries.append(query)
        if loadQueries.count == 1 { initialLoad.fulfill() }
        return query == "new" ? [.reviewRecord(title: "new")] : []
    }

    func search(_ query: String) async -> [CaptureRecord] {
        twoSearches.fulfill()
        return await withCheckedContinuation { continuations[query] = $0 }
    }

    func resume(query: String, records: [CaptureRecord]) {
        continuations.removeValue(forKey: query)?.resume(returning: records)
    }
    func register(media: RecordedMedia) async throws -> CaptureRecord { .reviewRecord() }
    func saveAnnotations(_ document: AnnotationDocument, for id: UUID, editedAt: Date) async throws {}
    func loadAnnotations(for id: UUID) async throws -> AnnotationDocument { .init(captureID: id) }
    func delete(id: UUID) async throws {}
    func updateTags(id: UUID, tags: [String]) async throws {}
    func originalURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func thumbnailURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func loadCapture(id: UUID) async throws -> CapturedImage { throw CocoaError(.fileNoSuchFile) }
}

@MainActor
private final class GatedCaptureActionRecorder {
    private(set) var modes: [CaptureMode] = []
    private var completion: AppCaptureCompletion?
    private let completesImmediately: Bool

    init(completesImmediately: Bool = false) {
        self.completesImmediately = completesImmediately
    }

    func begin(_ mode: CaptureMode, completion: AppCaptureCompletion) {
        modes.append(mode)
        if completesImmediately {
            completion()
        } else {
            self.completion = completion
        }
    }

    func complete() {
        completion?()
        completion = nil
    }
}

private actor GatedAsyncOperation {
    nonisolated let started = XCTestExpectation(description: "async operation started")
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async throws {
        started.fulfill()
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor GatedCancellationRecordingController: AppRecordingControlling {
    nonisolated let cancelStarted = XCTestExpectation(description: "recording cancel started")
    private var currentState: RecordingState = .idle
    private var cancelContinuation: CheckedContinuation<Void, Never>?

    var state: RecordingState { currentState }

    func start(request: RecordingRequest) async throws {
        currentState = .recording(startedAt: .now)
    }

    func stop() async throws -> URL {
        throw RecordingError.recordingFailed("unused")
    }

    func cancel() async {
        cancelStarted.fulfill()
        await withCheckedContinuation { cancelContinuation = $0 }
        currentState = .idle
    }

    func releaseCancel() {
        cancelContinuation?.resume()
        cancelContinuation = nil
    }
}

private enum RegistrationTestError: Error {
    case failed
}

private actor FailingRegistrationLibrary: AppLibraryServing {
    func load(matching query: String) async throws -> [CaptureRecord] { [] }
    func search(_ query: String) async -> [CaptureRecord] { [] }
    func register(media: RecordedMedia) async throws -> CaptureRecord {
        throw RegistrationTestError.failed
    }
    func saveAnnotations(_ document: AnnotationDocument, for id: UUID, editedAt: Date) async throws {}
    func loadAnnotations(for id: UUID) async throws -> AnnotationDocument { .init(captureID: id) }
    func delete(id: UUID) async throws {}
    func updateTags(id: UUID, tags: [String]) async throws {}
    func originalURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func thumbnailURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func loadCapture(id: UUID) async throws -> CapturedImage { throw CocoaError(.fileNoSuchFile) }
}

private actor GatedTagLibrary: AppLibraryServing {
    struct Update: Equatable {
        let id: UUID
        let tags: [String]
    }

    nonisolated let updateStarted = XCTestExpectation(description: "tag update started")
    private let record: CaptureRecord
    private var updateContinuation: CheckedContinuation<Void, Never>?
    private(set) var updates: [Update] = []

    init(record: CaptureRecord) {
        self.record = record
    }

    func load(matching query: String) async throws -> [CaptureRecord] { [record] }
    func search(_ query: String) async -> [CaptureRecord] { [record] }
    func register(media: RecordedMedia) async throws -> CaptureRecord { record }
    func saveAnnotations(_ document: AnnotationDocument, for id: UUID, editedAt: Date) async throws {}
    func loadAnnotations(for id: UUID) async throws -> AnnotationDocument { .init(captureID: id) }
    func delete(id: UUID) async throws {}
    func updateTags(id: UUID, tags: [String]) async throws {
        updateStarted.fulfill()
        await withCheckedContinuation { updateContinuation = $0 }
        updates.append(Update(id: id, tags: tags))
    }
    func releaseUpdate() {
        updateContinuation?.resume()
        updateContinuation = nil
    }
    func originalURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func thumbnailURL(for id: UUID) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func loadCapture(id: UUID) async throws -> CapturedImage { throw CocoaError(.fileNoSuchFile) }
}

private extension CaptureRecord {
    static func reviewRecord(
        id: UUID = UUID(),
        title: String = "Record",
        kind: CaptureKind = .area
    ) -> CaptureRecord {
        CaptureRecord(
            id: id,
            kind: kind,
            title: title,
            createdAt: .now,
            lastEditedAt: .now,
            pixelSize: PixelSize(width: 1, height: 1),
            duration: nil,
            originalFilename: "originals/\(id.uuidString).\(kind == .video ? "mp4" : kind == .gif ? "gif" : "png")",
            editedFilename: nil,
            thumbnailFilename: "thumbnails/\(id.uuidString).png",
            annotationFilename: nil,
            ocrText: "",
            tags: []
        )
    }
}

private func reviewRecordedMedia(url: URL) throws -> RecordedMedia {
    let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
    return RecordedMedia(
        id: id,
        kind: .video,
        title: url.lastPathComponent,
        createdAt: .now,
        pixelSize: PixelSize(width: 1, height: 1),
        duration: 1,
        originalURL: url,
        thumbnail: try TestImage.solid(width: 1, height: 1, color: .black)
    )
}
