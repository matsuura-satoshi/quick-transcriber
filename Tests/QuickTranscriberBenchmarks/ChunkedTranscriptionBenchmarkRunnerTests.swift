import XCTest
@testable import QuickTranscriberLib

final class ChunkedTranscriptionBenchmarkRunnerTests: XCTestCase {

    // MARK: - ChunkedBenchmarkResult Codable

    func testChunkedBenchmarkResultRoundTrip() throws {
        let result = ChunkedBenchmarkResult(
            fixture: "test_audio",
            label: "vad",
            language: "en",
            wer: 0.05,
            audioDurationSeconds: 10.0,
            totalInferenceSeconds: 2.5,
            realtimeFactor: 0.25,
            chunkCount: 3,
            skippedChunkCount: 1,
            avgChunkDurationSeconds: 3.0,
            p50ChunkDurationSeconds: 2.5,
            p95ChunkDurationSeconds: 4.5,
            minChunkDurationSeconds: 1.0,
            maxChunkDurationSeconds: 5.0,
            firstChunkLatencySeconds: 1.2,
            transcribedText: "hello world",
            referenceText: "hello world",
            peakMemoryMB: 512.0
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        let decoded = try JSONDecoder().decode(ChunkedBenchmarkResult.self, from: data)

        XCTAssertEqual(decoded.fixture, "test_audio")
        XCTAssertEqual(decoded.label, "vad")
        XCTAssertEqual(decoded.wer, 0.05)
        XCTAssertEqual(decoded.chunkCount, 3)
        XCTAssertEqual(decoded.skippedChunkCount, 1)
        XCTAssertEqual(decoded.p95ChunkDurationSeconds, 4.5)
    }

    // MARK: - Chunk Duration Statistics

    func testChunkDurationStatistics() {
        let durations: [Double] = [1.0, 2.0, 3.0, 4.0, 5.0]
        let stats = ChunkDurationStats.compute(from: durations)

        XCTAssertEqual(stats.avg, 3.0, accuracy: 0.01)
        XCTAssertEqual(stats.p50, 3.0, accuracy: 0.01) // median of [1,2,3,4,5]
        XCTAssertEqual(stats.p95, 4.8, accuracy: 0.01) // 95th percentile (linear interpolation)
        XCTAssertEqual(stats.min, 1.0)
        XCTAssertEqual(stats.max, 5.0)
    }

    func testChunkDurationStatisticsEmpty() {
        let stats = ChunkDurationStats.compute(from: [])
        XCTAssertEqual(stats.avg, 0.0)
        XCTAssertEqual(stats.p50, 0.0)
        XCTAssertEqual(stats.min, 0.0)
        XCTAssertEqual(stats.max, 0.0)
    }

    func testChunkDurationStatisticsSingleElement() {
        let stats = ChunkDurationStats.compute(from: [2.5])
        XCTAssertEqual(stats.avg, 2.5)
        XCTAssertEqual(stats.p50, 2.5)
        XCTAssertEqual(stats.p95, 2.5)
        XCTAssertEqual(stats.min, 2.5)
        XCTAssertEqual(stats.max, 2.5)
    }

    // MARK: - Streaming Simulation (VAD vs Fixed chunk counts)

    func testVADProducesChunksFromSpeechSilencePattern() {
        // Simulate: speech + silence + speech + silence pattern
        var acc = VADChunkAccumulator(endOfUtteranceSilence: 0.3)
        let sampleRate = 16000.0
        let incrementSize = Int(0.1 * sampleRate)
        var chunkCount = 0

        // Two utterances
        let audio: [Float] =
            [Float](repeating: 0.1, count: Int(1.0 * sampleRate)) + // 1s speech
            [Float](repeating: 0.0, count: Int(0.5 * sampleRate)) + // 0.5s silence
            [Float](repeating: 0.1, count: Int(1.0 * sampleRate)) + // 1s speech
            [Float](repeating: 0.0, count: Int(0.5 * sampleRate))   // 0.5s silence

        var offset = 0
        while offset < audio.count {
            let end = min(offset + incrementSize, audio.count)
            if acc.appendBuffer(Array(audio[offset..<end])) != nil {
                chunkCount += 1
            }
            offset = end
        }

        XCTAssertEqual(chunkCount, 2, "Two utterances separated by silence should produce 2 VAD chunks")
    }

    func testFixedProducesChunksAtFixedIntervals() {
        var sim = FixedChunkSimulator(chunkDuration: 2.0)
        let sampleRate = 16000.0
        let incrementSize = Int(0.1 * sampleRate)
        var chunkCount = 0

        // Same audio as above (3.0s total speech+silence)
        let audio: [Float] =
            [Float](repeating: 0.1, count: Int(1.0 * sampleRate)) +
            [Float](repeating: 0.0, count: Int(0.5 * sampleRate)) +
            [Float](repeating: 0.1, count: Int(1.0 * sampleRate)) +
            [Float](repeating: 0.0, count: Int(0.5 * sampleRate))

        var offset = 0
        while offset < audio.count {
            let end = min(offset + incrementSize, audio.count)
            if sim.appendBuffer(Array(audio[offset..<end])) != nil {
                chunkCount += 1
            }
            offset = end
        }

        // 3.0s total with 2.0s chunk → should cut at 2.0s, then 1.0s remains
        // But silence cutoff (0.8s) with silence at 1.0-1.5s: first silence is only 0.5s
        // At 2.0s → force cut
        XCTAssertEqual(chunkCount, 1, "3s audio with 2s fixed chunks should produce 1 chunk at 2s boundary")
    }

    // MARK: - Result Append

    func testAppendChunkedResult() throws {
        let tmpPath = NSTemporaryDirectory() + "test_chunked_results_\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let result = ChunkedBenchmarkResult(
            fixture: "test", label: "vad", language: "en",
            wer: 0.1, audioDurationSeconds: 5.0,
            totalInferenceSeconds: 1.0, realtimeFactor: 0.2,
            chunkCount: 2, skippedChunkCount: 0,
            avgChunkDurationSeconds: 2.5, p50ChunkDurationSeconds: 2.5,
            p95ChunkDurationSeconds: 3.0, minChunkDurationSeconds: 2.0,
            maxChunkDurationSeconds: 3.0, firstChunkLatencySeconds: 0.5,
            transcribedText: "test", referenceText: "test",
            peakMemoryMB: 100.0
        )

        try ChunkedBenchmarkResult.appendResult(result, to: tmpPath)
        try ChunkedBenchmarkResult.appendResult(result, to: tmpPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        let decoded = try JSONDecoder().decode([ChunkedBenchmarkResult].self, from: data)
        XCTAssertEqual(decoded.count, 2)
    }
}
