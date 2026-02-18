import Foundation

public enum SpeakerProfileStoreError: Error {
    case profileNotFound
}

public final class SpeakerProfileStore {
    private let fileURL: URL
    public var profiles: [StoredSpeakerProfile] = []

    private let mergeThreshold: Float = 0.5
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
        profiles[index].displayName = name.isEmpty ? nil : name
        try save()
    }

    public func delete(id: UUID) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw SpeakerProfileStoreError.profileNotFound
        }
        profiles.remove(at: index)
        try save()
    }

    public func displayName(for label: String) -> String {
        if let profile = profiles.first(where: { $0.label == label }),
           let name = profile.displayName, !name.isEmpty {
            return name
        }
        return label
    }

    public var labelDisplayNames: [String: String] {
        var result: [String: String] = [:]
        for profile in profiles {
            result[profile.label] = profile.displayName ?? profile.label
        }
        return result
    }

    private func nextAvailableLabel() -> String {
        let usedLabels = Set(profiles.map { $0.label })
        for i in 0..<26 {
            let label = String(UnicodeScalar(UInt8(65 + i)))
            if !usedLabels.contains(label) { return label }
        }
        for i in 0..<26 {
            for j in 0..<26 {
                let label = String(UnicodeScalar(UInt8(65 + i))) + String(UnicodeScalar(UInt8(65 + j)))
                if !usedLabels.contains(label) { return label }
            }
        }
        return "Z\(profiles.count)"
    }

    public func mergeSessionProfiles(_ sessionProfiles: [(label: String, embedding: [Float])]) {
        for (label, embedding) in sessionProfiles {
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
                let uniqueLabel = profiles.contains(where: { $0.label == label })
                    ? nextAvailableLabel()
                    : label
                profiles.append(StoredSpeakerProfile(label: uniqueLabel, embedding: embedding))
            }
        }
    }
}
