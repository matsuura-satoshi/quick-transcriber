import XCTest
@testable import QuickTranscriberLib

final class ChunkAccumulatorTests: XCTestCase {
    private let sampleRate: Double = 16000.0

    /// Helper: create a buffer of samples with given amplitude and duration.
    private func makeBuffer(amplitude: Float, duration: TimeInterval) -> [Float] {
        [Float](repeating: amplitude, count: Int(duration * sampleRate))
    }

    /// Helper: create speech buffer (above onset threshold).
    private func speechBuffer(duration: TimeInterval) -> [Float] {
        makeBuffer(amplitude: 0.1, duration: duration)
    }

    /// Helper: create silence buffer (zero energy).
    private func silenceBuffer(duration: TimeInterval) -> [Float] {
        makeBuffer(amplitude: 0.0, duration: duration)
    }

    /// Feed buffer in 100ms increments (simulating real streaming).
    private func feedIncrementally(_ acc: inout VADChunkAccumulator, buffer: [Float], incrementDuration: TimeInterval = 0.1) -> [ChunkResult] {
        let incrementSize = Int(incrementDuration * sampleRate)
        var results: [ChunkResult] = []
        var offset = 0
        while offset < buffer.count {
            let end = min(offset + incrementSize, buffer.count)
            let slice = Array(buffer[offset..<end])
            if let result = acc.appendBuffer(slice) {
                results.append(result)
            }
            offset = end
        }
        return results
    }

    // MARK: - Idle → Speaking Transition

    func testIdleToSpeakingTransition() {
        var acc = VADChunkAccumulator()
        // Feed speech — should not immediately produce a result (accumulating)
        let result = acc.appendBuffer(speechBuffer(duration: 0.1))
        XCTAssertNil(result, "Single speech buffer should not produce a chunk")
    }

    // MARK: - Pre-roll

    func testPreRollIncludedInChunk() {
        var acc = VADChunkAccumulator(
            endOfUtteranceSilence: 0.3,
            preRollDuration: 0.3
        )
        // Feed 0.5s silence (fills pre-roll)
        _ = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.5))
        // Feed 0.5s speech
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 0.5))
        // Feed 0.4s silence to trigger end-of-utterance (>= 0.3s)
        let results = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.4))

        XCTAssertEqual(results.count, 1, "Should emit one chunk")
        // Chunk should contain: pre-roll (0.3s) + speech (0.5s) + trailing silence (>=0.3s)
        let chunkDuration = TimeInterval(results[0].samples.count) / sampleRate
        XCTAssertGreaterThanOrEqual(chunkDuration, 0.8, "Chunk should include pre-roll + speech")
    }

    func testPreRollDoesNotExceedConfiguredDuration() {
        var acc = VADChunkAccumulator(preRollDuration: 0.3)
        // Feed 2s of silence (much more than pre-roll)
        _ = feedIncrementally(&acc, buffer: silenceBuffer(duration: 2.0))
        // Feed 0.5s speech + endOfUtterance silence
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 0.5))
        let results = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.7))

        XCTAssertEqual(results.count, 1)
        let chunkDuration = TimeInterval(results[0].samples.count) / sampleRate
        // pre-roll(0.3) + speech(0.5) + trailing(>=0.6) ≈ 1.4-1.5s
        // Without pre-roll cap it would be much longer
        XCTAssertLessThan(chunkDuration, 2.0, "Pre-roll should be capped at configured duration")
    }

    // MARK: - Hangover

    func testHangoverPreventsEarlyCut() {
        var acc = VADChunkAccumulator(
            endOfUtteranceSilence: 0.6,
            hangoverDuration: 0.15
        )
        // Feed speech
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 1.0))
        // Feed short silence (< hangoverDuration) then speech again
        _ = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.1))
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 0.5))
        // Feed end-of-utterance silence
        let results = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.7))

        // Should produce exactly one chunk (hangover prevented cut at 0.1s silence)
        XCTAssertEqual(results.count, 1, "Hangover should prevent premature cut")
    }

    // MARK: - End of Utterance

    func testEndOfUtteranceSilenceCutsChunk() {
        var acc = VADChunkAccumulator(endOfUtteranceSilence: 0.6)
        // Feed speech
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 1.0))
        // Feed silence >= endOfUtteranceSilence
        let results = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.7))

        XCTAssertEqual(results.count, 1, "Should cut after end-of-utterance silence")
    }

    // MARK: - Max Duration

    func testMaxDurationForceCut() {
        var acc = VADChunkAccumulator(maxChunkDuration: 2.0)
        // Feed continuous speech exceeding maxChunkDuration
        let results = feedIncrementally(&acc, buffer: speechBuffer(duration: 2.5))

        XCTAssertGreaterThanOrEqual(results.count, 1, "Should force-cut at max duration")
        let chunkDuration = TimeInterval(results[0].samples.count) / sampleRate
        XCTAssertEqual(chunkDuration, 2.0, accuracy: 0.15, "Forced cut should be near max duration")
    }

    // MARK: - Minimum Utterance Filter

    func testMinimumUtteranceFilterDiscardsTooShort() {
        var acc = VADChunkAccumulator(
            endOfUtteranceSilence: 0.3,
            minimumUtteranceDuration: 0.3
        )
        // Feed very short speech (50ms) + silence
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 0.05))
        let results = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.4))

        XCTAssertEqual(results.count, 0, "Too-short utterance should be discarded")
    }

    func testShortButValidUtteranceIsEmitted() {
        var acc = VADChunkAccumulator(
            endOfUtteranceSilence: 0.3,
            minimumUtteranceDuration: 0.3
        )
        // Feed 0.4s speech (above minimum) + silence
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 0.4))
        let results = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.4))

        XCTAssertEqual(results.count, 1, "Valid utterance should be emitted")
    }

    // MARK: - Preceding Silence

    func testPrecedingSilenceAccuracy() {
        var acc = VADChunkAccumulator(endOfUtteranceSilence: 0.3)
        // Feed 2.5s silence → then speech + silence
        _ = feedIncrementally(&acc, buffer: silenceBuffer(duration: 2.5))
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 0.5))
        let results = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.4))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].precedingSilenceDuration, 2.5, accuracy: 0.15,
                       "precedingSilence should reflect idle silence duration")
    }

    // MARK: - Trailing Silence

    func testTrailingSilenceAccuracy() {
        var acc = VADChunkAccumulator(endOfUtteranceSilence: 0.6)
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 1.0))
        let results = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.7))

        XCTAssertEqual(results.count, 1)
        XCTAssertGreaterThanOrEqual(results[0].trailingSilenceDuration, 0.6,
                                    "trailingSilence should be at least endOfUtteranceSilence")
    }

    // MARK: - Silence Carryover

    func testSilenceCarryover() {
        var acc = VADChunkAccumulator(endOfUtteranceSilence: 0.3)
        // First utterance
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 0.5))
        let results1 = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.4))
        XCTAssertEqual(results1.count, 1)
        let trailing1 = results1[0].trailingSilenceDuration

        // Second utterance — its preceding silence should include carryover
        _ = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.5))
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 0.5))
        let results2 = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.4))
        XCTAssertEqual(results2.count, 1)
        // Preceding = trailing from chunk1 + additional silence (0.5s)
        XCTAssertGreaterThanOrEqual(results2[0].precedingSilenceDuration, trailing1 + 0.4,
                                    "Carryover should add previous trailing to idle silence")
    }

    // MARK: - Flush

    func testFlushInSpeakingState() {
        var acc = VADChunkAccumulator()
        // Feed speech without triggering cut
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 1.0))
        let result = acc.flush()
        XCTAssertNotNil(result, "Flush during speaking should emit buffered audio")
        let chunkDuration = TimeInterval(result!.samples.count) / sampleRate
        XCTAssertGreaterThanOrEqual(chunkDuration, 0.5)
    }

    func testFlushInIdleState() {
        var acc = VADChunkAccumulator()
        // Feed only silence
        _ = feedIncrementally(&acc, buffer: silenceBuffer(duration: 1.0))
        let result = acc.flush()
        XCTAssertNil(result, "Flush during idle should return nil")
    }

    func testFlushInHangoverState() {
        var acc = VADChunkAccumulator(
            endOfUtteranceSilence: 1.0,
            hangoverDuration: 0.5
        )
        // Feed speech then short silence (enter hangover but not end-of-utterance)
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 1.0))
        _ = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.3))
        let result = acc.flush()
        XCTAssertNotNil(result, "Flush during hangover should emit buffered audio")
    }

    func testFlushTooShortIsDiscarded() {
        var acc = VADChunkAccumulator()
        // Feed very short speech (0.3s)
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 0.3))
        let result = acc.flush()
        XCTAssertNil(result, "Flush with < 0.5s audio should return nil")
    }

    // MARK: - Reset

    func testResetClearsAllState() {
        var acc = VADChunkAccumulator()
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 1.0))
        acc.reset()
        // After reset, flush should return nil
        let result = acc.flush()
        XCTAssertNil(result, "Reset should clear all buffered audio")
    }

    // MARK: - Multiple Utterances

    func testMultipleUtterancesProduceMultipleChunks() {
        var acc = VADChunkAccumulator(endOfUtteranceSilence: 0.3)
        // First utterance
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 0.5))
        let results1 = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.4))
        // Second utterance
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 0.5))
        let results2 = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.4))

        XCTAssertEqual(results1.count, 1, "First utterance should produce one chunk")
        XCTAssertEqual(results2.count, 1, "Second utterance should produce one chunk")
    }

    // MARK: - Hysteresis

    func testHysteresisOnsetOffsetDifference() {
        // Energy between offset (0.01) and onset (0.02) should:
        // - NOT trigger speaking from idle
        // - Continue speaking if already in speaking state
        var acc = VADChunkAccumulator(
            endOfUtteranceSilence: 0.3,
            silenceEnergyThreshold: 0.01,
            speechOnsetThreshold: 0.02
        )
        // Feed audio at amplitude 0.015 (RMS between offset and onset) — should stay idle
        _ = feedIncrementally(&acc, buffer: makeBuffer(amplitude: 0.015, duration: 1.0))
        let result = acc.flush()
        XCTAssertNil(result, "Energy between offset and onset should not trigger speaking from idle")
    }

    func testHysteresisSpeakingContinues() {
        var acc = VADChunkAccumulator(
            endOfUtteranceSilence: 0.5,
            silenceEnergyThreshold: 0.01,
            speechOnsetThreshold: 0.02
        )
        // Start speaking with clear speech
        _ = feedIncrementally(&acc, buffer: speechBuffer(duration: 0.5))
        // Drop to energy between offset and onset — should continue speaking (not hangover)
        _ = feedIncrementally(&acc, buffer: makeBuffer(amplitude: 0.015, duration: 0.5))
        // End-of-utterance silence
        let results = feedIncrementally(&acc, buffer: silenceBuffer(duration: 0.6))

        XCTAssertEqual(results.count, 1, "Should produce one chunk")
        let chunkDuration = TimeInterval(results[0].samples.count) / sampleRate
        // Should include the mid-energy portion (not cut early)
        XCTAssertGreaterThanOrEqual(chunkDuration, 0.9, "Mid-energy audio should be included in speaking chunk")
    }

    // MARK: - RMS Energy (preserved from original)

    func testRMSEnergyCalculation() {
        let energy = VADChunkAccumulator.rmsEnergy(of: [0.3, 0.4])
        XCTAssertEqual(energy, sqrt(0.125), accuracy: 0.0001)
    }

    func testRMSEnergyOfSilence() {
        let energy = VADChunkAccumulator.rmsEnergy(of: [Float](repeating: 0.0, count: 100))
        XCTAssertEqual(energy, 0.0)
    }

    func testRMSEnergyOfEmptyArray() {
        let energy = VADChunkAccumulator.rmsEnergy(of: [])
        XCTAssertEqual(energy, 0.0)
    }
}
