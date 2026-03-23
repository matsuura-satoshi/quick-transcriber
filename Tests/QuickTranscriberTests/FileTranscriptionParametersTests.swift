import XCTest
@testable import QuickTranscriberLib

final class FileTranscriptionParametersTests: XCTestCase {

    // MARK: - TranscriptionParameters defaults

    func testDefaultQualityThresholdsAreNil() {
        let params = TranscriptionParameters.default
        XCTAssertNil(params.compressionRatioThreshold)
        XCTAssertNil(params.logProbThreshold)
        XCTAssertNil(params.firstTokenLogProbThreshold)
        XCTAssertNil(params.noSpeechThreshold)
    }

    func testDefaultSuppressBlankIsFalse() {
        let params = TranscriptionParameters.default
        XCTAssertFalse(params.suppressBlank)
    }

    func testDefaultQualityThresholdMinChunkDuration() {
        let params = TranscriptionParameters.default
        XCTAssertEqual(params.qualityThresholdMinChunkDuration, Constants.FileTranscription.qualityThresholdMinChunkDuration)
    }

    // MARK: - Backward compatibility (old JSON without new fields)

    func testDecodingOldJSONWithoutQualityFields() throws {
        let oldJSON = """
        {"temperature":0,"temperatureFallbackCount":0,"sampleLength":224,"concurrentWorkerCount":4,"chunkDuration":8,"silenceCutoffDuration":0.6,"silenceEnergyThreshold":0.01}
        """
        let data = oldJSON.data(using: .utf8)!
        let params = try JSONDecoder().decode(TranscriptionParameters.self, from: data)
        XCTAssertNil(params.compressionRatioThreshold)
        XCTAssertNil(params.logProbThreshold)
        XCTAssertNil(params.firstTokenLogProbThreshold)
        XCTAssertNil(params.noSpeechThreshold)
        XCTAssertFalse(params.suppressBlank)
        XCTAssertEqual(params.qualityThresholdMinChunkDuration, Constants.FileTranscription.qualityThresholdMinChunkDuration)
    }

    // MARK: - Encoding round-trip with quality fields set

    func testCodableRoundTripWithQualityThresholds() throws {
        var params = TranscriptionParameters.default
        params.compressionRatioThreshold = 2.4
        params.logProbThreshold = -1.0
        params.firstTokenLogProbThreshold = -1.5
        params.noSpeechThreshold = 0.6
        params.suppressBlank = true
        params.qualityThresholdMinChunkDuration = 15.0

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(TranscriptionParameters.self, from: data)

        XCTAssertEqual(decoded.compressionRatioThreshold, 2.4)
        XCTAssertEqual(decoded.logProbThreshold, -1.0)
        XCTAssertEqual(decoded.firstTokenLogProbThreshold, -1.5)
        XCTAssertEqual(decoded.noSpeechThreshold, 0.6)
        XCTAssertTrue(decoded.suppressBlank)
        XCTAssertEqual(decoded.qualityThresholdMinChunkDuration, 15.0)
    }

    // MARK: - File-mode parameters construction

    func testFileOptimizedParametersOverrides() {
        var params = TranscriptionParameters.default

        // Apply file-optimized overrides (same logic as beginFileTranscription)
        params.chunkDuration = Constants.FileTranscription.chunkDuration
        params.silenceCutoffDuration = Constants.FileTranscription.endOfUtteranceSilence
        params.temperatureFallbackCount = Constants.FileTranscription.temperatureFallbackCount
        params.concurrentWorkerCount = 1

        XCTAssertEqual(params.chunkDuration, 25.0)
        XCTAssertEqual(params.silenceCutoffDuration, 1.0)
        XCTAssertEqual(params.temperatureFallbackCount, 2)
        XCTAssertEqual(params.concurrentWorkerCount, 1)
        // Quality thresholds remain nil (not used for file mode per benchmark results)
        XCTAssertNil(params.compressionRatioThreshold)
        XCTAssertNil(params.logProbThreshold)
        XCTAssertFalse(params.suppressBlank)
    }

    // MARK: - Parameter propagation through engine

    func testFileParametersFlowToTranscriber() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )

        var params = TranscriptionParameters.default
        params.chunkDuration = 25.0
        params.silenceCutoffDuration = 1.0
        params.temperatureFallbackCount = 2
        params.concurrentWorkerCount = 1

        try await engine.startStreaming(
            language: "en",
            parameters: params
        ) { _ in }

        // Feed speech + silence to trigger VAD chunk emission
        let speechSamples = [Float](repeating: 0.1, count: Int(1.0 * 16000))
        let silenceSamples = [Float](repeating: 0.0, count: Int(1.1 * 16000))
        mockCapture.simulateBuffer(speechSamples)
        mockCapture.simulateBuffer(silenceSamples)

        // Wait for processing
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(mockTranscriber.transcribeCallCount, 1)
        let capturedParams = mockTranscriber.lastParameters
        XCTAssertNotNil(capturedParams)
        XCTAssertEqual(capturedParams?.chunkDuration, 25.0)
        XCTAssertEqual(capturedParams?.silenceCutoffDuration, 1.0)
        XCTAssertEqual(capturedParams?.temperatureFallbackCount, 2)
        XCTAssertEqual(capturedParams?.concurrentWorkerCount, 1)
        // Quality thresholds should remain nil (data-driven decision from benchmarks)
        XCTAssertNil(capturedParams?.compressionRatioThreshold)

        await engine.stopStreaming(speakerDisplayNames: [:])
    }

    // MARK: - Constants

    func testFileTranscriptionConstants() {
        XCTAssertEqual(Constants.FileTranscription.chunkDuration, 25.0)
        XCTAssertEqual(Constants.FileTranscription.endOfUtteranceSilence, 1.0)
        XCTAssertEqual(Constants.FileTranscription.temperatureFallbackCount, 2)
        XCTAssertEqual(Constants.FileTranscription.qualityThresholdMinChunkDuration, 15.0)
    }
}
