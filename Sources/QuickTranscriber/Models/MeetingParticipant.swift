import Foundation

public struct MeetingParticipant: Identifiable, Equatable, Sendable {
    public let speakerProfileId: UUID?   // nil = new person (no embedding yet)
    public let assignedLabel: String     // Session label (A, B, C...)
    public var displayName: String       // Display name

    public var id: String { speakerProfileId?.uuidString ?? assignedLabel }

    public init(speakerProfileId: UUID? = nil, assignedLabel: String, displayName: String) {
        self.speakerProfileId = speakerProfileId
        self.assignedLabel = assignedLabel
        self.displayName = displayName
    }
}
