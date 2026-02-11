import XCTest
@testable import QuickTranscriberLib

final class ChunkAccumulatorTests: XCTestCase {
    private let sampleRate: Double = 16000.0

    // MARK: - Max Duration Cut

    func testChunkCutAtMaxDuration() {
        var acc = ChunkAccumulator(chunkDuration: 3.0)
        let samplesPerSecond = Int(sampleRate)
        // Feed 2.9 seconds of audio — should not cut yet
        let buffer1s = [Float](repeating: 0.1, count: samplesPerSecond)
        for _ in 0..<2 {
            let result = acc.appendBuffer(buffer1s)
            XCTAssertNil(result, "Should not cut before max duration")
        }
        // Feed remaining 1.0s to reach 3.0s — should cut
        let chunk = acc.appendBuffer(buffer1s)
        XCTAssertNotNil(chunk, "Should cut at max duration")
        XCTAssertEqual(chunk!.count, samplesPerSecond * 3)
    }

    // MARK: - Silence Detection

    func testSilenceDetectionCutsEarly() {
        var acc = ChunkAccumulator(
            chunkDuration: 3.0,
            silenceCutoffDuration: 0.5,
            silenceEnergyThreshold: 0.01,
            minimumChunkDuration: 1.0
        )
        // Feed 1.2s of speech (above threshold)
        let speechBuffer = [Float](repeating: 0.1, count: Int(1.2 * sampleRate))
        XCTAssertNil(acc.appendBuffer(speechBuffer))

        // Feed 0.5s of silence — should trigger cut (total > 1s minimum)
        let silenceBuffer = [Float](repeating: 0.0, count: Int(0.5 * sampleRate))
        let chunk = acc.appendBuffer(silenceBuffer)
        XCTAssertNotNil(chunk, "Should cut after silence threshold")
        let expectedCount = Int(1.2 * sampleRate) + Int(0.5 * sampleRate)
        XCTAssertEqual(chunk!.count, expectedCount)
    }

    // MARK: - Minimum Chunk Length

    func testMinimumChunkLength() {
        var acc = ChunkAccumulator(
            chunkDuration: 3.0,
            silenceCutoffDuration: 0.3,
            silenceEnergyThreshold: 0.01,
            minimumChunkDuration: 1.0
        )
        // Feed 0.5s of speech then 0.3s of silence — below minimum duration, should NOT cut
        let speechBuffer = [Float](repeating: 0.1, count: Int(0.5 * sampleRate))
        XCTAssertNil(acc.appendBuffer(speechBuffer))

        let silenceBuffer = [Float](repeating: 0.0, count: Int(0.3 * sampleRate))
        let chunk = acc.appendBuffer(silenceBuffer)
        XCTAssertNil(chunk, "Should not cut below minimum chunk duration")
    }

    // MARK: - RMS Energy Calculation

    func testRMSEnergyCalculation() {
        // Known input: [0.3, 0.4]
        // Sum of squares = 0.09 + 0.16 = 0.25
        // Mean = 0.125
        // sqrt(0.125) ≈ 0.3536
        let energy = ChunkAccumulator.rmsEnergy(of: [0.3, 0.4])
        XCTAssertEqual(energy, sqrt(0.125), accuracy: 0.0001)
    }

    func testRMSEnergyOfSilence() {
        let energy = ChunkAccumulator.rmsEnergy(of: [Float](repeating: 0.0, count: 100))
        XCTAssertEqual(energy, 0.0)
    }

    func testRMSEnergyOfEmptyArray() {
        let energy = ChunkAccumulator.rmsEnergy(of: [])
        XCTAssertEqual(energy, 0.0)
    }

    // MARK: - Empty / Silence Only

    func testEmptySilenceProducesNoChunk() {
        var acc = ChunkAccumulator(
            chunkDuration: 3.0,
            silenceCutoffDuration: 0.5,
            silenceEnergyThreshold: 0.01,
            minimumChunkDuration: 1.0
        )
        // Feed only 0.3s of silence — below both min duration and silence cutoff
        let silenceBuffer = [Float](repeating: 0.0, count: Int(0.3 * sampleRate))
        XCTAssertNil(acc.appendBuffer(silenceBuffer))
    }

    // MARK: - Flush

    func testFlushReturnsRemainingAudio() {
        var acc = ChunkAccumulator(chunkDuration: 3.0)
        // Feed 1.0s of audio
        let buffer = [Float](repeating: 0.1, count: Int(sampleRate))
        XCTAssertNil(acc.appendBuffer(buffer))
        // Flush should return the buffered audio
        let chunk = acc.flush()
        XCTAssertNotNil(chunk)
        XCTAssertEqual(chunk!.count, Int(sampleRate))
    }

    func testFlushDiscardsTooShortAudio() {
        var acc = ChunkAccumulator(chunkDuration: 3.0)
        // Feed 0.3s of audio — too short to flush
        let buffer = [Float](repeating: 0.1, count: Int(0.3 * sampleRate))
        XCTAssertNil(acc.appendBuffer(buffer))
        let chunk = acc.flush()
        XCTAssertNil(chunk, "Should not flush audio shorter than 0.5s")
    }

    // MARK: - Reset

    func testResetClearsBuffer() {
        var acc = ChunkAccumulator(chunkDuration: 3.0)
        let buffer = [Float](repeating: 0.1, count: Int(sampleRate))
        XCTAssertNil(acc.appendBuffer(buffer))
        acc.reset()
        let chunk = acc.flush()
        XCTAssertNil(chunk, "Should have no audio after reset")
    }

    // MARK: - Multiple Chunks

    func testMultipleChunksProduced() {
        var acc = ChunkAccumulator(chunkDuration: 2.0)
        let samplesPerSecond = Int(sampleRate)
        var chunkCount = 0

        // Feed 5 seconds of audio in 1-second increments
        for _ in 0..<5 {
            let buffer = [Float](repeating: 0.1, count: samplesPerSecond)
            if acc.appendBuffer(buffer) != nil {
                chunkCount += 1
            }
        }

        XCTAssertEqual(chunkCount, 2, "Should produce 2 full chunks from 5s of audio at 2s max")
    }

    // MARK: - Silence Resets After Speech

    func testSilenceCounterResetsAfterSpeech() {
        var acc = ChunkAccumulator(
            chunkDuration: 5.0,
            silenceCutoffDuration: 0.5,
            silenceEnergyThreshold: 0.01,
            minimumChunkDuration: 1.0
        )
        // Feed 1.0s speech
        let speech = [Float](repeating: 0.1, count: Int(sampleRate))
        XCTAssertNil(acc.appendBuffer(speech))

        // Feed 0.3s silence (not enough to trigger)
        let silence03 = [Float](repeating: 0.0, count: Int(0.3 * sampleRate))
        XCTAssertNil(acc.appendBuffer(silence03))

        // Feed speech again — silence counter should reset
        let speech2 = [Float](repeating: 0.1, count: Int(0.2 * sampleRate))
        XCTAssertNil(acc.appendBuffer(speech2))

        // Feed 0.3s silence again — should NOT trigger cut (counter reset)
        XCTAssertNil(acc.appendBuffer(silence03))
    }
}
