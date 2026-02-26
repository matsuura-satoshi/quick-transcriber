import Foundation

public struct TranscriptionSegmentData: Sendable {
    public let text: String
    public let start: Float
    public let end: Float
    public let isConfirmed: Bool

    public init(text: String, start: Float, end: Float, isConfirmed: Bool) {
        self.text = text
        self.start = start
        self.end = end
        self.isConfirmed = isConfirmed
    }
}

public struct TranscriptionState: Sendable {
    public var confirmedText: String
    public var unconfirmedText: String
    public var isRecording: Bool
    public var confirmedSegments: [ConfirmedSegment]

    public init(confirmedText: String, unconfirmedText: String, isRecording: Bool, confirmedSegments: [ConfirmedSegment] = []) {
        self.confirmedText = confirmedText
        self.unconfirmedText = unconfirmedText
        self.isRecording = isRecording
        self.confirmedSegments = confirmedSegments
    }
}

public protocol TranscriptionEngine: AnyObject {
    func setup(model: String) async throws
    func startStreaming(language: String, parameters: TranscriptionParameters, participantProfiles: [(speakerId: UUID, embedding: [Float])]?, onStateChange: @escaping @Sendable (TranscriptionState) -> Void) async throws
    func stopStreaming(speakerDisplayNames: [String: String]) async
    func cleanup()
    var isStreaming: Bool { get async }
    func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID)
    func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID)
}

extension TranscriptionEngine {
    public func startStreaming(language: String, parameters: TranscriptionParameters, onStateChange: @escaping @Sendable (TranscriptionState) -> Void) async throws {
        try await startStreaming(language: language, parameters: parameters, participantProfiles: nil, onStateChange: onStateChange)
    }

    public func startStreaming(language: String, onStateChange: @escaping @Sendable (TranscriptionState) -> Void) async throws {
        try await startStreaming(language: language, parameters: .default, participantProfiles: nil, onStateChange: onStateChange)
    }

    public func stopStreaming() async {
        await stopStreaming(speakerDisplayNames: [:])
    }

    public func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) {
        // Default no-op for engines without diarization
    }

    public func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) {
        // Default no-op for engines without diarization
    }
}
