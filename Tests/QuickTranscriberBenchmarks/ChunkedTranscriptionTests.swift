import XCTest
import AVFoundation
import WhisperKit
@testable import QuickTranscriberLib

/// Compares VAD-driven chunking vs fixed-duration chunking across multiple datasets.
/// Each test runs the same audio through both modes and outputs paired results.
final class ChunkedTranscriptionTests: BenchmarkTestBase {

    private var chunkedRunner: ChunkedTranscriptionBenchmarkRunner!
    private let chunkedOutputPath = "/tmp/quicktranscriber_chunked_comparison.json"

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
            throw NSError(domain: "ChunkedTranscription", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "ChunkedTranscription", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create buffer"])
        }
        try audioFile.read(into: buffer)
        return Array(UnsafeBufferPointer(
            start: buffer.floatChannelData![0],
            count: Int(buffer.frameLength)
        ))
    }

    // MARK: - Core comparison runner

    private func runComparison(
        dataset: String,
        maxSamples: Int = 50,
        skipKeys: Set<String> = [],
        language: String? = nil
    ) async throws -> (vadWER: Double, fixedWER: Double, count: Int) {
        let refs = try loadDatasetReferences(name: dataset)
        let dir = datasetDir(name: dataset)

        let keys = Array(refs.keys.sorted().prefix(maxSamples))
        guard !keys.isEmpty else {
            throw XCTSkip("No samples in dataset \(dataset)")
        }

        var vadTotalWER = 0.0
        var fixedTotalWER = 0.0
        var count = 0

        for key in keys {
            guard let ref = refs[key] else { continue }
            guard ref.duration_seconds >= 1.0 else { continue }
            if skipKeys.contains(key) { continue }

            let wavPath = dir.appendingPathComponent("\(key).wav").path
            guard FileManager.default.fileExists(atPath: wavPath) else { continue }

            let samples = try loadAudioSamples(from: wavPath)
            let lang = language ?? ref.language

            // VAD mode
            let vadResult = try await chunkedRunner.run(
                audioSamples: samples,
                language: lang,
                parameters: .default,
                referenceText: ref.text,
                audioDuration: ref.duration_seconds,
                fixture: key,
                mode: .vad,
                label: "\(dataset)/vad"
            )

            // Fixed mode
            let fixedResult = try await chunkedRunner.run(
                audioSamples: samples,
                language: lang,
                parameters: .default,
                referenceText: ref.text,
                audioDuration: ref.duration_seconds,
                fixture: key,
                mode: .fixed,
                label: "\(dataset)/fixed"
            )

            try? ChunkedBenchmarkResult.appendResult(vadResult, to: chunkedOutputPath)
            try? ChunkedBenchmarkResult.appendResult(fixedResult, to: chunkedOutputPath)

            vadTotalWER += vadResult.wer
            fixedTotalWER += fixedResult.wer
            count += 1

            NSLog("[Chunked] \(key) | VAD: WER=\(String(format: "%.3f", vadResult.wer)) chunks=\(vadResult.chunkCount) avgChunk=\(String(format: "%.1f", vadResult.avgChunkDurationSeconds))s | Fixed: WER=\(String(format: "%.3f", fixedResult.wer)) chunks=\(fixedResult.chunkCount) avgChunk=\(String(format: "%.1f", fixedResult.avgChunkDurationSeconds))s")
        }

        guard count > 0 else {
            throw XCTSkip("No processable samples in \(dataset)")
        }

        let vadAvgWER = vadTotalWER / Double(count)
        let fixedAvgWER = fixedTotalWER / Double(count)

        NSLog("[Chunked] === \(dataset) Summary ===")
        NSLog("[Chunked] Samples: \(count)")
        NSLog("[Chunked] VAD avgWER:   \(String(format: "%.4f", vadAvgWER))")
        NSLog("[Chunked] Fixed avgWER: \(String(format: "%.4f", fixedAvgWER))")
        NSLog("[Chunked] Delta (VAD-Fixed): \(String(format: "%+.4f", vadAvgWER - fixedAvgWER))")

        return (vadAvgWER, fixedAvgWER, count)
    }

    // MARK: - FLEURS English

    func testFLEURS_en_VADvsFixed() async throws {
        let (vadWER, fixedWER, count) = try await runComparison(
            dataset: "fleurs_en", maxSamples: 50
        )
        XCTAssertGreaterThan(count, 0)
        NSLog("[Chunked] FLEURS EN: VAD=\(String(format: "%.4f", vadWER)) Fixed=\(String(format: "%.4f", fixedWER))")
    }

    // MARK: - FLEURS Japanese

    func testFLEURS_ja_VADvsFixed() async throws {
        let knownBadKeys: Set<String> = ["ja_0023"]
        let (vadWER, fixedWER, count) = try await runComparison(
            dataset: "fleurs_ja", maxSamples: 50, skipKeys: knownBadKeys
        )
        XCTAssertGreaterThan(count, 0)
        NSLog("[Chunked] FLEURS JA: VAD=\(String(format: "%.4f", vadWER)) Fixed=\(String(format: "%.4f", fixedWER))")
    }

    // MARK: - LibriSpeech test-other (noisy English)

    func testLibriSpeech_VADvsFixed() async throws {
        let knownBadKeys: Set<String> = ["en_0047"]
        let (vadWER, fixedWER, count) = try await runComparison(
            dataset: "librispeech_test_other", maxSamples: 50, skipKeys: knownBadKeys
        )
        XCTAssertGreaterThan(count, 0)
        NSLog("[Chunked] LibriSpeech: VAD=\(String(format: "%.4f", vadWER)) Fixed=\(String(format: "%.4f", fixedWER))")
    }

    // MARK: - ReazonSpeech (noisy Japanese TV)

    func testReazonSpeech_VADvsFixed() async throws {
        let (vadWER, fixedWER, count) = try await runComparison(
            dataset: "reazonspeech_test", maxSamples: 50
        )
        XCTAssertGreaterThan(count, 0)
        NSLog("[Chunked] ReazonSpeech: VAD=\(String(format: "%.4f", vadWER)) Fixed=\(String(format: "%.4f", fixedWER))")
    }
}
