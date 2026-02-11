import Foundation

public final class WhisperKitEngine: TranscriptionEngine {
    private let provider: WhisperKitProviding
    private var _isStreaming = false

    public init(provider: WhisperKitProviding? = nil) {
        self.provider = provider ?? DefaultWhisperKitProvider()
    }

    public var isStreaming: Bool {
        get async { _isStreaming }
    }

    public func setup(model: String) async throws {
        try await provider.setup(model: model)
    }

    public func startStreaming(
        language: String,
        parameters: TranscriptionParameters = .default,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        _isStreaming = true
        try await provider.startStreamTranscription(
            language: language,
            parameters: parameters
        ) { confirmed, unconfirmed in
            let confirmedText = confirmed
                .map { Self.cleanSegmentText($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let unconfirmedText = unconfirmed
                .map { Self.cleanSegmentText($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            onStateChange(TranscriptionState(
                confirmedText: confirmedText,
                unconfirmedText: unconfirmedText,
                isRecording: true
            ))
        }
    }

    public func stopStreaming() async {
        await provider.stopStreamTranscription()
        _isStreaming = false
    }

    public func cleanup() {
        Task { [weak self] in
            await self?.stopStreaming()
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
