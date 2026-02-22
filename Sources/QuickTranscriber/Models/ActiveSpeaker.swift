import Foundation

public struct ActiveSpeaker: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var speakerProfileId: UUID?
    public var displayName: String?
    public let source: Source

    public enum Source: String, Equatable, Sendable {
        case manual
        case autoDetected
    }

    public init(
        id: UUID = UUID(),
        speakerProfileId: UUID? = nil,
        displayName: String? = nil,
        source: Source
    ) {
        self.id = id
        self.speakerProfileId = speakerProfileId
        self.displayName = displayName
        self.source = source
    }
}
