import XCTest
@testable import MyTranscriberLib

final class CompositeParameterTests: BenchmarkTestBase {

    override var outputPath: String { "/tmp/mytranscriber_composite_results.json" }

    // MARK: - Preset parameter sets

    static let speedKing = TranscriptionParameters(
        temperature: 0.0,
        temperatureFallbackCount: 0,
        sampleLength: 128,
        concurrentWorkerCount: 4
    )

    static let balanced = TranscriptionParameters(
        temperature: 0.0,
        temperatureFallbackCount: 1,
        sampleLength: 224,
        concurrentWorkerCount: 8
    )

    static let accuracyFirst = TranscriptionParameters(
        temperature: 0.0,
        temperatureFallbackCount: 3,
        sampleLength: 224,
        concurrentWorkerCount: 16
    )

    static let tvMedia = TranscriptionParameters(
        temperature: 0.0,
        temperatureFallbackCount: 0,
        sampleLength: 128,
        concurrentWorkerCount: 4
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
