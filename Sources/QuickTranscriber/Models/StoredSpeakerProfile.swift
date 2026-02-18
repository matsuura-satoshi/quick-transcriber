import Foundation

public struct StoredSpeakerProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public var embedding: [Float]
    public var lastUsed: Date
    public var sessionCount: Int
    public var displayName: String?

    public init(id: UUID = UUID(), label: String, embedding: [Float], lastUsed: Date = Date(), sessionCount: Int = 1, displayName: String? = nil) {
        self.id = id
        self.label = label
        self.embedding = embedding
        self.lastUsed = lastUsed
        self.sessionCount = sessionCount
        self.displayName = displayName
    }
}
