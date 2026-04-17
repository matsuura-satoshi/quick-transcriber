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

public struct WeightedEmbedding: Sendable {
    /// Unique identifier for this embedding entry. Used by correctAssignment
    /// to remove by identity rather than embedding-value match.
    public let entryId: UUID
    public let embedding: [Float]
    public let confidence: Float

    public init(entryId: UUID = UUID(), embedding: [Float], confidence: Float) {
        self.entryId = entryId
        self.embedding = embedding
        self.confidence = confidence
    }
}

extension WeightedEmbedding: Equatable {
    /// Equality compares semantic content only; entryId is a tracking ID
    /// and is intentionally excluded so value-based assertions remain stable.
    public static func == (lhs: WeightedEmbedding, rhs: WeightedEmbedding) -> Bool {
        lhs.embedding == rhs.embedding && lhs.confidence == rhs.confidence
    }
}

public struct UserCorrection: Sendable, Equatable {
    public let entryId: UUID
    public let fromId: UUID
    public let toId: UUID

    public init(entryId: UUID, fromId: UUID, toId: UUID) {
        self.entryId = entryId
        self.fromId = fromId
        self.toId = toId
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
    private var userCorrections: [UserCorrection] = []
    private let similarityThreshold: Float
    private let updateAlpha: Float
    public var expectedSpeakerCount: Int?
    private let strategy: ProfileStrategy
    private var identifyCount: Int = 0
    private let lock = NSLock()
    private var lastConfirmedId: UUID?

    /// When true, `identify()` will not update profile embeddings, and
    /// `correctAssignment()` will record a `UserCorrection` without mutating
    /// any profile centroid (centroid is frozen for post-hoc learning later).
    public var suppressLearning: Bool = false

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
        lock.withLock {
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

            // Tie-breaker: bestSimilarity と tieBreakerEpsilon 内のすべての候補を集める
            if bestIndex >= 0 && profiles.count > 1 {
                var candidates: [(index: Int, profile: SpeakerProfile)] = []
                for (i, profile) in profiles.enumerated() {
                    let sim = Self.cosineSimilarity(embedding, profile.embedding)
                    if abs(sim - bestSimilarity) <= Constants.Embedding.tieBreakerEpsilon {
                        candidates.append((i, profile))
                    }
                }
                if candidates.count > 1 {
                    // 1. hitCount 最大を優先
                    let maxHit = candidates.map { $0.profile.hitCount }.max()!
                    let byHit = candidates.filter { $0.profile.hitCount == maxHit }
                    if byHit.count == 1 {
                        bestIndex = byHit[0].index
                    } else if let lastId = lastConfirmedId,
                              let lastMatch = byHit.first(where: { $0.profile.id == lastId }) {
                        // 2. hitCount 同値の場合は lastConfirmedId を優先
                        bestIndex = lastMatch.index
                    } else {
                        // 3. enumerate 順（最初の候補）
                        bestIndex = byHit[0].index
                    }
                }
            }

            if bestIndex >= 0 && bestSimilarity >= similarityThreshold {
                if !suppressLearning {
                    profiles[bestIndex].embeddingHistory.append(WeightedEmbedding(embedding: embedding, confidence: bestSimilarity))
                    recalculateEmbedding(at: bestIndex)
                }
                lastConfirmedId = profiles[bestIndex].id
                return SpeakerIdentification(speakerId: profiles[bestIndex].id, confidence: bestSimilarity, embedding: embedding)
            }

            // At capacity: assign to most similar existing speaker instead of creating new
            if let limit = expectedSpeakerCount, profiles.count >= limit, bestIndex >= 0 {
                if !suppressLearning && bestSimilarity >= similarityThreshold {
                    profiles[bestIndex].embeddingHistory.append(WeightedEmbedding(embedding: embedding, confidence: bestSimilarity))
                    recalculateEmbedding(at: bestIndex)
                }
                lastConfirmedId = profiles[bestIndex].id
                return SpeakerIdentification(speakerId: profiles[bestIndex].id, confidence: bestSimilarity, embedding: embedding)
            }

            // Registration gate: only register if sufficiently different from all existing profiles
            if case .registrationGate(let minSeparation) = strategy, bestIndex >= 0 {
                if bestSimilarity >= minSeparation {
                    if !suppressLearning {
                        profiles[bestIndex].embeddingHistory.append(WeightedEmbedding(embedding: embedding, confidence: bestSimilarity))
                        recalculateEmbedding(at: bestIndex)
                    }
                    lastConfirmedId = profiles[bestIndex].id
                    return SpeakerIdentification(speakerId: profiles[bestIndex].id, confidence: bestSimilarity, embedding: embedding)
                }
            }

            // Register new speaker
            let newId = UUID()
            profiles.append(SpeakerProfile(id: newId, embedding: embedding, hitCount: 1, embeddingHistory: [WeightedEmbedding(embedding: embedding, confidence: 1.0)]))
            lastConfirmedId = newId
            return SpeakerIdentification(speakerId: newId, confidence: 1.0, embedding: embedding)
        }
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
        lock.withLock {
            guard let sourceIdx = profiles.firstIndex(where: { $0.id == sourceId }),
                  let targetIdx = profiles.firstIndex(where: { $0.id == targetId }) else {
                return
            }
            profiles[targetIdx].embeddingHistory.append(contentsOf: profiles[sourceIdx].embeddingHistory)
            recalculateEmbedding(at: targetIdx)
            profiles.remove(at: sourceIdx)
        }
    }

    /// Correct a speaker assignment by recording the user's reassignment.
    ///
    /// Behavior depends on `suppressLearning`:
    /// - When `true` (Manual mode): the profile centroid is not mutated.
    ///   A `UserCorrection` is appended to `userCorrections` for post-hoc learning.
    /// - When `false` (Auto mode): the embedding is removed from `oldId`'s history
    ///   via near-exact cosine match (≥ 0.9999, tolerant to floating-point jitter),
    ///   then appended to `newId`'s profile with confidence = `userCorrectionConfidence`.
    ///
    /// - Parameters:
    ///   - embedding: The embedding vector associated with the reassigned segment
    ///   - oldId: The current speaker UUID
    ///   - newId: The target speaker UUID (created if it doesn't exist in Auto mode)
    public func correctAssignment(embedding: [Float], from oldId: UUID, to newId: UUID) {
        lock.withLock {
            if suppressLearning {
                // Manual mode: profile centroid は動かさない。
                // 修正情報だけ記録して post-hoc 学習で使う。
                userCorrections.append(UserCorrection(
                    entryId: UUID(),
                    fromId: oldId,
                    toId: newId
                ))
                return
            }

            // Auto mode: 従来どおり centroid を更新するが、confidence を下げて
            // 汚染速度を緩和する。
            if let oldIdx = profiles.firstIndex(where: { $0.id == oldId }) {
                _ = Self.removeClosestMatch(in: &profiles[oldIdx].embeddingHistory, target: embedding)
                if profiles[oldIdx].embeddingHistory.isEmpty {
                    profiles.remove(at: oldIdx)
                } else {
                    recalculateEmbedding(at: oldIdx)
                }
            }

            let addConfidence = Constants.Embedding.userCorrectionConfidence
            if let newIdx = profiles.firstIndex(where: { $0.id == newId }) {
                profiles[newIdx].embeddingHistory.append(
                    WeightedEmbedding(embedding: embedding, confidence: addConfidence))
                recalculateEmbedding(at: newIdx)
            } else {
                profiles.append(SpeakerProfile(
                    id: newId,
                    embedding: embedding,
                    hitCount: 1,
                    embeddingHistory: [WeightedEmbedding(embedding: embedding, confidence: addConfidence)]
                ))
            }
        }
    }

    public func reset() {
        lock.withLock {
            profiles = []
            lastConfirmedId = nil
        }
    }

    public func exportProfiles() -> [(speakerId: UUID, embedding: [Float], hitCount: Int)] {
        lock.withLock {
            profiles.map { ($0.id, $0.embedding, $0.hitCount) }
        }
    }

    public func exportUserCorrections() -> [UserCorrection] {
        lock.withLock { userCorrections }
    }

    public func resetUserCorrections() {
        lock.withLock { userCorrections = [] }
    }

    public func exportDetailedProfiles() -> [(speakerId: UUID, embedding: [Float], hitCount: Int, embeddingHistory: [WeightedEmbedding])] {
        lock.withLock {
            profiles.map { ($0.id, $0.embedding, $0.hitCount, $0.embeddingHistory) }
        }
    }

    public func loadProfiles(_ loadedProfiles: [(speakerId: UUID, embedding: [Float])]) {
        lock.withLock {
            profiles = loadedProfiles.map {
                SpeakerProfile(id: $0.speakerId, embedding: $0.embedding, hitCount: 1,
                               embeddingHistory: [WeightedEmbedding(embedding: $0.embedding, confidence: 1.0)])
            }
            lastConfirmedId = nil
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

    /// Remove the embedding history entry most similar to `target` (≥ 0.9999 cosine).
    /// Returns true if an entry was removed.
    private static func removeClosestMatch(in history: inout [WeightedEmbedding], target: [Float]) -> Bool {
        var bestIndex = -1
        var bestSim: Float = 0.9999  // threshold: 実質同一
        for (i, entry) in history.enumerated() {
            let sim = cosineSimilarity(entry.embedding, target)
            if sim >= bestSim {
                bestSim = sim
                bestIndex = i
            }
        }
        if bestIndex >= 0 {
            history.remove(at: bestIndex)
            return true
        }
        return false
    }
}
