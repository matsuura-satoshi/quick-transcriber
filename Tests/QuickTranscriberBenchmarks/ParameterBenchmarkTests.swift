import XCTest
@testable import QuickTranscriberLib

final class ParameterBenchmarkTests: BenchmarkTestBase {

    override var outputPath: String { "/tmp/quicktranscriber_parameter_results.json" }
    private let testFixture = "en_medium"

    // MARK: - temperatureFallbackCount

    func testFallback_0() async throws {
        var params = TranscriptionParameters.default
        params.temperatureFallbackCount = 0
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testFallback_1() async throws {
        var params = TranscriptionParameters.default
        params.temperatureFallbackCount = 1
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testFallback_3() async throws {
        var params = TranscriptionParameters.default
        params.temperatureFallbackCount = 3
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testFallback_5() async throws {
        var params = TranscriptionParameters.default
        params.temperatureFallbackCount = 5
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    // MARK: - concurrentWorkerCount

    func testWorkers_2() async throws {
        var params = TranscriptionParameters.default
        params.concurrentWorkerCount = 2
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testWorkers_4() async throws {
        var params = TranscriptionParameters.default
        params.concurrentWorkerCount = 4
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testWorkers_8() async throws {
        var params = TranscriptionParameters.default
        params.concurrentWorkerCount = 8
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testWorkers_16() async throws {
        var params = TranscriptionParameters.default
        params.concurrentWorkerCount = 16
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    // MARK: - sampleLength

    func testSampleLength_128() async throws {
        var params = TranscriptionParameters.default
        params.sampleLength = 128
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testSampleLength_224() async throws {
        var params = TranscriptionParameters.default
        params.sampleLength = 224
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    // sampleLength=448 exceeds WhisperKit's internal buffer (max 224), skipped
}
