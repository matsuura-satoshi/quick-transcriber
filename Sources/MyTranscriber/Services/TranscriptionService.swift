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
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        guard isReady else {
            throw TranscriptionServiceError.engineNotReady
        }
        guard await !engine.isStreaming else {
            throw TranscriptionServiceError.alreadyStreaming
        }
        try await engine.startStreaming(language: language, parameters: parameters, onStateChange: onStateChange)
    }

    public func stopTranscription() async {
        await engine.stopStreaming()
    }

    public func cleanup() {
        engine.cleanup()
        isReady = false
    }
}
