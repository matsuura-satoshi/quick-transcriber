import Foundation
import WhisperKit
@testable import MyTranscriberLib

struct BenchmarkResult: Codable {
    let fixture: String
    let label: String
    let language: String
    let parameters: TranscriptionParameters
    let transcribedText: String
    let referenceText: String
    let wer: Double
    let audioDurationSeconds: Double
    let inferenceTimeSeconds: Double
    let realtimeFactor: Double
    let peakMemoryMB: Double
}

struct AudioReference: Codable {
    let language: String
    let text: String
    let duration_seconds: Double
}

final class BenchmarkRunner {

    private let whisperKit: WhisperKit

    init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
    }

    func run(
        audioPath: String,
        language: String,
        parameters: TranscriptionParameters,
        referenceText: String,
        audioDuration: Double,
        label: String = ""
    ) async throws -> BenchmarkResult {
        let decodingOptions = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: parameters.temperature,
            temperatureFallbackCount: parameters.temperatureFallbackCount,
            sampleLength: parameters.sampleLength,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.4,
            concurrentWorkerCount: parameters.concurrentWorkerCount,
            chunkingStrategy: .vad
        )

        let memBefore = Self.currentMemoryMB()
        let startTime = CFAbsoluteTimeGetCurrent()

        let results = try await whisperKit.transcribe(
            audioPath: audioPath,
            decodeOptions: decodingOptions
        )

        let inferenceTime = CFAbsoluteTimeGetCurrent() - startTime
        let memAfter = Self.currentMemoryMB()

        let transcribedText = results
            .flatMap { $0.segments }
            .map { TranscriptionUtils.cleanSegmentText($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let wer = Self.calculateWER(reference: referenceText, hypothesis: transcribedText)
        let fixture = URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent

        return BenchmarkResult(
            fixture: fixture,
            label: label,
            language: language,
            parameters: parameters,
            transcribedText: transcribedText,
            referenceText: referenceText,
            wer: wer,
            audioDurationSeconds: audioDuration,
            inferenceTimeSeconds: inferenceTime,
            realtimeFactor: inferenceTime / audioDuration,
            peakMemoryMB: max(memAfter, memBefore)
        )
    }

    // MARK: - WER Calculation (Levenshtein distance based)

    static func calculateWER(reference: String, hypothesis: String) -> Double {
        let refWords = tokenize(reference)
        let hypWords = tokenize(hypothesis)

        guard !refWords.isEmpty else {
            return hypWords.isEmpty ? 0.0 : 1.0
        }

        let n = refWords.count
        let m = hypWords.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)

        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }

        for i in 1...n {
            for j in 1...m {
                if refWords[i - 1] == hypWords[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
                }
            }
        }

        return Double(dp[n][m]) / Double(n)
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .flatMap { $0.components(separatedBy: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Memory measurement

    static func currentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    // MARK: - Result output

    static func appendResult(_ result: BenchmarkResult, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        var existing: [BenchmarkResult] = []
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([BenchmarkResult].self, from: data) {
            existing = decoded
        }
        existing.append(result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(existing)
        try data.write(to: url)
        NSLog("[Benchmark] Results written to: \(path) (\(existing.count) total)")
    }
}
