import Foundation

enum TranscriptionServiceError: LocalizedError {
    case engineNotReady
    case alreadyStreaming

    var errorDescription: String? {
        switch self {
        case .engineNotReady:
            return "Transcription engine is not ready."
        case .alreadyStreaming:
            return "Already streaming. Stop first before starting again."
        }
    }
}

final class TranscriptionService {
    private let engine: TranscriptionEngine
    private(set) var isReady = false

    init(engine: TranscriptionEngine) {
        self.engine = engine
    }

    func prepare(model: String) async throws {
        try await engine.setup(model: model)
        isReady = true
    }

    func startTranscription(
        language: String,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        guard isReady else {
            throw TranscriptionServiceError.engineNotReady
        }
        guard await !engine.isStreaming else {
            throw TranscriptionServiceError.alreadyStreaming
        }
        try await engine.startStreaming(language: language, onStateChange: onStateChange)
    }

    func stopTranscription() async {
        await engine.stopStreaming()
    }

    func cleanup() {
        engine.cleanup()
        isReady = false
    }
}
