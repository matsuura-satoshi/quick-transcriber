import Foundation

public struct HistoricalEmbedding: Codable, Equatable {
    public let embedding: [Float]
    public let confirmed: Bool

    public init(embedding: [Float], confirmed: Bool) {
        self.embedding = embedding
        self.confirmed = confirmed
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
        let confirmedEmbeddings = entries
            .filter { $0.speakerProfileId == profileId }
            .flatMap { $0.embeddings }
            .filter { $0.confirmed }
            .map { $0.embedding }
        guard !confirmedEmbeddings.isEmpty else { return nil }

        let count = Float(confirmedEmbeddings.count)
        var avg = [Float](repeating: 0, count: confirmedEmbeddings[0].count)
        for emb in confirmedEmbeddings {
            for i in 0..<avg.count {
                avg[i] += emb[i]
            }
        }
        for i in 0..<avg.count {
            avg[i] /= count
        }
        return avg
    }
}
