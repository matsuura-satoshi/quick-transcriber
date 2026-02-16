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

    func updateExpectedSpeakerCount(_ count: Int?) {}

    var exportedProfiles: [(label: String, embedding: [Float])] = []
    var loadedProfiles: [(label: String, embedding: [Float])]?

    func exportSpeakerProfiles() -> [(label: String, embedding: [Float])] {
        exportedProfiles
    }

    func loadSpeakerProfiles(_ profiles: [(label: String, embedding: [Float])]) {
        loadedProfiles = profiles
    }
}
