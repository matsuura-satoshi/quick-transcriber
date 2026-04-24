import XCTest
@testable import QuickTranscriberLib

/// Integration tests that verify LatencyInstrumentation marks are emitted at the
/// right call sites in the production pipeline.
///
/// Approach rationale: `ChunkTranscriber` is a protocol, not a concrete class, and
/// the real `WhisperKitChunkTranscriber` implementation requires loading the
/// WhisperKit model (multi-GB download, slow). We therefore:
///
/// 1. Drive the live `ChunkedWhisperEngine` pipeline end-to-end using the existing
///    `MockChunkTranscriber` / `MockSpeakerDiarizer` / `MockAudioCaptureService`
///    fixtures. Those mocks are extended in this PR to emit the same pair of marks
///    (inferenceStart/End, diarizeStart/End) their real counterparts do, so this
///    test exercises the call-site wrapper in ChunkedWhisperEngine itself
///    (chunkDispatched, emitToUI), while the VAD marks come from the real
///    `VADChunkAccumulator` and the inference/diarize marks come from the mocks'
///    own instrumentation that mirrors the real implementations.
/// 2. A narrower unit test confirms that the real `WhisperKitChunkTranscriber` and
///    `FluidAudioSpeakerDiarizer` bodies also contain the mark() calls — those
///    are exercised by the production pipeline whenever the models are available.
final class LatencyInstrumentationIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LatencyInstrumentation.reset()
        LatencyInstrumentation.isEnabled = true
    }

    override func tearDown() {
        LatencyInstrumentation.isEnabled = false
        LatencyInstrumentation.reset()
        super.tearDown()
    }

    func test_pipelineEmitsAllStageMarksForSingleUtterance() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        let mockDiarizer = MockSpeakerDiarizer()
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber,
            diarizer: mockDiarizer
        )

        try await engine.setup(model: "test-model")

        var parameters = TranscriptionParameters.default
        parameters.enableSpeakerDiarization = true

        let expectation = XCTestExpectation(description: "UI update received")
        try await engine.startStreaming(
            language: "en",
            parameters: parameters,
            onStateChange: { _ in
                expectation.fulfill()
            }
        )

        // Feed enough speech + silence to drive one full utterance through the pipeline.
        // speechOnsetThreshold default crossed by amplitude 0.1.
        let speechSamples = [Float](repeating: 0.1, count: Int(1.0 * 16000))
        let silenceSamples = [Float](repeating: 0.0, count: Int(0.8 * 16000))
        mockCapture.simulateBuffer(speechSamples)
        mockCapture.simulateBuffer(silenceSamples)

        await fulfillment(of: [expectation], timeout: 5.0)
        await engine.stopStreaming()

        let records = LatencyInstrumentation.drain()
        XCTAssertFalse(records.isEmpty, "Expected at least one latency record")

        // Group by utteranceId and verify each utterance has the expected stages in order.
        let byUtterance = Dictionary(grouping: records, by: { $0.utteranceId })
        XCTAssertGreaterThanOrEqual(byUtterance.count, 1, "At least one utterance id should be present")

        // Find the utterance group that contains the full lifecycle.
        let lifecycleGroup = byUtterance.values.first { group in
            let stages = Set(group.map(\.stage))
            return stages.contains(.vadOnset)
                && stages.contains(.chunkDispatched)
                && stages.contains(.inferenceStart)
                && stages.contains(.inferenceEnd)
                && stages.contains(.diarizeStart)
                && stages.contains(.diarizeEnd)
                && stages.contains(.emitToUI)
        }
        XCTAssertNotNil(lifecycleGroup, "Expected at least one utterance with full stage coverage")

        // And verify that utteranceId is a non-empty UUID-like string.
        if let group = lifecycleGroup, let id = group.first?.utteranceId {
            XCTAssertFalse(id.isEmpty)
        }
    }

    func test_marksNotEmittedWhenInstrumentationDisabled() async throws {
        LatencyInstrumentation.isEnabled = false

        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )

        try await engine.setup(model: "test-model")
        let expectation = XCTestExpectation(description: "UI update received")
        try await engine.startStreaming(
            language: "en",
            onStateChange: { _ in
                expectation.fulfill()
            }
        )

        let speechSamples = [Float](repeating: 0.1, count: Int(1.0 * 16000))
        let silenceSamples = [Float](repeating: 0.0, count: Int(0.8 * 16000))
        mockCapture.simulateBuffer(speechSamples)
        mockCapture.simulateBuffer(silenceSamples)

        await fulfillment(of: [expectation], timeout: 5.0)
        await engine.stopStreaming()

        let records = LatencyInstrumentation.drain()
        XCTAssertTrue(records.isEmpty, "No records should be emitted when disabled")
    }
}
