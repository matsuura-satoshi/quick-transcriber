import XCTest
@testable import QuickTranscriberLib

final class SpeakerDiarizerTests: XCTestCase {

    // MARK: - findRelevantSegment

    func testFindRelevantSegmentSingle() {
        // Buffer is 10s, chunk is 3s → target range: 7.0-10.0
        let segment = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "S1", embedding: [1.0], startTime: 7.5, endTime: 9.5
        )
        let result = FluidAudioSpeakerDiarizer.findRelevantSegment(
            segments: [segment], bufferDuration: 10.0, chunkDuration: 3.0
        )
        XCTAssertEqual(result?.speakerId, "S1")
    }

    func testFindRelevantSegmentPicksLongestOverlap() {
        // Target range: 7.0-10.0
        let seg1 = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "S1", embedding: [1.0], startTime: 6.0, endTime: 7.5  // 0.5s overlap
        )
        let seg2 = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "S2", embedding: [2.0], startTime: 7.5, endTime: 10.0  // 2.5s overlap
        )
        let result = FluidAudioSpeakerDiarizer.findRelevantSegment(
            segments: [seg1, seg2], bufferDuration: 10.0, chunkDuration: 3.0
        )
        XCTAssertEqual(result?.speakerId, "S2")
    }

    func testFindRelevantSegmentNoOverlap() {
        // Target range: 7.0-10.0
        let segment = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "S1", embedding: [1.0], startTime: 0.0, endTime: 5.0
        )
        let result = FluidAudioSpeakerDiarizer.findRelevantSegment(
            segments: [segment], bufferDuration: 10.0, chunkDuration: 3.0
        )
        XCTAssertNil(result)
    }

    func testFindRelevantSegmentEmpty() {
        let result = FluidAudioSpeakerDiarizer.findRelevantSegment(
            segments: [], bufferDuration: 10.0, chunkDuration: 3.0
        )
        XCTAssertNil(result)
    }

    func testFindRelevantSegmentPartialOverlap() {
        // Target range: 7.0-10.0, segment spans 5.0-8.0 → 1.0s overlap
        let segment = FluidAudioSpeakerDiarizer.TimedSegmentInfo(
            speakerId: "S1", embedding: [1.0], startTime: 5.0, endTime: 8.0
        )
        let result = FluidAudioSpeakerDiarizer.findRelevantSegment(
            segments: [segment], bufferDuration: 10.0, chunkDuration: 3.0
        )
        XCTAssertEqual(result?.speakerId, "S1")
    }

    // MARK: - correctSpeakerAssignment

    func testCorrectSpeakerAssignmentDelegatesToTracker() {
        let diarizer = FluidAudioSpeakerDiarizer()
        let embA = [Float](repeating: 0.01, count: 256)
        var embA_modified = embA
        embA_modified[0] = 1.0
        let embB = [Float](repeating: 0.01, count: 256)
        var embB_modified = embB
        embB_modified[1] = 1.0
        diarizer.loadSpeakerProfiles([("A", embA_modified), ("B", embB_modified)])

        diarizer.correctSpeakerAssignment(embedding: embA_modified, from: "A", to: "B")

        let profiles = diarizer.exportSpeakerProfiles()
        // A had only one embedding (from loadProfiles seed), now moved to B
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].label, "B")
    }
}
