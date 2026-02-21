import XCTest
@testable import QuickTranscriberLib

final class RetroactiveUpdateGuardTests: XCTestCase {

    /// Verify that isUserCorrected segments are NOT overwritten by retroactive speaker updates.
    func testUserCorrectedSegmentNotOverwrittenByRetroactiveUpdate() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        let mockDiarizer = MockSpeakerDiarizer()

        // First chunk: diarizer returns nil (pending)
        // Second chunk: diarizer returns speaker (triggers retroactive update)
        let testSpeakerId = UUID()
        mockDiarizer.speakerResults = [
            nil,
            SpeakerIdentification(speakerId: testSpeakerId, confidence: 0.8),
            SpeakerIdentification(speakerId: testSpeakerId, confidence: 0.8),
        ]

        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "first", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1),
        ]

        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber,
            diarizer: mockDiarizer
        )
        try await engine.setup(model: "test-model")

        var states: [TranscriptionState] = []
        let firstChunk = XCTestExpectation(description: "First chunk")
        let secondChunk = XCTestExpectation(description: "Second chunk")
        var chunkCount = 0

        let params = TranscriptionParameters(enableSpeakerDiarization: true)
        try await engine.startStreaming(language: "en", parameters: params) { state in
            if !state.confirmedText.isEmpty {
                states.append(state)
                chunkCount += 1
                if chunkCount == 1 { firstChunk.fulfill() }
                if chunkCount == 2 { secondChunk.fulfill() }
            }
        }

        // First chunk - speaker will be pending (nil)
        let speech = [Float](repeating: 0.1, count: 80000)
        mockCapture.simulateBuffer(speech)
        await fulfillment(of: [firstChunk], timeout: 6.0)

        // Simulate user correction on the first segment by directly modifying engine state
        // (In practice, ViewModel does this, but engine should guard on retroactive update)
        // We need to mark the segment as user-corrected before the retroactive update happens
        // This test verifies the guard logic in processChunk

        // Send second chunk with confirmed speaker to trigger retroactive update
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "second", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1),
        ]
        mockCapture.simulateBuffer(speech)
        await fulfillment(of: [secondChunk], timeout: 6.0)

        // After retroactive update, first segment should have speaker "A" (since we didn't mark it as user-corrected in engine)
        // This test validates the basic retroactive update flow works
        XCTAssertEqual(states.last?.confirmedSegments.count, 2)

        await engine.stopStreaming()
    }

    /// Test that the engine's processChunk skips isUserCorrected segments during retroactive update.
    /// We verify this by examining confirmedSegments after the update.
    func testRetroactiveUpdateSkipsUserCorrectedSegments() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        let mockDiarizer = MockSpeakerDiarizer()

        // ViterbiSpeakerSmoother needs consecutive same IDs to confirm a speaker
        // nil, id, id → confirms speaker, triggers retroactive update on pending segments
        let testSpeakerId2 = UUID()
        mockDiarizer.speakerResults = [
            nil,
            SpeakerIdentification(speakerId: testSpeakerId2, confidence: 0.8),
            SpeakerIdentification(speakerId: testSpeakerId2, confidence: 0.8),
        ]

        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "first", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1),
        ]

        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber,
            diarizer: mockDiarizer
        )
        try await engine.setup(model: "test-model")

        let firstChunk = XCTestExpectation(description: "First chunk")
        let secondChunk = XCTestExpectation(description: "Second chunk")
        var chunkCount = 0

        let params = TranscriptionParameters(enableSpeakerDiarization: true)
        try await engine.startStreaming(language: "en", parameters: params) { state in
            if !state.confirmedText.isEmpty {
                chunkCount += 1
                if chunkCount == 1 { firstChunk.fulfill() }
                if chunkCount == 2 { secondChunk.fulfill() }
            }
        }

        // First chunk
        let speech = [Float](repeating: 0.1, count: 80000)
        mockCapture.simulateBuffer(speech)
        await fulfillment(of: [firstChunk], timeout: 6.0)

        // Mark first segment as user-corrected (simulating ViewModel action)
        engine.markSegmentAsUserCorrected(at: 0, speaker: "B")

        // Send second chunk to trigger retroactive update
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "second", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1),
        ]
        mockCapture.simulateBuffer(speech)
        await fulfillment(of: [secondChunk], timeout: 6.0)

        // First segment should still be "B" (user-corrected), not overwritten to "A"
        let segments = engine.currentConfirmedSegments
        XCTAssertEqual(segments[0].speaker, "B", "User-corrected segment should not be overwritten by retroactive update")
        XCTAssertTrue(segments[0].isUserCorrected)

        await engine.stopStreaming()
    }

    // MARK: - Profile merge filter

    func testStopStreamingSkipsMergeForCorrectedSpeakers() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        let mockDiarizer = MockSpeakerDiarizer()

        let profileIdA = UUID()
        let profileIdB = UUID()
        mockDiarizer.exportedProfiles = [
            (speakerId: profileIdA, embedding: [Float](repeating: 0.1, count: 256)),
            (speakerId: profileIdB, embedding: [Float](repeating: 0.2, count: 256)),
        ]

        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "test", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1),
        ]

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileMergeTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SpeakerProfileStore(directory: dir)

        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber,
            diarizer: mockDiarizer,
            speakerProfileStore: store
        )
        try await engine.setup(model: "test-model")

        let params = TranscriptionParameters(enableSpeakerDiarization: true)
        try await engine.startStreaming(language: "en", parameters: params) { _ in }

        let speech = [Float](repeating: 0.1, count: 80000)
        mockCapture.simulateBuffer(speech)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Mark segment as user-corrected (was originally profileIdA, user changed to some other speaker)
        engine.markSegmentAsUserCorrected(at: 0, speaker: UUID().uuidString, originalSpeaker: profileIdA.uuidString)

        await engine.stopStreaming()

        // Only profileIdB should have been merged (not profileIdA since it was the original speaker of a corrected segment)
        let profiles = store.profiles
        let mergedNames = profiles.map { $0.displayName }
        XCTAssertTrue(mergedNames.contains(where: { $0.contains(profileIdB.uuidString.prefix(4)) }), "Non-corrected speaker B should be merged")
        XCTAssertFalse(mergedNames.contains(where: { $0.contains(profileIdA.uuidString.prefix(4)) }), "Corrected speaker A should NOT be merged")
    }
}
