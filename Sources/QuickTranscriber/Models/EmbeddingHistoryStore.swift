import Foundation

public struct HistoricalEmbedding: Codable, Equatable {
    public let embedding: [Float]
    public let confirmed: Bool
    public let confidence: Float?

    public init(embedding: [Float], confirmed: Bool, confidence: Float? = nil) {
        self.embedding = embedding
        self.confirmed = confirmed
        self.confidence = confidence
    }
}

public struct EmbeddingHistoryEntry: Codable, Equatable {
    public let speakerProfileId: UUID
    public let label: String
    public let sessionDate: Date
    public let embeddings: [HistoricalEmbedding]

    public init(speakerProfileId: UUID, label: String, sessionDate: Date, embeddings: [HistoricalEmbedding]) {
        self.speakerProfileId = speakerProfileId
        self.label = label
        self.sessionDate = sessionDate
        self.embeddings = embeddings
    }
}

public final class EmbeddingHistoryStore {
    private let fileURL: URL
    private let maxEntriesPerProfile: Int

    public init(directory: URL? = nil, maxEntriesPerProfile: Int = 500) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("QuickTranscriber")
        self.fileURL = dir.appendingPathComponent("embedding_history.json")
        self.maxEntriesPerProfile = maxEntriesPerProfile
    }

    public func appendSession(entries: [EmbeddingHistoryEntry]) {
        var existing = (try? loadAll()) ?? []
        existing.append(contentsOf: entries)
        existing = pruneEntries(existing)
        do {
            let dir = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(existing)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[EmbeddingHistoryStore] Failed to save: \(error)")
        }
    }

    /// Prune entries so each profile keeps at most `maxEntriesPerProfile` embeddings.
    /// Older sessions are dropped first.
    private func pruneEntries(_ entries: [EmbeddingHistoryEntry]) -> [EmbeddingHistoryEntry] {
        // Count embeddings per profile
        var countByProfile: [UUID: Int] = [:]
        for entry in entries {
            countByProfile[entry.speakerProfileId, default: 0] += entry.embeddings.count
        }

        // No pruning needed if all profiles are within limits
        let needsPruning = countByProfile.values.contains { $0 > maxEntriesPerProfile }
        guard needsPruning else { return entries }

        // Group by profile, keeping chronological order (oldest first)
        var entriesByProfile: [UUID: [EmbeddingHistoryEntry]] = [:]
        var profileOrder: [UUID] = []
        for entry in entries {
            if entriesByProfile[entry.speakerProfileId] == nil {
                profileOrder.append(entry.speakerProfileId)
            }
            entriesByProfile[entry.speakerProfileId, default: []].append(entry)
        }

        var pruned: [EmbeddingHistoryEntry] = []
        for profileId in profileOrder {
            guard var profileEntries = entriesByProfile[profileId] else { continue }
            let totalEmbeddings = profileEntries.reduce(0) { $0 + $1.embeddings.count }
            if totalEmbeddings > maxEntriesPerProfile {
                // Drop oldest sessions until within limit
                var remaining = totalEmbeddings
                while remaining > maxEntriesPerProfile && !profileEntries.isEmpty {
                    remaining -= profileEntries[0].embeddings.count
                    profileEntries.removeFirst()
                }
            }
            pruned.append(contentsOf: profileEntries)
        }
        return pruned
    }

    public func loadAll() throws -> [EmbeddingHistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([EmbeddingHistoryEntry].self, from: data)
    }

    public func removeEntries(for profileIds: Set<UUID>) {
        guard !profileIds.isEmpty else { return }
        var existing = (try? loadAll()) ?? []
        existing.removeAll { profileIds.contains($0.speakerProfileId) }
        do {
            if existing.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                let data = try JSONEncoder().encode(existing)
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            NSLog("[EmbeddingHistoryStore] Failed to remove entries: \(error)")
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func reconstructProfile(for profileId: UUID) throws -> [Float]? {
        let entries = try loadAll()
        let confirmedEntries = entries
            .filter { $0.speakerProfileId == profileId }
            .flatMap { $0.embeddings }
            .filter { $0.confirmed }
        guard !confirmedEntries.isEmpty else { return nil }

        let dims = confirmedEntries[0].embedding.count
        var weightedSum = [Float](repeating: 0, count: dims)
        var totalWeight: Float = 0
        for entry in confirmedEntries {
            let weight = entry.confidence ?? 1.0
            totalWeight += weight
            for i in 0..<dims {
                weightedSum[i] += weight * entry.embedding[i]
            }
        }
        guard totalWeight > 0 else { return nil }
        return weightedSum.map { $0 / totalWeight }
    }
}
