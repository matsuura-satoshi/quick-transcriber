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
        // Quality thresholds MUST be disabled (nil) for short chunks or segments get skipped.
        // For file mode with longer chunks (≥15s), thresholds improve accuracy.
        let chunkDuration = Double(audioArray.count) / Constants.Audio.sampleRate
        let useQualityThresholds = chunkDuration >= parameters.qualityThresholdMinChunkDuration
            && parameters.compressionRatioThreshold != nil

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: parameters.temperature,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: parameters.temperatureFallbackCount,
            sampleLength: parameters.sampleLength,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: useQualityThresholds ? parameters.suppressBlank : false,
            compressionRatioThreshold: useQualityThresholds ? parameters.compressionRatioThreshold : nil,
            logProbThreshold: useQualityThresholds ? parameters.logProbThreshold : nil,
            firstTokenLogProbThreshold: useQualityThresholds ? parameters.firstTokenLogProbThreshold : nil,
            noSpeechThreshold: useQualityThresholds ? parameters.noSpeechThreshold : nil,
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
