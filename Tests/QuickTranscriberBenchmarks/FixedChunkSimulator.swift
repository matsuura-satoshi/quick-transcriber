import Foundation
@testable import QuickTranscriberLib

/// Simulates the old fixed-duration ChunkAccumulator behavior for A/B comparison with VADChunkAccumulator.
///
/// Old behavior:
/// - Buffer all samples
/// - Force cut at `chunkDuration` (default 5s)
/// - Early cut when `trailingSilence >= silenceCutoff` AND `totalDuration >= minimumChunkDuration`
/// - Engine-side skip: chunks with `energy < silenceSkipThreshold` are skipped
struct FixedChunkSimulator {
    let chunkDuration: TimeInterval
    let silenceCutoff: TimeInterval
    let silenceThreshold: Float
    let minimumChunkDuration: TimeInterval
    let silenceSkipThreshold: Float

    private let sampleRate: Double = 16000.0
    private var buffer: [Float] = []
    private var trailingSilenceSamples: Int = 0
    private var pendingPrecedingSilence: TimeInterval = 0

    init(
        chunkDuration: TimeInterval = 5.0,
        silenceCutoff: TimeInterval = 0.8,
        silenceThreshold: Float = 0.01,
        minimumChunkDuration: TimeInterval = 1.0,
        silenceSkipThreshold: Float = 0.005
    ) {
        self.chunkDuration = chunkDuration
        self.silenceCutoff = silenceCutoff
        self.silenceThreshold = silenceThreshold
        self.minimumChunkDuration = minimumChunkDuration
        self.silenceSkipThreshold = silenceSkipThreshold
    }

    mutating func appendBuffer(_ samples: [Float]) -> ChunkResult? {
        buffer.append(contentsOf: samples)

        // Track trailing silence
        let energy = VADChunkAccumulator.rmsEnergy(of: samples)
        if energy < silenceThreshold {
            trailingSilenceSamples += samples.count
        } else {
            trailingSilenceSamples = 0
        }

        let totalDuration = TimeInterval(buffer.count) / sampleRate
        let trailingSilence = TimeInterval(trailingSilenceSamples) / sampleRate

        // Early cut: silence exceeds cutoff and total duration above minimum
        if trailingSilence >= silenceCutoff && totalDuration >= minimumChunkDuration {
            return emitChunk()
        }

        // Force cut: total duration exceeds chunkDuration
        if totalDuration >= chunkDuration {
            return emitChunk()
        }

        return nil
    }

    mutating func flush() -> ChunkResult? {
        guard !buffer.isEmpty else { return nil }
        return emitChunk()
    }

    private mutating func emitChunk() -> ChunkResult {
        let trailingSilence = TimeInterval(trailingSilenceSamples) / sampleRate
        let result = ChunkResult(
            samples: buffer,
            trailingSilenceDuration: trailingSilence,
            precedingSilenceDuration: pendingPrecedingSilence
        )
        // Carry trailing silence as next chunk's preceding silence
        pendingPrecedingSilence = trailingSilence
        buffer = []
        trailingSilenceSamples = 0
        return result
    }

    /// Whether a chunk should be skipped due to low energy (engine-side skip).
    func shouldSkip(_ chunk: ChunkResult) -> Bool {
        let energy = VADChunkAccumulator.rmsEnergy(of: chunk.samples)
        return energy < silenceSkipThreshold
    }
}
