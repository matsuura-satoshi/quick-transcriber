import Foundation
@testable import QuickTranscriberLib

final class MockChunkTranscriber: ChunkTranscriber {
    var setupCalled = false
    var setupError: Error?
    var transcribeResults: [TranscribedSegment] = [
        TranscribedSegment(text: "mock transcription", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
    ]
    var transcribeError: Error?
    var transcribeCallCount = 0
    var lastAudioArray: [Float]?
    var lastLanguage: String?
    var lastParameters: TranscriptionParameters?
    var lastUtteranceId: String?

    func setup(model: String) async throws {
        setupCalled = true
        if let error = setupError { throw error }
    }

    func transcribe(audioArray: [Float], language: String, parameters: TranscriptionParameters, utteranceId: String) async throws -> [TranscribedSegment] {
        transcribeCallCount += 1
        lastAudioArray = audioArray
        lastLanguage = language
        lastParameters = parameters
        lastUtteranceId = utteranceId
        // Mirror WhisperKitChunkTranscriber's instrumentation so integration tests can
        // exercise the full stage coverage via the mock pipeline.
        LatencyInstrumentation.mark(.inferenceStart, utteranceId: utteranceId)
        defer { LatencyInstrumentation.mark(.inferenceEnd, utteranceId: utteranceId) }
        if let error = transcribeError { throw error }
        return transcribeResults
    }
}
