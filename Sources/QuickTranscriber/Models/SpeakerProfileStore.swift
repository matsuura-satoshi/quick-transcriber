import Foundation

public enum SpeakerProfileStoreError: Error {
    case profileNotFound
}

public final class SpeakerProfileStore {
    private let fileURL: URL
    public var profiles: [StoredSpeakerProfile] = []

    private let mergeThreshold: Float = Constants.Embedding.similarityThreshold
    private let updateAlpha: Float = 0.3

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("QuickTranscriber")
        self.fileURL = dir.appendingPathComponent("speakers.json")
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            profiles = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        profiles = try JSONDecoder().decode([StoredSpeakerProfile].self, from: data)
    }

    public func save() throws {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: fileURL, options: .atomic)
    }

    public func deleteAll() {
        profiles = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func rename(id: UUID, to name: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw SpeakerProfileStoreError.profileNotFound
        }
        if !name.isEmpty {
            profiles[index].displayName = name
        }
        try save()
    }

    public func delete(id: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw SpeakerProfileStoreError.profileNotFound
        }
        profiles.remove(at: index)
        try save()
    }

    // MARK: - Tags

    public var allTags: [String] {
        Array(Set(profiles.flatMap { $0.tags })).sorted()
    }

    public func addTag(_ tag: String, to profileId: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw SpeakerProfileStoreError.profileNotFound
        }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !profiles[index].tags.contains(trimmed) else { return }
        profiles[index].tags.append(trimmed)
        try save()
    }

    public func removeTag(_ tag: String, from profileId: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw SpeakerProfileStoreError.profileNotFound
        }
        profiles[index].tags.removeAll { $0 == tag }
        try save()
    }

    public func deleteMultiple(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        profiles.removeAll { ids.contains($0.id) }
        try save()
    }

    public func profiles(withTag tag: String) -> [StoredSpeakerProfile] {
        profiles.filter { $0.tags.contains(tag) }
    }

    public func profiles(matching search: String) -> [StoredSpeakerProfile] {
        guard !search.isEmpty else { return profiles }
        return profiles.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
            || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    public func mergeSessionProfiles(_ sessionProfiles: [(speakerId: UUID, embedding: [Float], displayName: String)]) {
        for (_, embedding, displayName) in sessionProfiles {
            var bestIndex = -1
            var bestSimilarity: Float = -1

            for (i, stored) in profiles.enumerated() {
                let sim = EmbeddingBasedSpeakerTracker.cosineSimilarity(embedding, stored.embedding)
                if sim > bestSimilarity {
                    bestSimilarity = sim
                    bestIndex = i
                }
            }

            if bestIndex >= 0 && bestSimilarity >= mergeThreshold {
                let alpha = updateAlpha
                profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
                    (1 - alpha) * old + alpha * new
                }
                profiles[bestIndex].lastUsed = Date()
                profiles[bestIndex].sessionCount += 1
            } else {
                profiles.append(StoredSpeakerProfile(displayName: displayName, embedding: embedding))
            }
        }
    }
}
