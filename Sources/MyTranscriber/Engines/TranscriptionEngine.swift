import Foundation

struct TranscriptionSegmentData: Sendable {
    let text: String
    let start: Float
    let end: Float
    let isConfirmed: Bool
}

struct TranscriptionState: Sendable {
    var confirmedText: String
    var unconfirmedText: String
    var isRecording: Bool
}

protocol TranscriptionEngine: AnyObject {
    /// Set up the engine with a specific model. Downloads model if needed.
    func setup(model: String) async throws

    /// Start real-time streaming transcription from microphone.
    /// - Parameters:
    ///   - language: Language code (e.g., "en", "ja")
    ///   - onStateChange: Called when transcription state changes
    func startStreaming(language: String, onStateChange: @escaping @Sendable (TranscriptionState) -> Void) async throws

    /// Stop streaming transcription.
    func stopStreaming() async

    /// Clean up resources.
    func cleanup()

    /// Whether the engine is currently streaming.
    var isStreaming: Bool { get async }
}
