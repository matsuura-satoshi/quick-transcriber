import XCTest
@testable import MyTranscriberLib

final class CompositeParameterTests: BenchmarkTestBase {

    override var outputPath: String { "/tmp/mytranscriber_composite_results.json" }

    // MARK: - Preset parameter sets

    static let speedKing = TranscriptionParameters(
        requiredSegmentsForConfirmation: 1,
        silenceThreshold: 0.5,
        compressionCheckWindow: 20,
        useVAD: true,
        temperature: 0.0,
        temperatureFallbackCount: 0,
        noSpeechThreshold: 0.4,
        concurrentWorkerCount: 4,
        compressionRatioThreshold: 2.4,
        logProbThreshold: -1.0,
        firstTokenLogProbThreshold: -1.5,
        sampleLength: 128,
        windowClipTime: 1.0
    )

    static let balanced = TranscriptionParameters(
        requiredSegmentsForConfirmation: 1,
        silenceThreshold: 0.5,
        compressionCheckWindow: 20,
        useVAD: true,
        temperature: 0.0,
        temperatureFallbackCount: 1,
        noSpeechThreshold: 0.4,
        concurrentWorkerCount: 8,
        compressionRatioThreshold: 2.4,
        logProbThreshold: -1.0,
        firstTokenLogProbThreshold: -1.5,
        sampleLength: 224,
        windowClipTime: 1.0
    )

    static let accuracyFirst = TranscriptionParameters(
        requiredSegmentsForConfirmation: 2,
        silenceThreshold: 0.3,
        compressionCheckWindow: 20,
        useVAD: true,
        temperature: 0.0,
        temperatureFallbackCount: 3,
        noSpeechThreshold: 0.3,
        concurrentWorkerCount: 16,
        compressionRatioThreshold: 2.4,
        logProbThreshold: -1.0,
        firstTokenLogProbThreshold: -1.5,
        sampleLength: 224,
        windowClipTime: 1.0
    )

    static let tvMedia = TranscriptionParameters(
        requiredSegmentsForConfirmation: 1,
        silenceThreshold: 0.5,
        compressionCheckWindow: 20,
        useVAD: true,
        temperature: 0.0,
        temperatureFallbackCount: 0,
        noSpeechThreshold: 0.5,
        concurrentWorkerCount: 4,
        compressionRatioThreshold: 2.0,
        logProbThreshold: -1.0,
        firstTokenLogProbThreshold: -1.5,
        sampleLength: 128,
        windowClipTime: 1.0
    )

    // MARK: - English tests

    func testSpeedKing_enMedium() async throws {
        _ = try await runBenchmark(fixture: "en_medium", parameters: Self.speedKing)
    }

    func testBalanced_enMedium() async throws {
        _ = try await runBenchmark(fixture: "en_medium", parameters: Self.balanced)
    }

    func testAccuracyFirst_enMedium() async throws {
        _ = try await runBenchmark(fixture: "en_medium", parameters: Self.accuracyFirst)
    }

    func testTVMedia_enMedium() async throws {
        _ = try await runBenchmark(fixture: "en_medium", parameters: Self.tvMedia)
    }

    // MARK: - Japanese tests

    func testSpeedKing_jaMedium() async throws {
        _ = try await runBenchmark(fixture: "ja_medium", parameters: Self.speedKing)
    }

    func testBalanced_jaMedium() async throws {
        _ = try await runBenchmark(fixture: "ja_medium", parameters: Self.balanced)
    }

    func testAccuracyFirst_jaMedium() async throws {
        _ = try await runBenchmark(fixture: "ja_medium", parameters: Self.accuracyFirst)
    }

    func testTVMedia_jaMedium() async throws {
        _ = try await runBenchmark(fixture: "ja_medium", parameters: Self.tvMedia)
    }

    // MARK: - Pause handling

    func testSpeedKing_enPauses() async throws {
        _ = try await runBenchmark(fixture: "en_pauses", parameters: Self.speedKing)
    }

    func testTVMedia_enPauses() async throws {
        _ = try await runBenchmark(fixture: "en_pauses", parameters: Self.tvMedia)
    }
}
