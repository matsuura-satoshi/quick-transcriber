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

    func setup(model: String) async throws {
        setupCalled = true
        if let error = setupError { throw error }
    }

    func transcribe(audioArray: [Float], language: String, parameters: TranscriptionParameters) async throws -> [TranscribedSegment] {
        transcribeCallCount += 1
        lastAudioArray = audioArray
        lastLanguage = language
        lastParameters = parameters
        if let error = transcribeError { throw error }
        return transcribeResults
    }
}
