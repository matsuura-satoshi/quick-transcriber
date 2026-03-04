import XCTest
@testable import QuickTranscriberLib

final class FixedChunkSimulatorTests: XCTestCase {
    private let sampleRate: Double = 16000.0

    private func makeBuffer(amplitude: Float, duration: TimeInterval) -> [Float] {
        [Float](repeating: amplitude, count: Int(duration * sampleRate))
    }

    private func speechBuffer(duration: TimeInterval) -> [Float] {
        makeBuffer(amplitude: 0.1, duration: duration)
    }

    private func silenceBuffer(duration: TimeInterval) -> [Float] {
        makeBuffer(amplitude: 0.0, duration: duration)
    }

    private func feedIncrementally(_ sim: inout FixedChunkSimulator, buffer: [Float], incrementDuration: TimeInterval = 0.1) -> [ChunkResult] {
        let incrementSize = Int(incrementDuration * sampleRate)
        var results: [ChunkResult] = []
        var offset = 0
        while offset < buffer.count {
            let end = min(offset + incrementSize, buffer.count)
            let slice = Array(buffer[offset..<end])
            if let result = sim.appendBuffer(slice) {
                results.append(result)
            }
            offset = end
        }
        return results
    }

    // MARK: - Fixed Duration Cut

    func testForceCutAtChunkDuration() {
        var sim = FixedChunkSimulator(chunkDuration: 5.0)
        // Feed 6s of speech — should force cut at 5s
        let results = feedIncrementally(&sim, buffer: speechBuffer(duration: 6.0))
        XCTAssertEqual(results.count, 1, "Should force-cut at chunkDuration")
        let chunkDuration = TimeInterval(results[0].samples.count) / sampleRate
        XCTAssertEqual(chunkDuration, 5.0, accuracy: 0.15, "Cut should happen at ~5s")
    }

    // MARK: - Silence Early Cut

    func testSilenceEarlyCut() {
        var sim = FixedChunkSimulator(chunkDuration: 5.0, silenceCutoff: 0.8, minimumChunkDuration: 1.0)
        // Feed 2s of speech then 1s of silence (>0.8s cutoff)
        _ = feedIncrementally(&sim, buffer: speechBuffer(duration: 2.0))
        let results = feedIncrementally(&sim, buffer: silenceBuffer(duration: 1.0))
        XCTAssertEqual(results.count, 1, "Should cut early when silence exceeds cutoff")
        let chunkDuration = TimeInterval(results[0].samples.count) / sampleRate
        XCTAssertLessThan(chunkDuration, 5.0, "Early cut should be shorter than chunkDuration")
    }

    func testNoEarlyCutBelowMinimumDuration() {
        var sim = FixedChunkSimulator(chunkDuration: 5.0, silenceCutoff: 0.5, minimumChunkDuration: 2.0)
        // Feed 0.3s of speech then 0.6s of silence (total 0.9s < minimumChunkDuration 2.0)
        // Even though silence >= cutoff, totalDuration < minimumChunkDuration prevents early cut
        _ = feedIncrementally(&sim, buffer: speechBuffer(duration: 0.3))
        let results = feedIncrementally(&sim, buffer: silenceBuffer(duration: 0.6))
        XCTAssertEqual(results.count, 0, "Should NOT cut early when below minimumChunkDuration")
    }

    // MARK: - Silence Skip (Energy Threshold)

    func testShouldSkipDetectsLowEnergyChunk() {
        var sim = FixedChunkSimulator(chunkDuration: 5.0, silenceSkipThreshold: 0.005)
        // Feed speech to force a cut
        let results = feedIncrementally(&sim, buffer: speechBuffer(duration: 5.5))
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(sim.shouldSkip(results[0]), "Speech chunk should NOT be skipped")

        // Now feed pure silence to get a silence chunk
        _ = feedIncrementally(&sim, buffer: silenceBuffer(duration: 5.5))
        let silenceResult = sim.flush()!
        XCTAssertTrue(sim.shouldSkip(silenceResult), "Silence chunk should be skipped")
    }

    // MARK: - Flush

    func testFlushEmitsRemainingBuffer() {
        var sim = FixedChunkSimulator(chunkDuration: 5.0)
        _ = feedIncrementally(&sim, buffer: speechBuffer(duration: 2.0))
        let result = sim.flush()
        XCTAssertNotNil(result, "Flush should emit remaining buffered audio")
        let chunkDuration = TimeInterval(result!.samples.count) / sampleRate
        XCTAssertEqual(chunkDuration, 2.0, accuracy: 0.15, "Flush should return all buffered audio")
    }

    func testFlushEmptyBufferReturnsNil() {
        var sim = FixedChunkSimulator(chunkDuration: 5.0)
        let result = sim.flush()
        XCTAssertNil(result, "Flush on empty buffer should return nil")
    }

    // MARK: - Multiple Chunks

    func testMultipleChunksFromLongAudio() {
        var sim = FixedChunkSimulator(chunkDuration: 3.0)
        // Feed 10s of speech — should produce 3 chunks (3+3+3) with 1s remaining
        let results = feedIncrementally(&sim, buffer: speechBuffer(duration: 10.0))
        XCTAssertEqual(results.count, 3, "10s audio with 3s chunks should produce 3 chunks")
        // Flush remaining
        let flushed = sim.flush()
        XCTAssertNotNil(flushed, "Should have remaining audio to flush")
    }

    // MARK: - Trailing Silence Duration

    func testTrailingSilenceDurationAccuracy() {
        var sim = FixedChunkSimulator(chunkDuration: 5.0, silenceCutoff: 0.8, minimumChunkDuration: 1.0)
        // Feed 2s speech + 1s silence → early cut
        _ = feedIncrementally(&sim, buffer: speechBuffer(duration: 2.0))
        let results = feedIncrementally(&sim, buffer: silenceBuffer(duration: 1.0))
        XCTAssertEqual(results.count, 1)
        XCTAssertGreaterThanOrEqual(results[0].trailingSilenceDuration, 0.8,
                                     "Trailing silence should be at least silenceCutoff")
    }

    // MARK: - Preceding Silence

    func testPrecedingSilenceFromPreviousChunk() {
        var sim = FixedChunkSimulator(chunkDuration: 5.0, silenceCutoff: 0.8, minimumChunkDuration: 1.0)
        // First chunk: 2s speech + 1s silence → early cut with trailing silence
        _ = feedIncrementally(&sim, buffer: speechBuffer(duration: 2.0))
        let results1 = feedIncrementally(&sim, buffer: silenceBuffer(duration: 1.0))
        XCTAssertEqual(results1.count, 1)

        // Second chunk: 2s speech + 1s silence → preceding should carry over from first trailing
        _ = feedIncrementally(&sim, buffer: speechBuffer(duration: 2.0))
        let results2 = feedIncrementally(&sim, buffer: silenceBuffer(duration: 1.0))
        XCTAssertEqual(results2.count, 1)
        XCTAssertGreaterThan(results2[0].precedingSilenceDuration, 0.0,
                             "Second chunk should have preceding silence from first chunk's trailing")
    }
}
