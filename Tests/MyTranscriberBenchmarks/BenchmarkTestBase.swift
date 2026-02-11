import XCTest
import WhisperKit
@testable import MyTranscriberLib

class BenchmarkTestBase: XCTestCase {

    static var sharedWhisperKit: WhisperKit?
    static var references: [String: AudioReference] = [:]

    var runner: BenchmarkRunner!

    override class func setUp() {
        super.setUp()

        // Load references.json
        if let url = Bundle.module.url(forResource: "references", withExtension: "json", subdirectory: "Resources"),
           let data = try? Data(contentsOf: url),
           let refs = try? JSONDecoder().decode([String: AudioReference].self, from: data) {
            references = refs
        } else {
            NSLog("[Benchmark] WARNING: Could not load references.json")
        }
    }

    override func setUp() async throws {
        try await super.setUp()

        // Initialize WhisperKit once, reuse across tests
        if Self.sharedWhisperKit == nil {
            let modelName = "large-v3-v20240930_turbo"
            let modelFolder = findModelFolder(for: modelName)
            guard let modelFolder else {
                throw XCTSkip("Model not found locally. Run the app first to download.")
            }

            let computeOptions = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU,
                prefillCompute: .cpuAndGPU
            )

            Self.sharedWhisperKit = try await WhisperKit(
                modelFolder: modelFolder,
                computeOptions: computeOptions,
                verbose: false,
                logLevel: .error,
                load: true,
                download: false
            )
        }

        runner = BenchmarkRunner(whisperKit: Self.sharedWhisperKit!)
    }

    func audioPath(for fixture: String) -> String? {
        Bundle.module.url(forResource: fixture, withExtension: "wav", subdirectory: "Resources")?.path
    }

    /// Override in subclass to specify output path
    var outputPath: String { "/tmp/mytranscriber_benchmark_results.json" }

    func runBenchmark(
        fixture: String,
        parameters: TranscriptionParameters = .default,
        label: String = ""
    ) async throws -> BenchmarkResult {
        guard let path = audioPath(for: fixture) else {
            throw XCTSkip("Audio fixture \(fixture) not found")
        }
        guard let ref = Self.references[fixture] else {
            throw XCTSkip("Reference for \(fixture) not found")
        }

        let result = try await runner.run(
            audioPath: path,
            language: ref.language,
            parameters: parameters,
            referenceText: ref.text,
            audioDuration: ref.duration_seconds,
            label: label.isEmpty ? fixture : label
        )

        NSLog("[Benchmark] \(fixture) | WER: \(String(format: "%.2f", result.wer)) | RTF: \(String(format: "%.2f", result.realtimeFactor)) | Time: \(String(format: "%.1f", result.inferenceTimeSeconds))s | Mem: \(String(format: "%.0f", result.peakMemoryMB))MB")
        NSLog("[Benchmark] Transcribed: \(result.transcribedText.prefix(100))")

        try? BenchmarkRunner.appendResult(result, to: outputPath)

        return result
    }

    private func findModelFolder(for model: String) -> String? {
        let modelDirName = "openai_whisper-\(model)"
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        let searchPaths = [
            appSupport.appendingPathComponent("MyTranscriber/Models/\(modelDirName)"),
            homeDir.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml/\(modelDirName)"),
        ]

        for path in searchPaths {
            if fm.fileExists(atPath: path.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                return path.path
            }
        }
        return nil
    }
}
