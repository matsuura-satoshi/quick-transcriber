import Foundation
import WhisperKit

final class WhisperKitEngine: TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private var _isStreaming = false

    var isStreaming: Bool {
        get async { _isStreaming }
    }

    func setup(model: String) async throws {
        let whisper = try await WhisperKit(
            model: model,
            verbose: true,
            logLevel: .info,
            download: true
        )
        self.whisperKit = whisper
    }

    func startStreaming(
        language: String,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        guard let whisperKit else {
            throw WhisperKitEngineError.notInitialized
        }

        guard let tokenizer = whisperKit.tokenizer else {
            throw WhisperKitEngineError.tokenizerNotAvailable
        }

        let decodingOptions = DecodingOptions(
            task: .transcribe,
            language: language,
            chunkingStrategy: .vad
        )

        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: decodingOptions,
            requiredSegmentsForConfirmation: 2,
            silenceThreshold: 0.3,
            useVAD: true
        ) { oldState, newState in
            let confirmedText = newState.confirmedSegments
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")

            let unconfirmedText = newState.unconfirmedSegments
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")

            let state = TranscriptionState(
                confirmedText: confirmedText,
                unconfirmedText: unconfirmedText,
                isRecording: newState.isRecording
            )
            onStateChange(state)
        }

        self.streamTranscriber = transcriber
        self._isStreaming = true
        try await transcriber.startStreamTranscription()
    }

    func stopStreaming() async {
        await streamTranscriber?.stopStreamTranscription()
        self.streamTranscriber = nil
        self._isStreaming = false
    }

    func cleanup() {
        Task {
            await stopStreaming()
        }
        whisperKit = nil
    }
}

enum WhisperKitEngineError: LocalizedError {
    case notInitialized
    case tokenizerNotAvailable

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit is not initialized. Call setup() first."
        case .tokenizerNotAvailable:
            return "Tokenizer is not available. Model may not be loaded correctly."
        }
    }
}
