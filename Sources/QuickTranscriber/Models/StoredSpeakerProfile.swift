import Foundation

public struct StoredSpeakerProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public var embedding: [Float]
    public var lastUsed: Date
    public var sessionCount: Int
    public var displayName: String?
    public var tags: [String]

    public init(id: UUID = UUID(), label: String, embedding: [Float], lastUsed: Date = Date(), sessionCount: Int = 1, displayName: String? = nil, tags: [String] = []) {
        self.id = id
        self.label = label
        self.embedding = embedding
        self.lastUsed = lastUsed
        self.sessionCount = sessionCount
        self.displayName = displayName
        self.tags = tags
    }

    public var displayLabel: String {
        if let name = displayName, !name.isEmpty {
            return name
        }
        return "Speaker \(label)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        embedding = try container.decode([Float].self, forKey: .embedding)
        lastUsed = try container.decode(Date.self, forKey: .lastUsed)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}
