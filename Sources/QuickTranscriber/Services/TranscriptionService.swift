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
        audioRecordingDirectory: URL? = nil,
        audioRecordingDatePrefix: String? = nil,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        guard isReady else {
            throw TranscriptionServiceError.engineNotReady
        }
        guard await !engine.isStreaming else {
            throw TranscriptionServiceError.alreadyStreaming
        }
        try await engine.startStreaming(language: language, parameters: parameters, participantProfiles: participantProfiles, audioRecordingDirectory: audioRecordingDirectory, audioRecordingDatePrefix: audioRecordingDatePrefix, onStateChange: onStateChange)
    }

    public func stopTranscription(speakerDisplayNames: [String: String] = [:]) async {
        // 発行済みの speaker 系操作が engine に届いてから stop する
        // （同期呼び出し時代の「補正が stop より先に届く」順序を保存）
        await engineSyncTask?.value
        await engine.stopStreaming(speakerDisplayNames: speakerDisplayNames)
    }

    /// Speaker 系操作は engine（actor）へ直列チェーンで転送する。
    /// 呼び出し側（@MainActor の coordinator）は同期のまま、発行順序（FIFO）を保証する。
    /// テストは engineSyncTask を await して転送完了に同期する。
    private(set) var engineSyncTask: Task<Void, Never>?

    private func enqueueEngineSync(_ operation: @escaping @Sendable () async -> Void) {
        let previous = engineSyncTask
        engineSyncTask = Task {
            await previous?.value
            await operation()
        }
    }

    public func correctSpeakerAssignment(embedding: [Float], from oldSpeaker: String, to newSpeaker: String) {
        guard let oldId = UUID(uuidString: oldSpeaker), let newId = UUID(uuidString: newSpeaker) else { return }
        enqueueEngineSync { [engine] in
            await engine.correctSpeakerAssignment(embedding: embedding, from: oldId, to: newId)
        }
    }

    public func syncViterbiConfirm(to newSpeaker: String) {
        guard let newId = UUID(uuidString: newSpeaker) else { return }
        enqueueEngineSync { [engine] in
            await engine.syncViterbiConfirm(to: newId)
        }
    }

    public func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) {
        enqueueEngineSync { [engine] in
            await engine.mergeSpeakerProfiles(from: sourceId, into: targetId)
        }
    }
}
