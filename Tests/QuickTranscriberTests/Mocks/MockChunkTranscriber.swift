import Foundation
@testable import QuickTranscriberLib

final class MockChunkTranscriber: ChunkTranscriber {
    var setupCalled = false
    var setupError: Error?
    var transcribeResults: [String] = ["mock transcription"]
    var transcribeError: Error?
    var transcribeCallCount = 0
    var lastAudioArray: [Float]?
    var lastLanguage: String?

    func setup(model: String) async throws {
        setupCalled = true
        if let error = setupError { throw error }
    }

    func transcribe(audioArray: [Float], language: String, parameters: TranscriptionParameters) async throws -> [String] {
        transcribeCallCount += 1
        lastAudioArray = audioArray
        lastLanguage = language
        if let error = transcribeError { throw error }
        return transcribeResults
    }
}
