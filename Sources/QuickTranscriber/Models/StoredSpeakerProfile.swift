import Foundation

public struct StoredSpeakerProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var embedding: [Float]
    public var lastUsed: Date
    public var sessionCount: Int
    public var tags: [String]

    public init(id: UUID = UUID(), displayName: String, embedding: [Float], lastUsed: Date = Date(), sessionCount: Int = 1, tags: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.embedding = embedding
        self.lastUsed = lastUsed
        self.sessionCount = sessionCount
        self.tags = tags
    }
}
