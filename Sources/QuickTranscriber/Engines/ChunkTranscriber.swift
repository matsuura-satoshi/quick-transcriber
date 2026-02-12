import Foundation
import WhisperKit

/// Protocol for transcribing a chunk of audio.
/// Abstracts WhisperKit.transcribe(audioArray:) for testability.
public protocol ChunkTranscriber: AnyObject {
    func setup(model: String) async throws
    func transcribe(audioArray: [Float], language: String, parameters: TranscriptionParameters) async throws -> [TranscribedSegment]
}

/// Production implementation backed by WhisperKit.
public final class WhisperKitChunkTranscriber: ChunkTranscriber {
    private var whisperKit: WhisperKit?

    public init() {}

    public func setup(model: String) async throws {
        self.whisperKit = try await WhisperKitModelLoader.createWhisperKit(model: model)
    }

    public func transcribe(audioArray: [Float], language: String, parameters: TranscriptionParameters) async throws -> [TranscribedSegment] {
        guard let whisperKit else {
            throw TranscriptionEngineError.notInitialized
        }

        // Short chunks are padded to 30s mel spectrogram → ~90% silence.
        // All quality thresholds MUST be disabled (nil) or segments get skipped.
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: parameters.temperature,
            temperatureFallbackCount: parameters.temperatureFallbackCount,
            sampleLength: parameters.sampleLength,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            compressionRatioThreshold: nil,
            logProbThreshold: nil,
            firstTokenLogProbThreshold: nil,
            noSpeechThreshold: nil,
            concurrentWorkerCount: parameters.concurrentWorkerCount
        )

        let results = try await whisperKit.transcribe(audioArray: audioArray, decodeOptions: options)
        return results.flatMap { result in
            result.segments.compactMap { segment -> TranscribedSegment? in
                let cleanedText = TranscriptionUtils.cleanSegmentText(segment.text)
                guard !cleanedText.isEmpty else { return nil }
                return TranscribedSegment(
                    text: cleanedText,
                    avgLogprob: segment.avgLogprob,
                    compressionRatio: segment.compressionRatio,
                    noSpeechProb: segment.noSpeechProb
                )
            }
        }
    }
}
