import XCTest
@testable import QuickTranscriberLib

final class BaselineBenchmarkTests: BenchmarkTestBase {

    override var outputPath: String { "/tmp/quicktranscriber_baseline_results.json" }

    func testBaseline_enShort() async throws {
        let result = try await runBenchmark(fixture: "en_short")
        XCTAssertLessThan(result.wer, 0.5, "WER too high for en_short")
    }

    func testBaseline_enMedium() async throws {
        let result = try await runBenchmark(fixture: "en_medium")
        XCTAssertLessThan(result.wer, 0.5, "WER too high for en_medium")
    }

    func testBaseline_enPauses() async throws {
        let result = try await runBenchmark(fixture: "en_pauses")
        XCTAssertLessThan(result.wer, 0.5, "WER too high for en_pauses")
    }

    func testBaseline_jaShort() async throws {
        let result = try await runBenchmark(fixture: "ja_short")
        XCTAssertLessThan(result.wer, 1.0, "WER too high for ja_short")
    }

    func testBaseline_jaMedium() async throws {
        let result = try await runBenchmark(fixture: "ja_medium")
        XCTAssertLessThan(result.wer, 1.0, "WER too high for ja_medium")
    }
}
