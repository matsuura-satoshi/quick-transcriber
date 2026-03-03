import Foundation

public enum SpeakerProfileStoreError: Error {
    case profileNotFound
}

public final class SpeakerProfileStore {
    private let fileURL: URL
    public var profiles: [StoredSpeakerProfile] = []

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
        let hadProfiles = !profiles.isEmpty
        profiles.removeAll { !$0.isLocked }
        if profiles.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        } else if hadProfiles {
            try? save()
        }
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

    public func setLocked(id: UUID, locked: Bool) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw SpeakerProfileStoreError.profileNotFound
        }
        profiles[index].isLocked = locked
        try save()
    }

    public func delete(id: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw SpeakerProfileStoreError.profileNotFound
        }
        guard !profiles[index].isLocked else { return }
        profiles.remove(at: index)
        try save()
    }

    public func forceDelete(id: UUID) throws {
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
        profiles.removeAll { ids.contains($0.id) && !$0.isLocked }
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
        for (speakerId, embedding, displayName) in sessionProfiles {
            // Priority 1: ID match
            if let idMatchIndex = profiles.firstIndex(where: { $0.id == speakerId }) {
                let alpha = updateAlpha
                profiles[idMatchIndex].embedding = zip(profiles[idMatchIndex].embedding, embedding).map { old, new in
                    (1 - alpha) * old + alpha * new
                }
                profiles[idMatchIndex].lastUsed = Date()
                profiles[idMatchIndex].sessionCount += 1
            } else {
                let newProfile = StoredSpeakerProfile(id: speakerId, displayName: displayName, embedding: embedding)
                profiles.append(newProfile)
            }
        }
    }
}
