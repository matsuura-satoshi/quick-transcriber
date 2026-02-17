import Foundation

public enum ProfileStrategy: Sendable {
    case none
    case culling(interval: Int, minHits: Int)
    case merging(interval: Int, threshold: Float)
    case registrationGate(minSeparation: Float)
    case combined(cullInterval: Int, minHits: Int, mergeThreshold: Float)
}

/// Tracks speakers across diarization calls using embedding cosine similarity.
///
/// FluidAudio reassigns internal speaker IDs on each `process()` call,
/// making them unreliable for persistent tracking. This tracker maintains
/// a profile table of known speakers and matches new embeddings via
/// cosine similarity, providing stable labels (A, B, C, ...) across
/// an entire session.
public final class EmbeddingBasedSpeakerTracker: @unchecked Sendable {
    public struct SpeakerProfile {
        public let label: String
        public var embedding: [Float]
        public var hitCount: Int
    }

    private var profiles: [SpeakerProfile] = []
    private var nextLabelIndex: Int = 0
    private let similarityThreshold: Float
    private let updateAlpha: Float
    public var expectedSpeakerCount: Int?
    private let strategy: ProfileStrategy
    private var identifyCount: Int = 0

    /// - Parameters:
    ///   - similarityThreshold: Minimum cosine similarity to match a known speaker (default: 0.5)
    ///   - updateAlpha: Weight for new embedding in moving average update (default: 0.3)
    ///   - expectedSpeakerCount: Maximum number of speakers to track (nil = unlimited)
    ///   - strategy: Profile maintenance strategy (default: .none)
    public init(similarityThreshold: Float = 0.5, updateAlpha: Float = 0.3,
                expectedSpeakerCount: Int? = nil, strategy: ProfileStrategy = .none) {
        self.similarityThreshold = similarityThreshold
        self.updateAlpha = updateAlpha
        self.expectedSpeakerCount = expectedSpeakerCount
        self.strategy = strategy
    }

    /// Identify a speaker from their embedding vector.
    ///
    /// - Returns: A stable speaker label (A, B, C, ...)
    public func identify(embedding: [Float]) -> String {
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
            // Update profile with moving average
            profiles[bestIndex].hitCount += 1
            let alpha = updateAlpha
            profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
                (1 - alpha) * old + alpha * new
            }
            return profiles[bestIndex].label
        }

        // At capacity: assign to most similar existing speaker instead of creating new
        if let limit = expectedSpeakerCount, profiles.count >= limit, bestIndex >= 0 {
            profiles[bestIndex].hitCount += 1
            let alpha = updateAlpha
            profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
                (1 - alpha) * old + alpha * new
            }
            return profiles[bestIndex].label
        }

        // Registration gate: only register if sufficiently different from all existing profiles
        if case .registrationGate(let minSeparation) = strategy, bestIndex >= 0 {
            if bestSimilarity >= minSeparation {
                profiles[bestIndex].hitCount += 1
                let alpha = updateAlpha
                profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
                    (1 - alpha) * old + alpha * new
                }
                return profiles[bestIndex].label
            }
        }

        // Register new speaker
        let label = String(UnicodeScalar(UInt8(65 + nextLabelIndex % 26)))
        profiles.append(SpeakerProfile(label: label, embedding: embedding, hitCount: 1))
        nextLabelIndex += 1
        return label
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
        case .combined:
            break
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
                    let alpha = updateAlpha
                    profiles[keep].embedding = zip(profiles[keep].embedding, profiles[remove].embedding).map { a, b in
                        (1 - alpha) * a + alpha * b
                    }
                    profiles[keep].hitCount += profiles[remove].hitCount
                    profiles.remove(at: remove)
                    if remove < keep { i = max(0, i - 1) }
                } else {
                    j += 1
                }
            }
            i += 1
        }
    }

    public func reset() {
        profiles = []
        nextLabelIndex = 0
    }

    public func exportProfiles() -> [(label: String, embedding: [Float], hitCount: Int)] {
        profiles.map { ($0.label, $0.embedding, $0.hitCount) }
    }

    public func loadProfiles(_ loadedProfiles: [(label: String, embedding: [Float])]) {
        profiles = loadedProfiles.map { SpeakerProfile(label: $0.label, embedding: $0.embedding, hitCount: 0) }
        nextLabelIndex = loadedProfiles.count
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
