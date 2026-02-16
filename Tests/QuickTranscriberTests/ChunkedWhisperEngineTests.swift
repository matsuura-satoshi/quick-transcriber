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
}
