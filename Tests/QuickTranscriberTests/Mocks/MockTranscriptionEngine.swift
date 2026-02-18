import Foundation
@testable import QuickTranscriberLib

final class MockTranscriptionEngine: TranscriptionEngine {
    var setupCalled = false
    var setupModel: String?
    var setupError: Error?

    var startStreamingCalled = false
    var startStreamingLanguage: String?
    var startStreamingParameters: TranscriptionParameters?
    var startStreamingError: Error?
    private var stateChangeCallback: (@Sendable (TranscriptionState) -> Void)?

    var stopStreamingCalled = false
    var cleanupCalled = false
    var correctSpeakerCalled = false
    var correctSpeakerFrom: String?
    var correctSpeakerTo: String?

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
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        startStreamingCalled = true
        startStreamingLanguage = language
        startStreamingParameters = parameters
        stateChangeCallback = onStateChange
        if let error = startStreamingError {
            throw error
        }
        _isStreaming = true
    }

    func stopStreaming() async {
        stopStreamingCalled = true
        _isStreaming = false
        stateChangeCallback = nil
    }

    func correctSpeaker(from fromLabel: String, to toLabel: String) {
        correctSpeakerCalled = true
        correctSpeakerFrom = fromLabel
        correctSpeakerTo = toLabel
    }

    func cleanup() {
        cleanupCalled = true
        _isStreaming = false
        stateChangeCallback = nil
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
