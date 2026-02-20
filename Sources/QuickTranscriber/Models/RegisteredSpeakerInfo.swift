import Foundation

public struct RegisteredSpeakerInfo: Identifiable, Equatable {
    public let profileId: UUID
    public let label: String
    public let displayName: String?
    public let tags: [String]
    public let isAlreadyActive: Bool

    public var id: UUID { profileId }
}
