import Foundation

public enum ProfileStrategy: Sendable {
    case none
    case culling(interval: Int, minHits: Int)
    case merging(interval: Int, threshold: Float)
    case registrationGate(minSeparation: Float)
    case combined(cullInterval: Int, minHits: Int, mergeThreshold: Float)
}

public struct SpeakerIdentification: Sendable, Equatable {
    public let speakerId: UUID
    public let confidence: Float
    public let embedding: [Float]?

    public init(speakerId: UUID, confidence: Float, embedding: [Float]? = nil) {
        self.speakerId = speakerId
        self.confidence = confidence
        self.embedding = embedding
    }
}

public struct WeightedEmbedding: Sendable, Equatable {
    public let embedding: [Float]
    public let confidence: Float

    public init(embedding: [Float], confidence: Float) {
        self.embedding = embedding
        self.confidence = confidence
    }
}

/// Tracks speakers across diarization calls using embedding cosine similarity.
///
/// FluidAudio reassigns internal speaker IDs on each `process()` call,
/// making them unreliable for persistent tracking. This tracker maintains
/// a profile table of known speakers and matches new embeddings via
/// cosine similarity, providing stable UUIDs across an entire session.
public final class EmbeddingBasedSpeakerTracker: @unchecked Sendable {
    public struct SpeakerProfile {
        public let id: UUID
        public var embedding: [Float]
        public var hitCount: Int
        public var embeddingHistory: [WeightedEmbedding]
    }

    private var profiles: [SpeakerProfile] = []
    private let similarityThreshold: Float
    private let updateAlpha: Float
    public var expectedSpeakerCount: Int?
    private let strategy: ProfileStrategy
    private var identifyCount: Int = 0

    /// - Parameters:
    ///   - similarityThreshold: Minimum cosine similarity to match a known speaker (default: 0.5)
    ///   - updateAlpha: Unused, kept for backward compatibility (default: 0.3)
    ///   - expectedSpeakerCount: Maximum number of speakers to track (nil = unlimited)
    ///   - strategy: Profile maintenance strategy (default: .none)
    public init(similarityThreshold: Float = Constants.Embedding.similarityThreshold, updateAlpha: Float = 0.3,
                expectedSpeakerCount: Int? = nil, strategy: ProfileStrategy = .none) {
        self.similarityThreshold = similarityThreshold
        self.updateAlpha = updateAlpha
        self.expectedSpeakerCount = expectedSpeakerCount
        self.strategy = strategy
    }

    /// Identify a speaker from their embedding vector.
    ///
    /// - Returns: A `SpeakerIdentification` with the stable speaker label and confidence score
    public func identify(embedding: [Float]) -> SpeakerIdentification {
        identifyCount += 1
        maintainProfiles()

        var bestIndex = -1
        var bestSimilarity: Float = -1

        for (i, profile) in profiles.enumerated() {
            let sim = Self.cosineSimilarity(embedding, profile.embedding)
            if sim > bestSimilarity {
                bestSimilarity = sim
                bestIndex = i
            }
        }

        if bestIndex >= 0 && bestSimilarity >= similarityThreshold {
            profiles[bestIndex].embeddingHistory.append(WeightedEmbedding(embedding: embedding, confidence: bestSimilarity))
            recalculateEmbedding(at: bestIndex)
            return SpeakerIdentification(speakerId: profiles[bestIndex].id, confidence: bestSimilarity, embedding: embedding)
        }

        // At capacity: assign to most similar existing speaker instead of creating new
        if let limit = expectedSpeakerCount, profiles.count >= limit, bestIndex >= 0 {
            profiles[bestIndex].embeddingHistory.append(WeightedEmbedding(embedding: embedding, confidence: bestSimilarity))
            recalculateEmbedding(at: bestIndex)
            return SpeakerIdentification(speakerId: profiles[bestIndex].id, confidence: bestSimilarity, embedding: embedding)
        }

        // Registration gate: only register if sufficiently different from all existing profiles
        if case .registrationGate(let minSeparation) = strategy, bestIndex >= 0 {
            if bestSimilarity >= minSeparation {
                profiles[bestIndex].embeddingHistory.append(WeightedEmbedding(embedding: embedding, confidence: bestSimilarity))
                recalculateEmbedding(at: bestIndex)
                return SpeakerIdentification(speakerId: profiles[bestIndex].id, confidence: bestSimilarity, embedding: embedding)
            }
        }

        // Register new speaker
        let newId = UUID()
        profiles.append(SpeakerProfile(id: newId, embedding: embedding, hitCount: 1, embeddingHistory: [WeightedEmbedding(embedding: embedding, confidence: 1.0)]))
        return SpeakerIdentification(speakerId: newId, confidence: 1.0, embedding: embedding)
    }

    /// Recalculate the centroid embedding as confidence-weighted mean of all history entries.
    private func recalculateEmbedding(at index: Int) {
        let history = profiles[index].embeddingHistory
        guard let first = history.first else { return }
        let dims = first.embedding.count
        var weightedSum = [Float](repeating: 0, count: dims)
        var totalWeight: Float = 0
        for entry in history {
            totalWeight += entry.confidence
            for i in 0..<dims {
                weightedSum[i] += entry.confidence * entry.embedding[i]
            }
        }
        guard totalWeight > 0 else { return }
        profiles[index].embedding = weightedSum.map { $0 / totalWeight }
        profiles[index].hitCount = history.count
    }

    private func maintainProfiles() {
        switch strategy {
        case .none, .registrationGate:
            break
        case .culling(let interval, let minHits):
            guard identifyCount % interval == 0 else { return }
            profiles.removeAll { $0.hitCount < minHits }
        case .merging(let interval, let threshold):
            guard identifyCount % interval == 0 else { return }
            mergeProfiles(threshold: threshold)
        case .combined(let cullInterval, let minHits, let mergeThreshold):
            guard identifyCount % cullInterval == 0 else { return }
            profiles.removeAll { $0.hitCount < minHits }
            mergeProfiles(threshold: mergeThreshold)
        }
    }

    private func mergeProfiles(threshold: Float) {
        var i = 0
        while i < profiles.count {
            var j = i + 1
            while j < profiles.count {
                let sim = Self.cosineSimilarity(profiles[i].embedding, profiles[j].embedding)
                if sim >= threshold {
                    // Keep the profile with more hits, absorb the other
                    let (keep, remove) = profiles[i].hitCount >= profiles[j].hitCount ? (i, j) : (j, i)
                    profiles[keep].embeddingHistory.append(contentsOf: profiles[remove].embeddingHistory)
                    recalculateEmbedding(at: keep)
                    profiles.remove(at: remove)
                    if remove < keep { i = max(0, i - 1) }
                } else {
                    j += 1
                }
            }
            i += 1
        }
    }

    /// Merge one speaker profile into another, combining embedding histories.
    public func mergeProfile(from sourceId: UUID, into targetId: UUID) {
        guard let sourceIdx = profiles.firstIndex(where: { $0.id == sourceId }),
              let targetIdx = profiles.firstIndex(where: { $0.id == targetId }) else {
            return
        }
        profiles[targetIdx].embeddingHistory.append(contentsOf: profiles[sourceIdx].embeddingHistory)
        recalculateEmbedding(at: targetIdx)
        profiles.remove(at: sourceIdx)
    }

    /// Correct a speaker assignment by moving an embedding from one profile to another.
    ///
    /// - Parameters:
    ///   - embedding: The embedding vector to reassign (matched by value)
    ///   - oldId: The current speaker UUID
    ///   - newId: The target speaker UUID (created if it doesn't exist)
    public func correctAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) {
        // Remove from old profile
        if let oldIdx = profiles.firstIndex(where: { $0.id == oldId }) {
            profiles[oldIdx].embeddingHistory.removeAll { $0.embedding == embedding }
            if profiles[oldIdx].embeddingHistory.isEmpty {
                profiles.remove(at: oldIdx)
            } else {
                recalculateEmbedding(at: oldIdx)
            }
        }

        // Add to new/existing profile with confidence 1.0 (user-confirmed)
        if let newIdx = profiles.firstIndex(where: { $0.id == newId }) {
            profiles[newIdx].embeddingHistory.append(WeightedEmbedding(embedding: embedding, confidence: 1.0))
            recalculateEmbedding(at: newIdx)
        } else {
            profiles.append(SpeakerProfile(
                id: newId,
                embedding: embedding,
                hitCount: 1,
                embeddingHistory: [WeightedEmbedding(embedding: embedding, confidence: 1.0)]
            ))
        }
    }

    public func reset() {
        profiles = []
    }

    public func exportProfiles() -> [(speakerId: UUID, embedding: [Float], hitCount: Int)] {
        profiles.map { ($0.id, $0.embedding, $0.hitCount) }
    }

    public func exportDetailedProfiles() -> [(speakerId: UUID, embedding: [Float], hitCount: Int, embeddingHistory: [WeightedEmbedding])] {
        profiles.map { ($0.id, $0.embedding, $0.hitCount, $0.embeddingHistory) }
    }

    public func loadProfiles(_ loadedProfiles: [(speakerId: UUID, embedding: [Float])]) {
        profiles = loadedProfiles.map {
            SpeakerProfile(id: $0.speakerId, embedding: $0.embedding, hitCount: 1,
                           embeddingHistory: [WeightedEmbedding(embedding: $0.embedding, confidence: 1.0)])
        }
    }

    /// Cosine similarity between two vectors.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
