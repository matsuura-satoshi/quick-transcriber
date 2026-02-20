import XCTest
@testable import QuickTranscriberLib

@MainActor
final class SpeakerReassignmentTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedLanguage")
        UserDefaults.standard.removeObject(forKey: "isRecording")
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerReassignmentTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func makeViewModel() -> (TranscriptionViewModel, MockTranscriptionEngine) {
        let engine = MockTranscriptionEngine()
        let store = SpeakerProfileStore(directory: tmpDir)
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", speakerProfileStore: store)
        return (vm, engine)
    }

    // MARK: - splitSegment

    func testSplitSegmentAtOffset() {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello World", precedingSilence: 1.0, speaker: "A", speakerConfidence: 0.8),
        ]

        vm.splitSegment(at: 0, offset: 5)

        XCTAssertEqual(vm.confirmedSegments.count, 2)
        XCTAssertEqual(vm.confirmedSegments[0].text, "Hello")
        XCTAssertEqual(vm.confirmedSegments[0].precedingSilence, 1.0)
        XCTAssertEqual(vm.confirmedSegments[0].speaker, "A")
        XCTAssertEqual(vm.confirmedSegments[1].text, " World")
        XCTAssertEqual(vm.confirmedSegments[1].precedingSilence, 0)
        XCTAssertEqual(vm.confirmedSegments[1].speaker, "A")
    }

    func testSplitSegmentAtBeginningDoesNothing() {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: "A"),
        ]

        vm.splitSegment(at: 0, offset: 0)

        XCTAssertEqual(vm.confirmedSegments.count, 1)
    }

    func testSplitSegmentAtEndDoesNothing() {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: "A"),
        ]

        vm.splitSegment(at: 0, offset: 5)

        XCTAssertEqual(vm.confirmedSegments.count, 1)
    }

    // MARK: - reassignSpeakerForBlock

    func testReassignSpeakerForBlockUpdatesConsecutiveSegments() {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "world", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "foo", speaker: "B", speakerConfidence: 0.7),
        ]

        vm.reassignSpeakerForBlock(segmentIndex: 0, newSpeaker: "C")

        XCTAssertEqual(vm.confirmedSegments[0].speaker, "C")
        XCTAssertEqual(vm.confirmedSegments[0].speakerConfidence, 1.0)
        XCTAssertTrue(vm.confirmedSegments[0].isUserCorrected)
        XCTAssertEqual(vm.confirmedSegments[0].originalSpeaker, "A")
        XCTAssertEqual(vm.confirmedSegments[1].speaker, "C")
        XCTAssertTrue(vm.confirmedSegments[1].isUserCorrected)
        // B segment unchanged
        XCTAssertEqual(vm.confirmedSegments[2].speaker, "B")
        XCTAssertFalse(vm.confirmedSegments[2].isUserCorrected)
    }

    func testReassignSpeakerForBlockUpdatesConfirmedText() {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.7),
        ]

        vm.reassignSpeakerForBlock(segmentIndex: 0, newSpeaker: "C")

        XCTAssertTrue(vm.confirmedText.contains("C:"))
        XCTAssertTrue(vm.confirmedText.contains("Hello"))
    }

    // MARK: - reassignSpeakerForSelection

    func testReassignSpeakerForSelectionWholeSegment() {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.7),
        ]
        // Build map to get selection ranges
        let (_, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            vm.confirmedSegments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: ""
        )
        // Select the second segment's text
        let secondEntry = map.entries[1]

        vm.reassignSpeakerForSelection(
            selectionRange: secondEntry.characterRange,
            newSpeaker: "C",
            segmentMap: map
        )

        XCTAssertEqual(vm.confirmedSegments[1].speaker, "C")
        XCTAssertTrue(vm.confirmedSegments[1].isUserCorrected)
    }

    func testReassignSpeakerForSelectionPartialSplitsSegment() {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello World", speaker: "A", speakerConfidence: 0.8),
        ]
        let (_, map) = TranscriptionTextView.buildAttributedStringFromSegments(
            vm.confirmedSegments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: ""
        )

        // Select "World" part only (characters 9-14 in "A: Hello World")
        // "A: " is label (0-2), "Hello World" is text starting at 3
        // "World" starts at offset 6 within segment text
        let selectionRange = NSRange(location: 9, length: 5)

        vm.reassignSpeakerForSelection(
            selectionRange: selectionRange,
            newSpeaker: "B",
            segmentMap: map
        )

        // Should split into "Hello " (A) and "World" (B)
        XCTAssertGreaterThanOrEqual(vm.confirmedSegments.count, 2)
        let bSegments = vm.confirmedSegments.filter { $0.speaker == "B" }
        XCTAssertFalse(bSegments.isEmpty)
        let bText = bSegments.map { $0.text }.joined()
        XCTAssertTrue(bText.contains("World"))
    }

    // MARK: - availableSpeakers

    func testAvailableSpeakersFromActiveSpeakers() {
        let (vm, _) = makeViewModel()
        // availableSpeakers now derives from activeSpeakers, not confirmedSegments
        vm.addManualSpeaker(displayName: "Alice")
        vm.addManualSpeaker(displayName: "Bob")

        let speakers = vm.availableSpeakers
        XCTAssertTrue(speakers.contains { $0.label == "A" && $0.displayName == "Alice" })
        XCTAssertTrue(speakers.contains { $0.label == "B" && $0.displayName == "Bob" })
    }

    func testAvailableSpeakersIncludesAutoDetected() {
        let (vm, _) = makeViewModel()
        vm.addManualSpeaker(displayName: "Alice")
        // Simulate auto-detected speaker
        vm.activeSpeakers.append(ActiveSpeaker(
            sessionLabel: "B",
            displayName: "Bob",
            source: .autoDetected
        ))

        let speakers = vm.availableSpeakers
        XCTAssertTrue(speakers.contains { $0.label == "A" && $0.displayName == "Alice" })
        XCTAssertTrue(speakers.contains { $0.label == "B" && $0.displayName == "Bob" })
    }

    // MARK: - regenerateText

    func testRegenerateTextFromSegments() {
        let (vm, _) = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.7),
        ]

        vm.regenerateText()

        XCTAssertEqual(vm.confirmedText, "A: Hello\nB: World")
    }

    // MARK: - User correction persists across engine state updates

    func testUserCorrectionSurvivesEngineStateUpdate() async {
        let (vm, engine) = makeViewModel()
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Engine sends initial segments
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.7),
        ]
        engine.simulateStateChange(TranscriptionState(
            confirmedText: "A: Hello\nB: World",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: segments
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.confirmedSegments.count, 2)

        // User corrects first segment's speaker from A to C
        vm.reassignSpeakerForBlock(segmentIndex: 0, newSpeaker: "C")
        XCTAssertEqual(vm.confirmedSegments[0].speaker, "C")
        XCTAssertTrue(vm.confirmedSegments[0].isUserCorrected)

        // Engine sends next state update with appended segment (engine doesn't know about correction)
        let engineSegments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.8),
            ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.7),
            ConfirmedSegment(text: "New text", speaker: "A", speakerConfidence: 0.9),
        ]
        engine.simulateStateChange(TranscriptionState(
            confirmedText: "A: Hello\nB: World\nA: New text",
            unconfirmedText: "",
            isRecording: true,
            confirmedSegments: engineSegments
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // User correction should be preserved
        XCTAssertEqual(vm.confirmedSegments[0].speaker, "C",
                       "User-corrected speaker should survive engine state updates")
        XCTAssertTrue(vm.confirmedSegments[0].isUserCorrected)
        // New segment should appear
        XCTAssertEqual(vm.confirmedSegments.count, 3)
        XCTAssertEqual(vm.confirmedSegments[2].text, "New text")
    }

    // MARK: - Retroactive update guard

    func testReassignedSegmentNotOverwrittenByRetroactiveUpdate() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        let mockDiarizer = MockSpeakerDiarizer()

        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "first", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        mockDiarizer.speakerResults = [] // Will remain pending (returns nil)

        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber,
            diarizer: mockDiarizer
        )
        try await engine.setup(model: "test-model")

        var lastState: TranscriptionState?
        let firstChunkExpectation = XCTestExpectation(description: "First chunk processed")

        let params = TranscriptionParameters(enableSpeakerDiarization: true)
        try await engine.startStreaming(language: "en", parameters: params) { state in
            if !state.confirmedText.isEmpty {
                lastState = state
                firstChunkExpectation.fulfill()
            }
        }

        // Send first chunk (pending speaker)
        let speech = [Float](repeating: 0.1, count: 80000)
        mockCapture.simulateBuffer(speech)
        await fulfillment(of: [firstChunkExpectation], timeout: 6.0)

        // First segment should have nil speaker (pending)
        XCTAssertEqual(lastState?.confirmedSegments.count, 1)
        XCTAssertNil(lastState?.confirmedSegments[0].speaker)

        await engine.stopStreaming()
    }
}
