import XCTest
@testable import MyTranscriberLib

final class RealWorldBenchmarkTests: BenchmarkTestBase {

    private static let testAudioDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/MyTranscriber/test-audio")

    override var outputPath: String { "/tmp/mytranscriber_realworld_results.json" }

    func testRealWorldAudio() async throws {
        let fm = FileManager.default
        let dir = Self.testAudioDir

        guard fm.fileExists(atPath: dir.path) else {
            throw XCTSkip("Real-world test audio directory not found at \(dir.path). Place WAV files and corresponding .txt files there to run these tests.")
        }

        let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let wavFiles = contents.filter { $0.pathExtension.lowercased() == "wav" }

        guard !wavFiles.isEmpty else {
            throw XCTSkip("No WAV files found in \(dir.path)")
        }

        var count = 0
        for wavFile in wavFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = wavFile.deletingPathExtension().lastPathComponent
            let language = name.hasPrefix("ja_") ? "ja" : "en"

            // Load reference text if available
            let txtFile = wavFile.deletingPathExtension().appendingPathExtension("txt")
            let referenceText: String
            if fm.fileExists(atPath: txtFile.path) {
                referenceText = (try? String(contentsOf: txtFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } else {
                referenceText = ""
            }

            // Estimate audio duration from file size (16kHz, 16-bit mono = 32000 bytes/sec)
            let attrs = try fm.attributesOfItem(atPath: wavFile.path)
            let fileSize = (attrs[.size] as? Int) ?? 0
            let estimatedDuration = Double(fileSize) / 32000.0

            NSLog("[RealWorld] Testing: \(name) (lang=\(language), ref=\(referenceText.isEmpty ? "none" : "\(referenceText.count) chars"))")

            let result = try await runner.run(
                audioPath: wavFile.path,
                language: language,
                parameters: .default,
                referenceText: referenceText,
                audioDuration: estimatedDuration,
                label: "realworld/\(name)"
            )

            try? BenchmarkRunner.appendResult(result, to: outputPath)
            count += 1

            NSLog("[RealWorld] \(name) | WER: \(String(format: "%.2f", result.wer)) | RTF: \(String(format: "%.2f", result.realtimeFactor)) | Time: \(String(format: "%.1f", result.inferenceTimeSeconds))s")
            NSLog("[RealWorld] Transcribed: \(result.transcribedText.prefix(200))")

            if !referenceText.isEmpty {
                XCTAssertLessThan(result.wer, 1.0, "WER too high for \(name)")
            }
        }

        NSLog("[RealWorld] Completed \(count) tests")
    }
}
