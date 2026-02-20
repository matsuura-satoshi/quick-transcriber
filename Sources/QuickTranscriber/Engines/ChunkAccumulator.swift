import Foundation

/// Result of a chunk cut, containing audio samples and trailing silence info.
public struct ChunkResult: Sendable {
    public let samples: [Float]
    public let trailingSilenceDuration: TimeInterval
}

/// Accumulates audio buffers and emits chunks based on silence detection or max duration.
/// Pure logic with no external dependencies — easy to unit test.
public struct ChunkAccumulator {
    /// Maximum chunk duration in seconds before forced cut.
    public var chunkDuration: TimeInterval
    /// Silence duration in seconds to trigger an early cut.
    public var silenceCutoffDuration: TimeInterval
    /// RMS energy threshold below which audio is considered silence.
    public var silenceEnergyThreshold: Float
    /// Minimum chunk duration in seconds (won't cut shorter than this).
    public var minimumChunkDuration: TimeInterval

    private let sampleRate: Double = Constants.Audio.sampleRate
    private var buffer: [Float] = []
    /// Duration of continuous silence at the end of buffer, in seconds.
    private var trailingSilenceDuration: TimeInterval = 0

    public init(
        chunkDuration: TimeInterval = 3.0,
        silenceCutoffDuration: TimeInterval = 0.8,
        silenceEnergyThreshold: Float = 0.01,
        minimumChunkDuration: TimeInterval = 1.0
    ) {
        self.chunkDuration = chunkDuration
        self.silenceCutoffDuration = silenceCutoffDuration
        self.silenceEnergyThreshold = silenceEnergyThreshold
        self.minimumChunkDuration = minimumChunkDuration
    }

    /// Append a buffer of 16kHz Float32 samples.
    /// Returns a ChunkResult if cut conditions are met, otherwise nil.
    public mutating func appendBuffer(_ samples: [Float]) -> ChunkResult? {
        guard !samples.isEmpty else { return nil }

        buffer.append(contentsOf: samples)

        let energy = Self.rmsEnergy(of: samples)
        let bufferDuration = TimeInterval(samples.count) / sampleRate

        if energy < silenceEnergyThreshold {
            trailingSilenceDuration += bufferDuration
        } else {
            trailingSilenceDuration = 0
        }

        let totalDuration = TimeInterval(buffer.count) / sampleRate

        // Condition B: Max duration reached → forced cut
        if totalDuration >= chunkDuration {
            return cutChunk()
        }

        // Condition A: Silence cutoff + minimum duration met
        if trailingSilenceDuration >= silenceCutoffDuration && totalDuration >= minimumChunkDuration {
            return cutChunk()
        }

        return nil
    }

    /// Flush any remaining audio (e.g., when stopping recording).
    /// Returns the remaining buffer if it has enough content, otherwise nil.
    public mutating func flush() -> ChunkResult? {
        guard !buffer.isEmpty else { return nil }
        let totalDuration = TimeInterval(buffer.count) / sampleRate
        // Only flush if there's meaningful audio (at least 0.5s)
        guard totalDuration >= 0.5 else {
            buffer.removeAll()
            trailingSilenceDuration = 0
            return nil
        }
        return cutChunk()
    }

    /// Reset the accumulator, discarding all buffered audio.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        trailingSilenceDuration = 0
    }

    /// Calculate RMS energy of a sample buffer.
    public static func rmsEnergy(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    // MARK: - Private

    private mutating func cutChunk() -> ChunkResult {
        let chunk = buffer
        let silence = trailingSilenceDuration
        buffer.removeAll(keepingCapacity: true)
        trailingSilenceDuration = 0
        return ChunkResult(samples: chunk, trailingSilenceDuration: silence)
    }
}
