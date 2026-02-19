import Foundation
@testable import QuickTranscriberLib

final class MockSpeakerDiarizer: SpeakerDiarizer, @unchecked Sendable {
    var setupCalled = false
    var setupError: Error?
    var speakerResults: [SpeakerIdentification?] = []
    private var callIndex = 0

    func setup() async throws {
        setupCalled = true
        if let error = setupError { throw error }
    }

    func identifySpeaker(audioChunk: [Float]) async -> SpeakerIdentification? {
        guard callIndex < speakerResults.count else { return nil }
        let result = speakerResults[callIndex]
        callIndex += 1
        return result
    }

    func updateExpectedSpeakerCount(_ count: Int?) {}

    var exportedProfiles: [(label: String, embedding: [Float])] = []
    var loadedProfiles: [(label: String, embedding: [Float])]?
    var detailedProfiles: [(label: String, embedding: [Float], embeddingHistory: [[Float]])] = []

    func exportSpeakerProfiles() -> [(label: String, embedding: [Float])] {
        exportedProfiles
    }

    func exportDetailedSpeakerProfiles() -> [(label: String, embedding: [Float], embeddingHistory: [[Float]])] {
        detailedProfiles
    }

    func loadSpeakerProfiles(_ profiles: [(label: String, embedding: [Float])]) {
        loadedProfiles = profiles
    }

    var correctedAssignments: [(embedding: [Float], oldLabel: String, newLabel: String)] = []

    func correctSpeakerAssignment(embedding: [Float], from oldLabel: String, to newLabel: String) {
        correctedAssignments.append((embedding: embedding, oldLabel: oldLabel, newLabel: newLabel))
    }
}
