import Foundation

public struct StoredSpeakerProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var embedding: [Float]
    public var lastUsed: Date
    public var sessionCount: Int
    public var tags: [String]
    public var isLocked: Bool

    public init(id: UUID = UUID(), displayName: String, embedding: [Float], lastUsed: Date = Date(), sessionCount: Int = 1, tags: [String] = [], isLocked: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.embedding = embedding
        self.lastUsed = lastUsed
        self.sessionCount = sessionCount
        self.tags = tags
        self.isLocked = isLocked
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, embedding, lastUsed, sessionCount, tags, isLocked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        embedding = try container.decode([Float].self, forKey: .embedding)
        lastUsed = try container.decode(Date.self, forKey: .lastUsed)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        tags = try container.decode([String].self, forKey: .tags)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }
}

public extension Array where Element == StoredSpeakerProfile {
    /// displayName / タグの部分一致検索。空文字はそのまま返す。
    func matching(_ search: String) -> [StoredSpeakerProfile] {
        guard !search.isEmpty else { return self }
        return filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
}
