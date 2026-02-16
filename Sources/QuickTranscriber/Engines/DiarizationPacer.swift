import Foundation

/// Controls when diarization should run based on accumulated audio samples.
///
/// Instead of running diarization on every transcription chunk (e.g., every 3 seconds),
/// the pacer accumulates chunks and only triggers diarization when enough audio
/// has been collected (e.g., every 7 seconds). This reduces label flips and improves
/// accuracy by giving the diarizer a wider time range for speaker identification.
public struct DiarizationPacer {
    public let diarizationChunkDuration: TimeInterval
    public let sampleRate: Int
    public private(set) var samplesSinceLastDiarization: Int = 0
    public var lastLabel: String?

    public init(diarizationChunkDuration: TimeInterval, sampleRate: Int) {
        self.diarizationChunkDuration = diarizationChunkDuration
        self.sampleRate = sampleRate
    }

    /// Accumulate audio samples and determine whether diarization should run.
    ///
    /// - Returns: `true` if accumulated samples have reached the threshold.
    public mutating func accumulate(chunkSamples: Int) -> Bool {
        samplesSinceLastDiarization += chunkSamples
        let threshold = Int(diarizationChunkDuration * Double(sampleRate))
        return samplesSinceLastDiarization >= threshold
    }

    /// Reset the accumulation counter after running diarization.
    public mutating func reset() {
        samplesSinceLastDiarization = 0
    }
}
