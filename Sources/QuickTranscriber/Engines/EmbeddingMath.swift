import Foundation

/// 話者 embedding ベクトルの共有演算。
/// tracker / EmbeddingHistoryStore / engine / store に分散していた
/// 中核計算を 1 箇所に集約する。
public enum EmbeddingMath {
    /// Cosine similarity between two vectors.
    /// Returns 0 for mismatched dimensions, empty vectors, or zero norm.
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

    /// Weight 付き平均。次元が先頭エントリと異なるものはスキップする。
    /// - Returns: items が空、または有効な総 weight が 0 のとき nil。
    public static func weightedMean(_ items: [(embedding: [Float], weight: Float)]) -> [Float]? {
        guard let first = items.first, !first.embedding.isEmpty else { return nil }
        let dims = first.embedding.count
        var weightedSum = [Float](repeating: 0, count: dims)
        var totalWeight: Float = 0
        for item in items {
            guard item.embedding.count == dims else { continue }
            totalWeight += item.weight
            for i in 0..<dims {
                weightedSum[i] += item.weight * item.embedding[i]
            }
        }
        guard totalWeight > 0 else { return nil }
        return weightedSum.map { $0 / totalWeight }
    }

    /// 線形ブレンド: (1-alpha)*a + alpha*b（zip 準拠: 長さが違う場合は短い方に切り詰め）。
    public static func blend(_ a: [Float], _ b: [Float], alpha: Float) -> [Float] {
        zip(a, b).map { (1 - alpha) * $0 + alpha * $1 }
    }
}
