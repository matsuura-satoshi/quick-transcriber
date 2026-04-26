import Foundation

public struct LoadedSpeakerProfile: Sendable {
    public let id: UUID
    public let displayName: String
    public let embedding: [Float]
    public let sessionCount: Int
    public let isLocked: Bool

    public init(id: UUID, displayName: String, embedding: [Float], sessionCount: Int, isLocked: Bool) {
        self.id = id
        self.displayName = displayName
        self.embedding = embedding
        self.sessionCount = sessionCount
        self.isLocked = isLocked
    }
}

/// Loads speaker profiles from disk, filtered by displayName whitelist.
/// Strict read-only contract: this loader never writes back to the source path.
public enum SpeakerProfileLoader {
    public enum LoadError: Error, Equatable {
        case missingProfiles([String])
    }

    private struct DiskProfile: Decodable {
        let id: UUID
        let displayName: String
        let embedding: [Float]
        let sessionCount: Int?
        let isLocked: Bool?
    }

    public static func load(path: String, displayNames: [String]) throws -> [LoadedSpeakerProfile] {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url, options: [.uncached])
        let disk = try JSONDecoder().decode([DiskProfile].self, from: data)

        let whitelist = Set(displayNames)
        let matched = disk.filter { whitelist.contains($0.displayName) }
        let foundNames = Set(matched.map(\.displayName))
        let missing = displayNames.filter { !foundNames.contains($0) }
        if !missing.isEmpty {
            throw LoadError.missingProfiles(missing)
        }
        return matched.map {
            LoadedSpeakerProfile(
                id: $0.id,
                displayName: $0.displayName,
                embedding: $0.embedding,
                sessionCount: $0.sessionCount ?? 0,
                isLocked: $0.isLocked ?? false
            )
        }
    }
}
