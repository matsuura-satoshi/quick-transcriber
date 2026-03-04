import Foundation
import WhisperKit
@testable import QuickTranscriberLib

// MARK: - Result Types

struct ChunkedBenchmarkResult: Codable {
    let fixture: String
    let label: String
    let language: String
    let wer: Double
    let audioDurationSeconds: Double
    let totalInferenceSeconds: Double
    let realtimeFactor: Double
    let chunkCount: Int
    let skippedChunkCount: Int
    let avgChunkDurationSeconds: Double
    let p50ChunkDurationSeconds: Double
    let p95ChunkDurationSeconds: Double
    let minChunkDurationSeconds: Double
    let maxChunkDurationSeconds: Double
    let firstChunkLatencySeconds: Double
    let transcribedText: String
    let referenceText: String
    let peakMemoryMB: Double

    static func appendResult(_ result: ChunkedBenchmarkResult, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        var existing: [ChunkedBenchmarkResult] = []
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([ChunkedBenchmarkResult].self, from: data) {
            existing = decoded
        }
        existing.append(result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(existing)
        try data.write(to: url)
    }
}

struct ChunkDurationStats {
    let avg: Double
    let p50: Double
    let p95: Double
    let min: Double
    let max: Double

    static func compute(from durations: [Double]) -> ChunkDurationStats {
        guard !durations.isEmpty else {
            return ChunkDurationStats(avg: 0, p50: 0, p95: 0, min: 0, max: 0)
        }
        let sorted = durations.sorted()
        let avg = sorted.reduce(0, +) / Double(sorted.count)
        let p50 = percentile(sorted, 0.50)
        let p95 = percentile(sorted, 0.95)
        return ChunkDurationStats(
            avg: avg, p50: p50, p95: p95,
            min: sorted.first!, max: sorted.last!
        )
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let index = p * Double(sorted.count - 1)
        let lower = Int(index)
        let upper = Swift.min(lower + 1, sorted.count - 1)
        let frac = index - Double(lower)
        return sorted[lower] + frac * (sorted[upper] - sorted[lower])
    }
}

// MARK: - Chunked Benchmark Runner

/// Simulates the streaming pipeline: feeds audio in 100ms increments to an accumulator,
/// transcribes each chunk with WhisperKit, and collects metrics.
final class ChunkedTranscriptionBenchmarkRunner {

    private let whisperKit: WhisperKit
    private let sampleRate: Double = 16000.0
    private let streamingIncrementDuration: TimeInterval = 0.1

    init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    enum ChunkingMode {
        case vad
        case fixed
    }

    /// Normalize audio peak to target level so VAD thresholds work with quiet dataset recordings.
    /// Both VAD and Fixed accumulators see the same normalized audio for fair comparison.
    /// WhisperKit also receives the normalized audio (it's amplitude-agnostic via mel spectrogram).
    static func normalizeAudio(_ samples: [Float], targetPeak: Float = 0.5) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let peak = samples.map { abs($0) }.max() ?? 0
        guard peak > 0 else { return samples }
        let scale = targetPeak / peak
        return samples.map { $0 * scale }
    }

    func run(
        audioSamples: [Float],
        language: String,
        parameters: TranscriptionParameters,
        referenceText: String,
        audioDuration: Double,
        fixture: String,
        mode: ChunkingMode,
        label: String
    ) async throws -> ChunkedBenchmarkResult {
        let incrementSize = Int(streamingIncrementDuration * sampleRate)
        let memBefore = BenchmarkRunner.currentMemoryMB()
        let overallStart = CFAbsoluteTimeGetCurrent()

        // Normalize audio to simulate real microphone levels.
        // Dataset recordings are much quieter than live mic input;
        // without normalization, VAD onset threshold (0.02) is never reached.
        let normalizedSamples = Self.normalizeAudio(audioSamples, targetPeak: 0.5)

        // Set up accumulator
        var vadAccumulator = VADChunkAccumulator()
        var fixedAccumulator = FixedChunkSimulator()

        // Collect chunks
        var chunks: [(samples: [Float], emitTime: CFAbsoluteTime)] = []
        var skippedCount = 0

        var offset = 0
        while offset < normalizedSamples.count {
            let end = min(offset + incrementSize, normalizedSamples.count)
            let slice = Array(normalizedSamples[offset..<end])

            let chunkResult: ChunkResult?
            switch mode {
            case .vad:
                chunkResult = vadAccumulator.appendBuffer(slice)
            case .fixed:
                chunkResult = fixedAccumulator.appendBuffer(slice)
            }

            if let chunk = chunkResult {
                let now = CFAbsoluteTimeGetCurrent()
                // Engine-side skip for fixed mode
                if mode == .fixed && fixedAccumulator.shouldSkip(chunk) {
                    skippedCount += 1
                } else {
                    chunks.append((samples: chunk.samples, emitTime: now))
                }
            }
            offset = end
        }

        // Flush remaining
        let flushResult: ChunkResult?
        switch mode {
        case .vad:
            flushResult = vadAccumulator.flush()
        case .fixed:
            flushResult = fixedAccumulator.flush()
        }
        if let chunk = flushResult {
            let now = CFAbsoluteTimeGetCurrent()
            if mode == .fixed && fixedAccumulator.shouldSkip(chunk) {
                skippedCount += 1
            } else {
                chunks.append((samples: chunk.samples, emitTime: now))
            }
        }

        // Transcribe each chunk
        var allText: [String] = []
        var totalInference: TimeInterval = 0
        var chunkDurations: [Double] = []

        let decodingOptions = DecodingOptions(
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

        for chunk in chunks {
            let chunkDuration = TimeInterval(chunk.samples.count) / sampleRate
            chunkDurations.append(chunkDuration)
            let inferenceStart = CFAbsoluteTimeGetCurrent()
            let results = try await whisperKit.transcribe(
                audioArray: chunk.samples,
                decodeOptions: decodingOptions
            )
            let inferenceTime = CFAbsoluteTimeGetCurrent() - inferenceStart
            totalInference += inferenceTime

            let segments = results.flatMap { $0.segments }
            for segment in segments {
                let cleaned = TranscriptionUtils.cleanSegmentText(segment.text)
                guard !cleaned.isEmpty else { continue }

                let transcribed = TranscribedSegment(
                    text: cleaned,
                    avgLogprob: segment.avgLogprob,
                    compressionRatio: segment.compressionRatio,
                    noSpeechProb: segment.noSpeechProb
                )

                // Quality filters
                if TranscriptionUtils.shouldFilterByMetadata(transcribed) { continue }
                if TranscriptionUtils.shouldFilterSegment(cleaned, language: language) { continue }

                allText.append(cleaned)
            }
        }

        let memAfter = BenchmarkRunner.currentMemoryMB()
        let transcribedText = allText.joined(separator: " ")
        let wer = BenchmarkRunner.calculateWER(reference: referenceText, hypothesis: transcribedText)
        let stats = ChunkDurationStats.compute(from: chunkDurations)

        let firstChunkLatency: Double
        if let firstChunk = chunks.first {
            firstChunkLatency = firstChunk.emitTime - overallStart
        } else {
            firstChunkLatency = 0
        }

        return ChunkedBenchmarkResult(
            fixture: fixture,
            label: label,
            language: language,
            wer: wer,
            audioDurationSeconds: audioDuration,
            totalInferenceSeconds: totalInference,
            realtimeFactor: totalInference / max(audioDuration, 0.001),
            chunkCount: chunks.count,
            skippedChunkCount: skippedCount,
            avgChunkDurationSeconds: stats.avg,
            p50ChunkDurationSeconds: stats.p50,
            p95ChunkDurationSeconds: stats.p95,
            minChunkDurationSeconds: stats.min,
            maxChunkDurationSeconds: stats.max,
            firstChunkLatencySeconds: firstChunkLatency,
            transcribedText: transcribedText,
            referenceText: referenceText,
            peakMemoryMB: max(memBefore, memAfter)
        )
    }
}
