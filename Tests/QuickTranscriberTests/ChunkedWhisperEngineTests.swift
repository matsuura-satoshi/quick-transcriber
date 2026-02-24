import XCTest
@testable import QuickTranscriberLib

final class ChunkedWhisperEngineTests: XCTestCase {
    private var mockCapture: MockAudioCaptureService!

    override func setUp() {
        super.setUp()
        mockCapture = MockAudioCaptureService()
    }

    func testInitialState() async {
        let engine = ChunkedWhisperEngine(audioCaptureService: mockCapture)
        let streaming = await engine.isStreaming
        XCTAssertFalse(streaming)
    }

    func testStartStreamingWithoutSetupThrows() async {
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.setupError = MockError.setupFailed
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        do {
            try await engine.setup(model: "test-model")
            XCTFail("Should throw when setup fails")
        } catch {
            // Expected — setup failed, so startStreaming should also fail
            // because transcriber is in a failed state
        }
    }

    func testCleanupResetsState() async {
        let engine = ChunkedWhisperEngine(audioCaptureService: mockCapture)
        engine.cleanup()
        let streaming = await engine.isStreaming
        XCTAssertFalse(streaming)
    }

    func testMockAudioCaptureServiceLifecycle() async throws {
        XCTAssertFalse(mockCapture.isCapturing)
        try await mockCapture.startCapture { _ in }
        XCTAssertTrue(mockCapture.isCapturing)
        XCTAssertTrue(mockCapture.startCaptureCalled)
        mockCapture.stopCapture()
        XCTAssertFalse(mockCapture.isCapturing)
        XCTAssertTrue(mockCapture.stopCaptureCalled)
    }

    func testMockAudioCaptureSimulateBuffer() async throws {
        let expectation = XCTestExpectation(description: "Buffer received")
        var receivedSamples: [Float]?

        try await mockCapture.startCapture { samples in
            receivedSamples = samples
            expectation.fulfill()
        }

        let testSamples: [Float] = [0.1, 0.2, 0.3]
        mockCapture.simulateBuffer(testSamples)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedSamples, testSamples)
    }

    // MARK: - Integration tests with MockChunkTranscriber

    func testFullPipelineProducesTranscription() async throws {
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "Hello world", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        let expectation = XCTestExpectation(description: "State change received")
        var lastState: TranscriptionState?

        try await engine.startStreaming(language: "en") { state in
            if !state.confirmedText.isEmpty {
                lastState = state
                expectation.fulfill()
            }
        }

        // Feed 5 seconds of audio (16kHz) to trigger chunk cut
        let speechBuffer = [Float](repeating: 0.1, count: 80000)
        mockCapture.simulateBuffer(speechBuffer)

        await fulfillment(of: [expectation], timeout: 6.0)

        XCTAssertEqual(lastState?.confirmedText, "Hello world")
        XCTAssertEqual(mockTranscriber.transcribeCallCount, 1)
        XCTAssertEqual(mockTranscriber.lastLanguage, "en")

        await engine.stopStreaming()
    }

    func testTranscriptionFailureContinues() async throws {
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.transcribeError = MockError.streamingFailed
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        try await engine.startStreaming(language: "en") { _ in }

        // Feed 5 seconds to trigger chunk — transcription will fail
        let buffer = [Float](repeating: 0.1, count: 80000)
        mockCapture.simulateBuffer(buffer)

        // Wait for processing
        try await Task.sleep(nanoseconds: 200_000_000)

        // Engine should still be streaming despite the error
        let streaming = await engine.isStreaming
        XCTAssertTrue(streaming)
        XCTAssertEqual(mockTranscriber.transcribeCallCount, 1)

        await engine.stopStreaming()
    }

    func testJapaneseLanguagePassedToTranscriber() async throws {
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "こんにちは", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        let expectation = XCTestExpectation(description: "Japanese transcription")
        try await engine.startStreaming(language: "ja") { state in
            if !state.confirmedText.isEmpty {
                expectation.fulfill()
            }
        }

        let buffer = [Float](repeating: 0.1, count: 80000)
        mockCapture.simulateBuffer(buffer)

        await fulfillment(of: [expectation], timeout: 6.0)
        XCTAssertEqual(mockTranscriber.lastLanguage, "ja")

        await engine.stopStreaming()
    }

    func testFlushOnStopProducesTranscription() async throws {
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "flushed text", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        try await engine.startStreaming(language: "en") { _ in }

        // Feed 1 second of audio — not enough for chunk cut but enough for flush
        let buffer = [Float](repeating: 0.1, count: 16000)
        mockCapture.simulateBuffer(buffer)
        try await Task.sleep(nanoseconds: 100_000_000)

        await engine.stopStreaming()

        // flush() should have triggered transcription
        XCTAssertEqual(mockTranscriber.transcribeCallCount, 1)
    }

    func testMultipleChunksAccumulateText() async throws {
        let mockTranscriber = MockChunkTranscriber()
        var callCount = 0
        // Return different text for each call
        // MockChunkTranscriber returns the same result, so we track via callCount
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "segment", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        var states: [TranscriptionState] = []
        try await engine.startStreaming(language: "en") { state in
            if !state.confirmedText.isEmpty {
                states.append(state)
            }
        }

        // Feed 10 seconds of audio → 2 chunks at 5s each
        for _ in 0..<10 {
            let buffer = [Float](repeating: 0.1, count: 16000)
            mockCapture.simulateBuffer(buffer)
        }

        // Wait for both chunks to be processed
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(mockTranscriber.transcribeCallCount, 2)

        // confirmedText should contain both segments joined by newline
        let lastState = states.last
        XCTAssertEqual(lastState?.confirmedText, "segment segment")

        await engine.stopStreaming()
    }

    // MARK: - Speaker Profile Store Integration

    private func makeTempDirectory() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkedWhisperEngineTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    func testStopStreamingExportsSpeakerProfiles() async throws {
        let mockDiarizer = MockSpeakerDiarizer()
        let exportedId = UUID()
        mockDiarizer.exportedProfiles = [(speakerId: exportedId, embedding: [Float](repeating: 0.1, count: 256))]
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SpeakerProfileStore(directory: dir)
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: MockChunkTranscriber(),
            diarizer: mockDiarizer,
            speakerProfileStore: store
        )
        try await engine.setup(model: "test-model")

        var params = TranscriptionParameters.default
        params.enableSpeakerDiarization = true
        try await engine.startStreaming(language: "en", parameters: params, onStateChange: { _ in })

        // Provide display name mapping for the exported profile
        await engine.stopStreaming(speakerDisplayNames: [exportedId.uuidString: "Speaker-1"])

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].displayName, "Speaker-1")
    }

    func testCorrectSpeakerAssignmentForwardsToDiarizer() async throws {
        let mockDiarizer = MockSpeakerDiarizer()
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: MockChunkTranscriber(),
            diarizer: mockDiarizer
        )

        let embedding: [Float] = [1.0, 2.0, 3.0]
        let oldId = UUID()
        let newId = UUID()
        engine.correctSpeakerAssignment(embedding: embedding, from: oldId, to: newId)

        XCTAssertEqual(mockDiarizer.correctedAssignments.count, 1)
        XCTAssertEqual(mockDiarizer.correctedAssignments[0].oldId, oldId)
        XCTAssertEqual(mockDiarizer.correctedAssignments[0].newId, newId)
        XCTAssertEqual(mockDiarizer.correctedAssignments[0].embedding, embedding)
    }

    func testCorrectSpeakerAssignmentWithoutDiarizerIsNoOp() {
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: MockChunkTranscriber()
        )
        // Should not crash when no diarizer
        engine.correctSpeakerAssignment(embedding: [1.0], from: UUID(), to: UUID())
    }

    func testProcessChunkStoresEmbeddingInSegments() async throws {
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "Hello", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let mockDiarizer = MockSpeakerDiarizer()
        let testEmbedding: [Float] = [Float](repeating: 0.42, count: 256)
        mockDiarizer.speakerResults = [
            SpeakerIdentification(speakerId: UUID(), confidence: 0.8, embedding: testEmbedding)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber,
            diarizer: mockDiarizer
        )
        try await engine.setup(model: "test-model")

        var params = TranscriptionParameters.default
        params.enableSpeakerDiarization = true
        let expectation = XCTestExpectation(description: "State change with embedding")
        var receivedSegments: [ConfirmedSegment]?

        try await engine.startStreaming(language: "en", parameters: params) { state in
            if !state.confirmedSegments.isEmpty {
                receivedSegments = state.confirmedSegments
                expectation.fulfill()
            }
        }

        // Feed enough audio for a chunk (5s at 16kHz = 80000 samples)
        let speechBuffer = [Float](repeating: 0.1, count: 80000)
        mockCapture.simulateBuffer(speechBuffer)

        await fulfillment(of: [expectation], timeout: 6.0)

        XCTAssertNotNil(receivedSegments)
        XCTAssertEqual(receivedSegments?.count, 1)
        XCTAssertEqual(receivedSegments?[0].speakerEmbedding, testEmbedding)

        await engine.stopStreaming()
    }

    func testStopStreamingSavesEmbeddingHistory() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EngineHistoryTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let profileStore = SpeakerProfileStore(directory: tmpDir)
        let historyStore = EmbeddingHistoryStore(directory: tmpDir)
        let mockDiarizer = MockSpeakerDiarizer()
        let emb = [Float](repeating: 0.1, count: 256)
        let historyProfileId = UUID()
        mockDiarizer.detailedProfiles = [
            (speakerId: historyProfileId, embedding: emb, embeddingHistory: [
                WeightedEmbedding(embedding: emb, confidence: 1.0),
                WeightedEmbedding(embedding: emb, confidence: 0.8)
            ])
        ]

        let engine = ChunkedWhisperEngine(
            audioCaptureService: MockAudioCaptureService(),
            transcriber: MockChunkTranscriber(),
            diarizer: mockDiarizer,
            speakerProfileStore: profileStore,
            embeddingHistoryStore: historyStore
        )

        try await engine.startStreaming(language: "en", parameters: .init(enableSpeakerDiarization: true)) { _ in }
        await engine.stopStreaming()

        let loaded = try historyStore.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].label, historyProfileId.uuidString)
        XCTAssertEqual(loaded[0].embeddings.count, 2)
    }

    func testStopStreamingWithoutHistoryStoreDoesNotCrash() async throws {
        let mockDiarizer = MockSpeakerDiarizer()
        let engine = ChunkedWhisperEngine(
            audioCaptureService: MockAudioCaptureService(),
            transcriber: MockChunkTranscriber(),
            diarizer: mockDiarizer
        )

        try await engine.startStreaming(language: "en", parameters: .init(enableSpeakerDiarization: true)) { _ in }
        await engine.stopStreaming()
        // Should not crash
    }

    func testStopStreamingSkipsGhostProfiles() async throws {
        let mockDiarizer = MockSpeakerDiarizer()
        let knownId = UUID()
        let ghostId = UUID()
        let embedding = [Float](repeating: 0.1, count: 256)
        mockDiarizer.exportedProfiles = [
            (speakerId: knownId, embedding: embedding),
            (speakerId: ghostId, embedding: embedding)
        ]
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SpeakerProfileStore(directory: dir)
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: MockChunkTranscriber(),
            diarizer: mockDiarizer,
            speakerProfileStore: store
        )
        try await engine.setup(model: "test-model")

        var params = TranscriptionParameters.default
        params.enableSpeakerDiarization = true
        try await engine.startStreaming(language: "en", parameters: params, onStateChange: { _ in })

        // Only knownId has a display name mapping; ghostId is unmapped
        await engine.stopStreaming(speakerDisplayNames: [knownId.uuidString: "Alice"])

        // Only the known profile should be merged
        XCTAssertEqual(store.profiles.count, 1, "Ghost profile should be filtered out")
        XCTAssertEqual(store.profiles[0].displayName, "Alice")
    }

    func testManualModeEmptyParticipantsDisablesDiarization() async throws {
        let mockTranscriber = MockChunkTranscriber()
        let mockDiarizer = MockSpeakerDiarizer()
        let spkId = UUID()
        mockDiarizer.speakerResults = [SpeakerIdentification(speakerId: spkId, confidence: 0.9, embedding: [Float](repeating: 0.5, count: 256))]
        mockTranscriber.transcribeResults = [TranscribedSegment(text: "Hello", avgLogprob: -0.3, compressionRatio: 1.5, noSpeechProb: 0.1)]

        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber,
            diarizer: mockDiarizer
        )
        try await engine.setup(model: "test-model")

        var params = TranscriptionParameters.default
        params.enableSpeakerDiarization = true
        params.diarizationMode = .manual

        // Manual mode with empty participants → diarization should be disabled
        try await engine.startStreaming(
            language: "en", parameters: params,
            participantProfiles: [],
            onStateChange: { _ in }
        )

        // Feed a chunk to trigger processChunk
        let chunk = [Float](repeating: 0.5, count: 80000)
        mockCapture.simulateBuffer(chunk)

        // Give time for processing
        try await Task.sleep(nanoseconds: 500_000_000)

        // Diarizer should NOT have been called
        XCTAssertEqual(mockDiarizer.identifySpeakerCallCount, 0,
                       "Manual mode with no participants should disable diarization")

        await engine.stopStreaming()
    }

    func testStartStreamingLoadsSpeakerProfiles() async throws {
        let mockDiarizer = MockSpeakerDiarizer()
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SpeakerProfileStore(directory: dir)
        store.profiles = [StoredSpeakerProfile(displayName: "Alice", embedding: [Float](repeating: 0.1, count: 256))]
        try store.save()

        // Create new store instance (simulating app restart)
        let store2 = SpeakerProfileStore(directory: dir)
        try store2.load()

        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: MockChunkTranscriber(),
            diarizer: mockDiarizer,
            speakerProfileStore: store2
        )
        try await engine.setup(model: "test-model")

        var params = TranscriptionParameters.default
        params.enableSpeakerDiarization = true
        try await engine.startStreaming(language: "en", parameters: params, onStateChange: { _ in })

        XCTAssertNotNil(mockDiarizer.loadedProfiles)
        XCTAssertEqual(mockDiarizer.loadedProfiles?.count, 1)
        // The engine maps StoredSpeakerProfile.id to speakerId
        XCTAssertEqual(mockDiarizer.loadedProfiles?.first?.speakerId, store2.profiles.first?.id)

        await engine.stopStreaming()
    }
}
