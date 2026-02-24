import Foundation
@testable import QuickTranscriberLib

final class MockSpeakerDiarizer: SpeakerDiarizer, @unchecked Sendable {
    var setupCalled = false
    var setupError: Error?
    var speakerResults: [SpeakerIdentification?] = []
    var identifySpeakerCallCount = 0
    var forceRunValues: [Bool] = []
    private var callIndex = 0

    func setup() async throws {
        setupCalled = true
        if let error = setupError { throw error }
    }

    func identifySpeaker(audioChunk: [Float], forceRun: Bool) async -> SpeakerIdentification? {
        identifySpeakerCallCount += 1
        forceRunValues.append(forceRun)
        guard callIndex < speakerResults.count else { return nil }
        let result = speakerResults[callIndex]
        callIndex += 1
        return result
    }

    func updateExpectedSpeakerCount(_ count: Int?) {}

    var exportedProfiles: [(speakerId: UUID, embedding: [Float])] = []
    var loadedProfiles: [(speakerId: UUID, embedding: [Float])]?
    var detailedProfiles: [(speakerId: UUID, embedding: [Float], embeddingHistory: [WeightedEmbedding])] = []

    func exportSpeakerProfiles() -> [(speakerId: UUID, embedding: [Float])] {
        exportedProfiles
    }

    func exportDetailedSpeakerProfiles() -> [(speakerId: UUID, embedding: [Float], embeddingHistory: [WeightedEmbedding])] {
        detailedProfiles
    }

    func loadSpeakerProfiles(_ profiles: [(speakerId: UUID, embedding: [Float])]) {
        loadedProfiles = profiles
    }

    var correctedAssignments: [(embedding: [Float], oldId: UUID, newId: UUID)] = []

    func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) {
        correctedAssignments.append((embedding: embedding, oldId: oldId, newId: newId))
    }
}
