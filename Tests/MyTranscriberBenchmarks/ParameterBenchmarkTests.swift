import XCTest
@testable import MyTranscriberLib

final class ParameterBenchmarkTests: BenchmarkTestBase {

    override var outputPath: String { "/tmp/mytranscriber_parameter_results.json" }
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

    // MARK: - noSpeechThreshold

    func testNoSpeech_03() async throws {
        var params = TranscriptionParameters.default
        params.noSpeechThreshold = 0.3
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testNoSpeech_04() async throws {
        var params = TranscriptionParameters.default
        params.noSpeechThreshold = 0.4
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testNoSpeech_06() async throws {
        var params = TranscriptionParameters.default
        params.noSpeechThreshold = 0.6
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testNoSpeech_08() async throws {
        var params = TranscriptionParameters.default
        params.noSpeechThreshold = 0.8
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    // MARK: - compressionRatioThreshold

    func testCompression_18() async throws {
        var params = TranscriptionParameters.default
        params.compressionRatioThreshold = 1.8
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testCompression_24() async throws {
        var params = TranscriptionParameters.default
        params.compressionRatioThreshold = 2.4
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testCompression_30() async throws {
        var params = TranscriptionParameters.default
        params.compressionRatioThreshold = 3.0
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

    // MARK: - requiredSegmentsForConfirmation

    func testSegments_1() async throws {
        var params = TranscriptionParameters.default
        params.requiredSegmentsForConfirmation = 1
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testSegments_2() async throws {
        var params = TranscriptionParameters.default
        params.requiredSegmentsForConfirmation = 2
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testSegments_3() async throws {
        var params = TranscriptionParameters.default
        params.requiredSegmentsForConfirmation = 3
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    // MARK: - silenceThreshold

    func testSilence_02() async throws {
        var params = TranscriptionParameters.default
        params.silenceThreshold = 0.2
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testSilence_03() async throws {
        var params = TranscriptionParameters.default
        params.silenceThreshold = 0.3
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testSilence_05() async throws {
        var params = TranscriptionParameters.default
        params.silenceThreshold = 0.5
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }

    func testSilence_07() async throws {
        var params = TranscriptionParameters.default
        params.silenceThreshold = 0.7
        _ = try await runBenchmark(fixture: testFixture, parameters: params)
    }
}
