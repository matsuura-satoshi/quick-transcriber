import Foundation

public enum TranscriptionServiceError: LocalizedError {
    case engineNotReady
    case alreadyStreaming

    public var errorDescription: String? {
        switch self {
        case .engineNotReady:
            return "Transcription engine is not ready."
        case .alreadyStreaming:
            return "Already streaming. Stop first before starting again."
        }
    }
}

public final class TranscriptionService {
    private let engine: TranscriptionEngine
    public private(set) var isReady = false

    public init(engine: TranscriptionEngine) {
        self.engine = engine
    }

    public func prepare(model: String) async throws {
        try await engine.setup(model: model)
        isReady = true
    }

    public func startTranscription(
        language: String,
        parameters: TranscriptionParameters = .default,
        participantProfiles: [(speakerId: UUID, embedding: [Float])]? = nil,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        guard isReady else {
            throw TranscriptionServiceError.engineNotReady
        }
        guard await !engine.isStreaming else {
            throw TranscriptionServiceError.alreadyStreaming
        }
        try await engine.startStreaming(language: language, parameters: parameters, participantProfiles: participantProfiles, onStateChange: onStateChange)
    }

    public func stopTranscription(speakerDisplayNames: [String: String] = [:]) async {
        await engine.stopStreaming(speakerDisplayNames: speakerDisplayNames)
    }

    public func correctSpeakerAssignment(embedding: [Float], from oldSpeaker: String, to newSpeaker: String) {
        guard let oldId = UUID(uuidString: oldSpeaker), let newId = UUID(uuidString: newSpeaker) else { return }
        engine.correctSpeakerAssignment(embedding: embedding, from: oldId, to: newId)
    }

    public func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) {
        engine.mergeSpeakerProfiles(from: sourceId, into: targetId)
    }

    public func cleanup() {
        engine.cleanup()
        isReady = false
    }
}
