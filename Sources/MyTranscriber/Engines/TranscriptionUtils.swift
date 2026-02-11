import Foundation

public enum TranscriptionUtils {
    public static func cleanSegmentText(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "\u{FFFD}", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TranscriptionEngineError: LocalizedError {
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
