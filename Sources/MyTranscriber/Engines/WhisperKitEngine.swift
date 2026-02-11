import Foundation
import WhisperKit

public final class WhisperKitEngine: TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?
    private var _isStreaming = false

    public init() {}

    public var isStreaming: Bool {
        get async { _isStreaming }
    }

    public func setup(model: String) async throws {
        self.whisperKit = try await WhisperKitModelLoader.createWhisperKit(model: model)
    }

    public func startStreaming(
        language: String,
        parameters: TranscriptionParameters = .default,
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
            temperature: parameters.temperature,
            temperatureFallbackCount: parameters.temperatureFallbackCount,
            sampleLength: parameters.sampleLength,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            compressionRatioThreshold: parameters.compressionRatioThreshold,
            logProbThreshold: parameters.logProbThreshold,
            firstTokenLogProbThreshold: parameters.firstTokenLogProbThreshold,
            noSpeechThreshold: parameters.noSpeechThreshold,
            concurrentWorkerCount: parameters.concurrentWorkerCount,
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
            requiredSegmentsForConfirmation: parameters.requiredSegmentsForConfirmation,
            silenceThreshold: parameters.silenceThreshold,
            compressionCheckWindow: parameters.compressionCheckWindow,
            useVAD: parameters.useVAD
        ) { oldState, newState in
            let confirmedText = newState.confirmedSegments
                .map { Self.cleanSegmentText($0.text) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            let unconfirmedText = newState.unconfirmedSegments
                .map { Self.cleanSegmentText($0.text) }
                .filter { !$0.isEmpty }
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

    public func stopStreaming() async {
        await streamTranscriber?.stopStreamTranscription()
        self.streamTranscriber = nil
        self._isStreaming = false
    }

    public func cleanup() {
        Task { [weak self] in
            await self?.stopStreaming()
            self?.whisperKit = nil
        }
    }
}

extension WhisperKitEngine {
    public static func cleanSegmentText(_ text: String) -> String {
        var cleaned = text
        // Remove any remaining special tokens like <|...|>
        cleaned = cleaned.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
        // Remove Unicode replacement characters
        cleaned = cleaned.replacingOccurrences(of: "\u{FFFD}", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum WhisperKitEngineError: LocalizedError {
    case notInitialized
    case tokenizerNotAvailable

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit is not initialized. Call setup() first."
        case .tokenizerNotAvailable:
            return "Tokenizer is not available. Model may not be loaded correctly."
        }
    }
}
