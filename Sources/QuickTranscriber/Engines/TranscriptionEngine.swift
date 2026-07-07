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
    public var unconfirmedText: String
    public var isRecording: Bool
    public var confirmedSegments: [ConfirmedSegment]

    public init(unconfirmedText: String, isRecording: Bool, confirmedSegments: [ConfirmedSegment] = []) {
        self.unconfirmedText = unconfirmedText
        self.isRecording = isRecording
        self.confirmedSegments = confirmedSegments
    }
}

public protocol TranscriptionEngine: AnyObject, Sendable {
    func setup(model: String) async throws
    func startStreaming(language: String, parameters: TranscriptionParameters, participantProfiles: [(speakerId: UUID, embedding: [Float])]?, audioRecordingDirectory: URL?, audioRecordingDatePrefix: String?, onStateChange: @escaping @Sendable (TranscriptionState) -> Void) async throws
    func stopStreaming(speakerDisplayNames: [String: String]) async
    var isStreaming: Bool { get async }
    func correctSpeakerAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) async
    func mergeSpeakerProfiles(from sourceId: UUID, into targetId: UUID) async
    func syncViterbiConfirm(to newId: UUID) async
}

extension TranscriptionEngine {
    public func startStreaming(language: String, parameters: TranscriptionParameters, participantProfiles: [(speakerId: UUID, embedding: [Float])]? = nil, onStateChange: @escaping @Sendable (TranscriptionState) -> Void) async throws {
        try await startStreaming(language: language, parameters: parameters, participantProfiles: participantProfiles, audioRecordingDirectory: nil, audioRecordingDatePrefix: nil, onStateChange: onStateChange)
    }

    public func startStreaming(language: String, onStateChange: @escaping @Sendable (TranscriptionState) -> Void) async throws {
        try await startStreaming(language: language, parameters: .default, participantProfiles: nil, audioRecordingDirectory: nil, audioRecordingDatePrefix: nil, onStateChange: onStateChange)
    }

    public func stopStreaming() async {
        await stopStreaming(speakerDisplayNames: [:])
    }
}
