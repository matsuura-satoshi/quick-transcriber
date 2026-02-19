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

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("QuickTranscriber")
        self.fileURL = dir.appendingPathComponent("embedding_history.json")
    }

    public func appendSession(entries: [EmbeddingHistoryEntry]) {
        var existing = (try? loadAll()) ?? []
        existing.append(contentsOf: entries)
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

    public func loadAll() throws -> [EmbeddingHistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([EmbeddingHistoryEntry].self, from: data)
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
