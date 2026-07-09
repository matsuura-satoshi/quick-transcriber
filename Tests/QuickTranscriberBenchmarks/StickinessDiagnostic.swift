import Foundation

/// Per-chunk diagnostic record emitted by the extended Manual-mode replay.
/// Captures the pre-Viterbi (raw) tracker decision alongside the smoothed /
/// final attribution so misattribution causes can be separated.
struct ChunkDiagnostic: Codable {
    let start: Double
    let end: Double
    /// Pre-Viterbi tracker label (resolved display name); nil if the diarizer
    /// returned no identification for this chunk.
    let rawName: String?
    let rawConfidence: Float?
    /// True when the diarizer returned the pacer-cached result of an earlier
    /// window instead of running fresh diarization on this chunk.
    let cached: Bool
    /// True when the chunk followed a >= end-of-utterance silence gap, which
    /// resets the smoother (immediateConfirmNext) and forces a fresh run.
    let significantSilence: Bool
    /// The smoother's own output for this chunk; nil while pending.
    let smoothedName: String?
    /// Final attributed label after pending flush / trailing inheritance.
    let finalName: String?
    /// True when finalName came from a flush/inheritance, not an own confirmation.
    let inherited: Bool
    /// Cosine similarity of the raw query embedding to each registered centroid.
    let cosines: [String: Float]
    /// The raw query embedding itself (nil when the diarizer returned none).
    /// Recorded so offline analyses can simulate alternative matching schemes
    /// (e.g. session-overlay) without replaying audio.
    let embedding: [Float]?

    init(
        start: Double, end: Double,
        rawName: String?, rawConfidence: Float?,
        cached: Bool, significantSilence: Bool,
        smoothedName: String?, finalName: String?, inherited: Bool,
        cosines: [String: Float],
        embedding: [Float]? = nil
    ) {
        self.start = start
        self.end = end
        self.rawName = rawName
        self.rawConfidence = rawConfidence
        self.cached = cached
        self.significantSilence = significantSilence
        self.smoothedName = smoothedName
        self.finalName = finalName
        self.inherited = inherited
        self.cosines = cosines
        self.embedding = embedding
    }

    /// Copy with the final label resolved (used when a pending chunk is
    /// flushed to a later confirmation or inherits the trailing speaker).
    func withFinal(_ name: String?, inherited: Bool) -> ChunkDiagnostic {
        ChunkDiagnostic(
            start: start, end: end,
            rawName: rawName, rawConfidence: rawConfidence,
            cached: cached, significantSilence: significantSilence,
            smoothedName: smoothedName, finalName: name, inherited: inherited,
            cosines: cosines,
            embedding: embedding
        )
    }
}

/// Cause taxonomy for a misattributed chunk (finalName != ground truth).
enum MisattributionCause: String, Codable, CaseIterable {
    /// Raw tracker label matched ground truth but the smoother overrode it —
    /// the Viterbi/lastConfirmed stickiness the handoff calls "smoother-flip".
    case smootherFlip
    /// Raw label was wrong on a fresh diarization result — the query embedding
    /// scored higher against the wrong profile. Diagnosed 2026-06-10 as
    /// embedding/profile confusion (NOT the 15 s window swallowing short turns:
    /// wrong runs persist through 60 s+ of continuous single-speaker audio).
    case rawWrongFresh
    /// Raw label was wrong AND the result was a pacer-cached value computed
    /// from an earlier window — the chunk's own audio was never diarized.
    case staleCache
    /// Chunk had no own confirmation; its label was inherited from a later
    /// pending flush or the trailing last-confirmed fallback.
    case pendingInherit
    /// Diarizer returned nil; the smoother held the previous confirmed speaker.
    case noObservationHold
}

enum StickinessClassifier {
    /// Classify a misattributed chunk; returns nil when the chunk is correct.
    static func classify(chunk: ChunkDiagnostic, groundTruth: String) -> MisattributionCause? {
        guard let final = chunk.finalName, final != groundTruth else { return nil }
        if chunk.inherited { return .pendingInherit }
        guard let raw = chunk.rawName else { return .noObservationHold }
        if raw == groundTruth { return .smootherFlip }
        return chunk.cached ? .staleCache : .rawWrongFresh
    }

    /// Aggregate cause counts over (chunk, groundTruth) pairs; correct chunks excluded.
    static func aggregate(chunks: [(ChunkDiagnostic, String)]) -> [MisattributionCause: Int] {
        var counts: [MisattributionCause: Int] = [:]
        for (chunk, gt) in chunks {
            if let cause = classify(chunk: chunk, groundTruth: gt) {
                counts[cause, default: 0] += 1
            }
        }
        return counts
    }
}
