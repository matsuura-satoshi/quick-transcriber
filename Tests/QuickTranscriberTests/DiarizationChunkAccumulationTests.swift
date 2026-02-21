import XCTest
@testable import QuickTranscriberLib

final class DiarizationChunkAccumulationTests: XCTestCase {

    // MARK: - DiarizationPacer

    func testPacerReturnsFalseWhenBelowThreshold() {
        var pacer = DiarizationPacer(diarizationChunkDuration: 6.0, sampleRate: 16000)
        // 3s chunk = 48000 samples, threshold = 96000 (6s)
        let shouldRun = pacer.accumulate(chunkSamples: 48000)
        XCTAssertFalse(shouldRun)
        XCTAssertEqual(pacer.samplesSinceLastDiarization, 48000)
    }

    func testPacerReturnsTrueWhenThresholdReached() {
        var pacer = DiarizationPacer(diarizationChunkDuration: 6.0, sampleRate: 16000)
        // First 3s chunk
        _ = pacer.accumulate(chunkSamples: 48000)
        // Second 3s chunk → total 6s = threshold
        let shouldRun = pacer.accumulate(chunkSamples: 48000)
        XCTAssertTrue(shouldRun)
    }

    func testPacerResetClearsAccumulation() {
        var pacer = DiarizationPacer(diarizationChunkDuration: 6.0, sampleRate: 16000)
        _ = pacer.accumulate(chunkSamples: 48000)
        pacer.reset()
        XCTAssertEqual(pacer.samplesSinceLastDiarization, 0)

        // After reset, need to accumulate again
        let shouldRun = pacer.accumulate(chunkSamples: 48000)
        XCTAssertFalse(shouldRun)
    }

    func testPacerReturnsTrueWhenExceedsThreshold() {
        var pacer = DiarizationPacer(diarizationChunkDuration: 5.0, sampleRate: 16000)
        // Single 7s chunk > 5s threshold
        let shouldRun = pacer.accumulate(chunkSamples: 112000)
        XCTAssertTrue(shouldRun)
    }

    func testPacerLastResultCaching() {
        var pacer = DiarizationPacer(diarizationChunkDuration: 6.0, sampleRate: 16000)
        XCTAssertNil(pacer.lastResult)
        let testId = UUID()
        pacer.lastResult = SpeakerIdentification(speakerId: testId, confidence: 0.85)
        XCTAssertEqual(pacer.lastResult?.speakerId, testId)
        XCTAssertEqual(pacer.lastResult?.confidence, 0.85)
    }

    // MARK: - findRelevantSegment with wider chunk duration

    func testFindRelevantSegmentWith7sChunk() {
        // Buffer 15s, chunk 7s → target range: 8.0-15.0
        let segEarly = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "S1", embedding: [1.0], startTime: 0.0, endTime: 8.0
        )
        let segLate = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "S2", embedding: [2.0], startTime: 8.0, endTime: 15.0
        )
        let result = FluidAudioSpeakerDiarizer.findRelevantSegment(
            segments: [segEarly, segLate], bufferDuration: 15.0, chunkDuration: 7.0
        )
        XCTAssertEqual(result?.speakerId, "S2")
    }

    func testFindRelevantSegmentWiderChunkCoversBothSpeakers() {
        // Buffer 15s, chunk 7s → target range: 8.0-15.0
        // Speaker A: 8-11s (3s overlap), Speaker B: 11-15s (4s overlap)
        let segA = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "A", embedding: [1.0], startTime: 8.0, endTime: 11.0
        )
        let segB = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "B", embedding: [2.0], startTime: 11.0, endTime: 15.0
        )
        let result = FluidAudioSpeakerDiarizer.findRelevantSegment(
            segments: [segA, segB], bufferDuration: 15.0, chunkDuration: 7.0
        )
        // B has more overlap (4s > 3s)
        XCTAssertEqual(result?.speakerId, "B")
    }
}
