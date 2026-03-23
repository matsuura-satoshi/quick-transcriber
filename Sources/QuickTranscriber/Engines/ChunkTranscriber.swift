import Foundation
import WhisperKit

/// A segment from file transcription with timestamp information.
public struct FileTranscriptionSegment: Sendable {
    public let text: String
    public let start: Float
    public let end: Float
    public let avgLogprob: Float
    public let compressionRatio: Float
    public let noSpeechProb: Float
}

/// Protocol for transcribing a chunk of audio.
/// Abstracts WhisperKit.transcribe(audioArray:) for testability.
public protocol ChunkTranscriber: AnyObject {
    func setup(model: String) async throws
    func transcribe(audioArray: [Float], language: String, parameters: TranscriptionParameters) async throws -> [TranscribedSegment]
    /// Transcribe an audio file using WhisperKit's optimal file processing pipeline.
    /// Uses full 30s windows, VAD chunking, quality thresholds, and timestamps.
    func transcribeFile(audioPath: String, language: String, onProgress: (@Sendable (Double) -> Void)?) async throws -> [FileTranscriptionSegment]
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

    public func transcribeFile(
        audioPath: String,
        language: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [FileTranscriptionSegment] {
        guard let whisperKit else {
            throw TranscriptionEngineError.notInitialized
        }

        // Accuracy-optimized options: use WhisperKit defaults for quality thresholds,
        // enable VAD chunking for optimal 30s window utilization, enable timestamps.
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 1,
            chunkingStrategy: .vad
        )

        let progressCallback: TranscriptionCallback = onProgress != nil ? { progress in
            // windowId increments per 30s chunk; approximate progress
            onProgress?(Double(progress.windowId + 1) * 0.1) // rough estimate, capped by caller
            return nil // continue transcription
        } : nil

        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioPath: audioPath,
            decodeOptions: options,
            callback: progressCallback
        )

        return results.flatMap { result in
            result.segments.compactMap { segment -> FileTranscriptionSegment? in
                let cleanedText = TranscriptionUtils.cleanSegmentText(segment.text)
                guard !cleanedText.isEmpty else { return nil }
                return FileTranscriptionSegment(
                    text: cleanedText,
                    start: segment.start,
                    end: segment.end,
                    avgLogprob: segment.avgLogprob,
                    compressionRatio: segment.compressionRatio,
                    noSpeechProb: segment.noSpeechProb
                )
            }
        }
    }
}
