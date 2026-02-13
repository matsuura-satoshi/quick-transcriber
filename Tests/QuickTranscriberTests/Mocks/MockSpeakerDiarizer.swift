import Foundation
@testable import QuickTranscriberLib

final class MockSpeakerDiarizer: SpeakerDiarizer, @unchecked Sendable {
    var setupCalled = false
    var setupError: Error?
    var speakerResults: [String?] = []
    private var callIndex = 0

    func setup() async throws {
        setupCalled = true
        if let error = setupError { throw error }
    }

    func identifySpeaker(audioChunk: [Float]) async -> String? {
        guard callIndex < speakerResults.count else { return nil }
        let result = speakerResults[callIndex]
        callIndex += 1
        return result
    }
}
