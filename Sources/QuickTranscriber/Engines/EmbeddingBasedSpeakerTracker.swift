import Foundation

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
    }

    private var profiles: [SpeakerProfile] = []
    private var nextLabelIndex: Int = 0
    private let similarityThreshold: Float
    private let updateAlpha: Float
    public var expectedSpeakerCount: Int?

    /// - Parameters:
    ///   - similarityThreshold: Minimum cosine similarity to match a known speaker (default: 0.5)
    ///   - updateAlpha: Weight for new embedding in moving average update (default: 0.3)
    ///   - expectedSpeakerCount: Maximum number of speakers to track (nil = unlimited)
    public init(similarityThreshold: Float = 0.5, updateAlpha: Float = 0.3, expectedSpeakerCount: Int? = nil) {
        self.similarityThreshold = similarityThreshold
        self.updateAlpha = updateAlpha
        self.expectedSpeakerCount = expectedSpeakerCount
    }

    /// Identify a speaker from their embedding vector.
    ///
    /// - Returns: A stable speaker label (A, B, C, ...)
    public func identify(embedding: [Float]) -> String {
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
            let alpha = updateAlpha
            profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
                (1 - alpha) * old + alpha * new
            }
            return profiles[bestIndex].label
        }

        // At capacity: assign to most similar existing speaker instead of creating new
        if let limit = expectedSpeakerCount, profiles.count >= limit, bestIndex >= 0 {
            let alpha = updateAlpha
            profiles[bestIndex].embedding = zip(profiles[bestIndex].embedding, embedding).map { old, new in
                (1 - alpha) * old + alpha * new
            }
            return profiles[bestIndex].label
        }

        // Register new speaker
        let label = String(UnicodeScalar(UInt8(65 + nextLabelIndex % 26)))
        profiles.append(SpeakerProfile(label: label, embedding: embedding))
        nextLabelIndex += 1
        return label
    }

    public func reset() {
        profiles = []
        nextLabelIndex = 0
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
