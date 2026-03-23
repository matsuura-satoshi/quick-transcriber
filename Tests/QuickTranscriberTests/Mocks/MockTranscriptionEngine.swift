import Foundation
@testable import QuickTranscriberLib

final class MockTranscriptionEngine: TranscriptionEngine {
    var setupCalled = false
    var setupModel: String?
    var setupError: Error?

    var startStreamingCalled = false
    var startStreamingCallCount: Int = 0
    var startStreamingLanguage: String?
    var startStreamingParameters: TranscriptionParameters?
    var startStreamingParticipantProfiles: [(speakerId: UUID, embedding: [Float])]?
    var startStreamingError: Error?
    private var stateChangeCallback: (@Sendable (TranscriptionState) -> Void)?

    var stopStreamingCalled = false
    var stopStreamingCallCount: Int = 0
    var stopStreamingSpeakerDisplayNames: [String: String]?
    var cleanupCalled = false

    private var _isStreaming = false
    var isStreaming: Bool {
        get async { _isStreaming }
    }

    func setup(model: String) async throws {
        setupCalled = true
        setupModel = model
        if let error = setupError {
            throw error
        }
    }

    func startStreaming(
        language: String,
        parameters: TranscriptionParameters = .default,
        participantProfiles: [(speakerId: UUID, embedding: [Float])]? = nil,
        audioRecordingDirectory: URL? = nil,
        audioRecordingDatePrefix: String? = nil,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        startStreamingCalled = true
        startStreamingCallCount += 1
        startStreamingLanguage = language
        startStreamingParameters = parameters
        startStreamingParticipantProfiles = participantProfiles
        stateChangeCallback = onStateChange
        if let error = startStreamingError {
            throw error
        }
        _isStreaming = true
    }

    func stopStreaming(speakerDisplayNames: [String: String]) async {
        stopStreamingCalled = true
        stopStreamingCallCount += 1
        stopStreamingSpeakerDisplayNames = speakerDisplayNames
        _isStreaming = false
        stateChangeCallback = nil
    }

    func cleanup() {
        cleanupCalled = true
        _isStreaming = false
        stateChangeCallback = nil
    }

    var correctedAssignments: [(embedding: [Float], oldId: UUID, newId: UUID)] = []
    var mergedProfiles: [(sourceId: UUID, targetId: UUID)] = []

    func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) {
        correctedAssignments.append((embedding: embedding, oldId: oldId, newId: newId))
    }

    func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) {
        mergedProfiles.append((sourceId: sourceId, targetId: targetId))
    }

    // Helper to simulate state changes from the engine
    func simulateStateChange(_ state: TranscriptionState) {
        stateChangeCallback?(state)
    }
}

enum MockError: LocalizedError {
    case setupFailed
    case streamingFailed

    var errorDescription: String? {
        switch self {
        case .setupFailed: return "Mock setup failed"
        case .streamingFailed: return "Mock streaming failed"
        }
    }
}
