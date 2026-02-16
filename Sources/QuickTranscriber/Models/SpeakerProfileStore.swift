import Foundation

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
                profiles.append(StoredSpeakerProfile(label: label, embedding: embedding))
            }
        }
    }
}
