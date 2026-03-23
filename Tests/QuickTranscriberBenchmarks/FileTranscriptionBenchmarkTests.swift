import XCTest
import AVFoundation
import WhisperKit
@testable import QuickTranscriberLib

/// Compares real-time VAD parameters vs file-optimized parameters across multiple datasets.
/// Tests the effect of larger chunks, quality thresholds, and temperature fallback.
final class FileTranscriptionBenchmarkTests: BenchmarkTestBase {

    private var chunkedRunner: ChunkedTranscriptionBenchmarkRunner!
    private let outputPath_ = "/tmp/quicktranscriber_file_vs_realtime.json"

    override func setUp() async throws {
        try await super.setUp()
        chunkedRunner = ChunkedTranscriptionBenchmarkRunner(whisperKit: Self.sharedWhisperKit!)
    }

    // MARK: - Dataset helpers

    private func datasetDir(name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/QuickTranscriber/test-audio/\(name)")
    }

    private func loadDatasetReferences(name: String) throws -> [String: DatasetBenchmarkTestBase.DatasetReference] {
        let dir = datasetDir(name: name)
        let refsURL = dir.appendingPathComponent("references.json")
        guard FileManager.default.fileExists(atPath: refsURL.path) else {
            throw XCTSkip("Dataset \(name) not found. Run Scripts/download_datasets.py first.")
        }
        let data = try Data(contentsOf: refsURL)
        return try JSONDecoder().decode([String: DatasetBenchmarkTestBase.DatasetReference].self, from: data)
    }

    private func loadAudioSamples(from path: String) throws -> [Float] {
        let audioURL = URL(fileURLWithPath: path)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "FileTranscriptionBenchmark", code: 1)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "FileTranscriptionBenchmark", code: 2)
        }
        try audioFile.read(into: buffer)
        return Array(UnsafeBufferPointer(
            start: buffer.floatChannelData![0],
            count: Int(buffer.frameLength)
        ))
    }

    // MARK: - Parameter configurations

    /// Real-time defaults (baseline)
    private var realtimeParams: TranscriptionParameters {
        .default
    }

    /// File-optimized: larger chunks + quality thresholds + temperature fallback
    private var fileParams: TranscriptionParameters {
        var p = TranscriptionParameters.default
        p.chunkDuration = Constants.FileTranscription.chunkDuration           // 25.0
        p.silenceCutoffDuration = Constants.FileTranscription.endOfUtteranceSilence  // 1.0
        p.temperatureFallbackCount = Constants.FileTranscription.temperatureFallbackCount // 2
        p.concurrentWorkerCount = 1
        p.compressionRatioThreshold = 2.4
        p.logProbThreshold = -1.0
        p.firstTokenLogProbThreshold = -1.5
        p.noSpeechThreshold = 0.6
        p.suppressBlank = true
        p.qualityThresholdMinChunkDuration = Constants.FileTranscription.qualityThresholdMinChunkDuration
        return p
    }

    /// File-optimized without quality thresholds (isolate chunk size effect)
    private var fileParamsNoThresholds: TranscriptionParameters {
        var p = TranscriptionParameters.default
        p.chunkDuration = Constants.FileTranscription.chunkDuration           // 25.0
        p.silenceCutoffDuration = Constants.FileTranscription.endOfUtteranceSilence  // 1.0
        p.temperatureFallbackCount = Constants.FileTranscription.temperatureFallbackCount // 2
        p.concurrentWorkerCount = 1
        return p
    }

    // MARK: - Core comparison runner

    private func runFileVsRealtime(
        dataset: String,
        maxSamples: Int = 50,
        skipKeys: Set<String> = [],
        language: String? = nil
    ) async throws {
        let refs = try loadDatasetReferences(name: dataset)
        let dir = datasetDir(name: dataset)

        let keys = Array(refs.keys.sorted().prefix(maxSamples))
        guard !keys.isEmpty else {
            throw XCTSkip("No samples in dataset \(dataset)")
        }

        var realtimeTotalWER = 0.0
        var fileTotalWER = 0.0
        var fileNoThreshTotalWER = 0.0
        var count = 0

        let configs: [(label: String, params: TranscriptionParameters)] = [
            ("realtime", realtimeParams),
            ("file", fileParams),
            ("file_no_thresh", fileParamsNoThresholds),
        ]

        for key in keys {
            guard let ref = refs[key] else { continue }
            guard ref.duration_seconds >= 1.0 else { continue }
            if skipKeys.contains(key) { continue }

            let wavPath = dir.appendingPathComponent("\(key).wav").path
            guard FileManager.default.fileExists(atPath: wavPath) else { continue }

            let samples = try loadAudioSamples(from: wavPath)
            let lang = language ?? ref.language

            var wers: [String: Double] = [:]
            for config in configs {
                let result = try await chunkedRunner.run(
                    audioSamples: samples,
                    language: lang,
                    parameters: config.params,
                    referenceText: ref.text,
                    audioDuration: ref.duration_seconds,
                    fixture: key,
                    mode: .vad,
                    label: "\(dataset)/\(config.label)"
                )
                try? ChunkedBenchmarkResult.appendResult(result, to: outputPath_)
                wers[config.label] = result.wer

                NSLog("[FileBench] \(key)/\(config.label) | WER=\(String(format: "%.3f", result.wer)) chunks=\(result.chunkCount) avgChunk=\(String(format: "%.1f", result.avgChunkDurationSeconds))s")
            }

            realtimeTotalWER += wers["realtime"] ?? 0
            fileTotalWER += wers["file"] ?? 0
            fileNoThreshTotalWER += wers["file_no_thresh"] ?? 0
            count += 1
        }

        guard count > 0 else {
            throw XCTSkip("No processable samples in \(dataset)")
        }

        let realtimeAvg = realtimeTotalWER / Double(count)
        let fileAvg = fileTotalWER / Double(count)
        let fileNoThreshAvg = fileNoThreshTotalWER / Double(count)

        NSLog("[FileBench] === \(dataset) Summary (\(count) samples) ===")
        NSLog("[FileBench] Realtime (8s, no thresh):    WER=\(String(format: "%.4f", realtimeAvg))")
        NSLog("[FileBench] File (25s, thresholds):      WER=\(String(format: "%.4f", fileAvg)) Δ=\(String(format: "%+.4f", fileAvg - realtimeAvg))")
        NSLog("[FileBench] File (25s, no thresh):       WER=\(String(format: "%.4f", fileNoThreshAvg)) Δ=\(String(format: "%+.4f", fileNoThreshAvg - realtimeAvg))")
    }

    // MARK: - FLEURS English

    func testFLEURS_en_FileVsRealtime() async throws {
        try await runFileVsRealtime(dataset: "fleurs_en", maxSamples: 50)
    }

    // MARK: - FLEURS Japanese

    func testFLEURS_ja_FileVsRealtime() async throws {
        let knownBadKeys: Set<String> = ["ja_0023"]
        try await runFileVsRealtime(dataset: "fleurs_ja", maxSamples: 50, skipKeys: knownBadKeys)
    }

    // MARK: - LibriSpeech test-other

    func testLibriSpeech_FileVsRealtime() async throws {
        let knownBadKeys: Set<String> = ["en_0047"]
        try await runFileVsRealtime(dataset: "librispeech_test_other", maxSamples: 50, skipKeys: knownBadKeys)
    }

    // MARK: - ReazonSpeech

    func testReazonSpeech_FileVsRealtime() async throws {
        try await runFileVsRealtime(dataset: "reazonspeech_test", maxSamples: 50)
    }
}
