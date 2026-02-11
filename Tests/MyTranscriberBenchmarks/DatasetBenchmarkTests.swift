import XCTest
import WhisperKit
@testable import MyTranscriberLib

/// Base class for dataset-based benchmarks.
/// Reads WAV + references.json from ~/Documents/MyTranscriber/test-audio/<dataset>/
class DatasetBenchmarkTestBase: BenchmarkTestBase {

    struct DatasetReference: Codable {
        let language: String
        let text: String
        let duration_seconds: Double
    }

    func datasetDir(name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MyTranscriber/test-audio/\(name)")
    }

    func loadDatasetReferences(name: String) throws -> [String: DatasetReference] {
        let dir = datasetDir(name: name)
        let refsURL = dir.appendingPathComponent("references.json")
        guard FileManager.default.fileExists(atPath: refsURL.path) else {
            throw XCTSkip("Dataset \(name) not found at \(dir.path). Run Scripts/download_datasets.py first.")
        }
        let data = try Data(contentsOf: refsURL)
        return try JSONDecoder().decode([String: DatasetReference].self, from: data)
    }

    func runDatasetBenchmark(
        dataset: String,
        maxSamples: Int = 50,
        sampleOffset: Int = 0,
        skipKeys: Set<String> = [],
        parameters: TranscriptionParameters = .default,
        label: String = ""
    ) async throws -> (averageWER: Double, averageRTF: Double, count: Int) {
        let refs = try loadDatasetReferences(name: dataset)
        let dir = datasetDir(name: dataset)

        // Sort keys for reproducibility, apply offset and take subset
        let allKeys = refs.keys.sorted()
        let keys = Array(allKeys.dropFirst(sampleOffset).prefix(maxSamples))
        guard !keys.isEmpty else {
            throw XCTSkip("No samples in dataset \(dataset)")
        }

        var totalWER = 0.0
        var totalRTF = 0.0
        var count = 0

        for key in keys {
            guard let ref = refs[key] else { continue }
            // Skip very short audio (< 1s) to avoid WhisperKit internal errors
            guard ref.duration_seconds >= 1.0 else {
                NSLog("[Dataset] Skipping \(key): too short (\(ref.duration_seconds)s)")
                continue
            }
            // Skip known problematic samples
            if skipKeys.contains(key) {
                NSLog("[Dataset] Skipping \(key): in skipKeys")
                continue
            }
            let wavPath = dir.appendingPathComponent("\(key).wav").path
            guard FileManager.default.fileExists(atPath: wavPath) else { continue }

            let result = try await runner.run(
                audioPath: wavPath,
                language: ref.language,
                parameters: parameters,
                referenceText: ref.text,
                audioDuration: ref.duration_seconds,
                label: "\(dataset)/\(label.isEmpty ? "default" : label)"
            )

            try? BenchmarkRunner.appendResult(result, to: outputPath)
            totalWER += result.wer
            totalRTF += result.realtimeFactor
            count += 1
        }

        let avgWER = count > 0 ? totalWER / Double(count) : 0
        let avgRTF = count > 0 ? totalRTF / Double(count) : 0
        let tag = label.isEmpty ? dataset : "\(dataset)/\(label)"
        NSLog("[Dataset] \(tag) | samples=\(count) | avgWER=\(String(format: "%.3f", avgWER)) | avgRTF=\(String(format: "%.3f", avgRTF))")

        return (avgWER, avgRTF, count)
    }
}

// MARK: - Minimal: FLEURS

final class FLEURSBenchmarkTests: DatasetBenchmarkTestBase {

    override var outputPath: String { "/tmp/mytranscriber_fleurs_results.json" }

    // Samples that cause WhisperKit fatalError
    private let knownBadJaKeys: Set<String> = ["ja_0023"]

    func testFLEURS_en_default() async throws {
        let (wer, _, count) = try await runDatasetBenchmark(
            dataset: "fleurs_en", maxSamples: 50, label: "default"
        )
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(wer, 0.5, "Average WER too high for FLEURS English")
    }

    func testFLEURS_ja_default() async throws {
        let (wer, _, count) = try await runDatasetBenchmark(
            dataset: "fleurs_ja", maxSamples: 50,
            skipKeys: knownBadJaKeys, label: "default"
        )
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(wer, 1.0, "Average WER too high for FLEURS Japanese")
    }
}

// MARK: - Standard: LibriSpeech test-other (noisy English)

final class LibriSpeechBenchmarkTests: DatasetBenchmarkTestBase {

    override var outputPath: String { "/tmp/mytranscriber_librispeech_results.json" }

    // Samples that cause WhisperKit fatalError (non-deterministic crash)
    private let knownBadKeys: Set<String> = ["en_0047"]

    func testLibriSpeech_default() async throws {
        let (wer, _, count) = try await runDatasetBenchmark(
            dataset: "librispeech_test_other", maxSamples: 50,
            skipKeys: knownBadKeys, label: "default"
        )
        XCTAssertGreaterThan(count, 0)
        NSLog("[LibriSpeech] Default params: avgWER=\(String(format: "%.3f", wer))")
    }

    func testLibriSpeech_speedKing() async throws {
        let (wer, _, _) = try await runDatasetBenchmark(
            dataset: "librispeech_test_other", maxSamples: 50,
            skipKeys: knownBadKeys,
            parameters: CompositeParameterTests.speedKing, label: "speedKing"
        )
        NSLog("[LibriSpeech] SpeedKing: avgWER=\(String(format: "%.3f", wer))")
    }

    func testLibriSpeech_tvMedia() async throws {
        let (wer, _, _) = try await runDatasetBenchmark(
            dataset: "librispeech_test_other", maxSamples: 50,
            skipKeys: knownBadKeys,
            parameters: CompositeParameterTests.tvMedia, label: "tvMedia"
        )
        NSLog("[LibriSpeech] TVMedia: avgWER=\(String(format: "%.3f", wer))")
    }

    func testLibriSpeech_accuracyFirst() async throws {
        let (wer, _, _) = try await runDatasetBenchmark(
            dataset: "librispeech_test_other", maxSamples: 50,
            skipKeys: knownBadKeys,
            parameters: CompositeParameterTests.accuracyFirst, label: "accuracyFirst"
        )
        NSLog("[LibriSpeech] AccuracyFirst: avgWER=\(String(format: "%.3f", wer))")
    }
}

// MARK: - Standard: ReazonSpeech (noisy Japanese TV broadcast)

final class ReazonSpeechBenchmarkTests: DatasetBenchmarkTestBase {

    override var outputPath: String { "/tmp/mytranscriber_reazonspeech_results.json" }

    func testReazonSpeech_default() async throws {
        let (wer, _, count) = try await runDatasetBenchmark(
            dataset: "reazonspeech_test", maxSamples: 50, label: "default"
        )
        XCTAssertGreaterThan(count, 0)
        NSLog("[ReazonSpeech] Default params: avgWER=\(String(format: "%.3f", wer))")
    }

    func testReazonSpeech_speedKing() async throws {
        let (wer, _, _) = try await runDatasetBenchmark(
            dataset: "reazonspeech_test", maxSamples: 50,
            parameters: CompositeParameterTests.speedKing, label: "speedKing"
        )
        NSLog("[ReazonSpeech] SpeedKing: avgWER=\(String(format: "%.3f", wer))")
    }

    func testReazonSpeech_tvMedia() async throws {
        let (wer, _, _) = try await runDatasetBenchmark(
            dataset: "reazonspeech_test", maxSamples: 50,
            parameters: CompositeParameterTests.tvMedia, label: "tvMedia"
        )
        NSLog("[ReazonSpeech] TVMedia: avgWER=\(String(format: "%.3f", wer))")
    }

    func testReazonSpeech_accuracyFirst() async throws {
        let (wer, _, _) = try await runDatasetBenchmark(
            dataset: "reazonspeech_test", maxSamples: 50,
            parameters: CompositeParameterTests.accuracyFirst, label: "accuracyFirst"
        )
        NSLog("[ReazonSpeech] AccuracyFirst: avgWER=\(String(format: "%.3f", wer))")
    }
}
