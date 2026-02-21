import XCTest
@testable import QuickTranscriberLib

final class TranscriptionServiceTests: XCTestCase {

    func testPrepareSuccess() async throws {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        XCTAssertFalse(service.isReady)
        try await service.prepare(model: "test-model")
        XCTAssertTrue(service.isReady)
        XCTAssertTrue(engine.setupCalled)
    }

    func testPrepareFailure() async {
        let engine = MockTranscriptionEngine()
        engine.setupError = MockError.setupFailed
        let service = TranscriptionService(engine: engine)

        do {
            try await service.prepare(model: "test-model")
            XCTFail("Expected error")
        } catch {
            XCTAssertFalse(service.isReady)
        }
    }

    func testStartTranscriptionRequiresPrepare() async {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        do {
            try await service.startTranscription(language: "en") { _ in }
            XCTFail("Expected error")
        } catch let error as TranscriptionServiceError {
            XCTAssertEqual(error, .engineNotReady)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testStartTranscriptionAfterPrepare() async throws {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        try await service.prepare(model: "test-model")
        try await service.startTranscription(language: "ja") { _ in }

        XCTAssertTrue(engine.startStreamingCalled)
        XCTAssertEqual(engine.startStreamingLanguage, "ja")
    }

    func testStopTranscription() async throws {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        try await service.prepare(model: "test-model")
        try await service.startTranscription(language: "en") { _ in }
        await service.stopTranscription()

        XCTAssertTrue(engine.stopStreamingCalled)
    }

    func testCleanup() async throws {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        try await service.prepare(model: "test-model")
        service.cleanup()

        XCTAssertTrue(engine.cleanupCalled)
        XCTAssertFalse(service.isReady)
    }

    // MARK: - エッジケース

    func testDoubleStartThrowsAlreadyStreaming() async throws {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        try await service.prepare(model: "test-model")
        try await service.startTranscription(language: "en") { _ in }

        do {
            try await service.startTranscription(language: "en") { _ in }
            XCTFail("Expected alreadyStreaming error")
        } catch let error as TranscriptionServiceError {
            XCTAssertEqual(error, .alreadyStreaming)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testStopWithoutStartIsSafe() async {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        // stopTranscription on a non-started service should not crash
        await service.stopTranscription()
        XCTAssertTrue(engine.stopStreamingCalled)
    }

    func testCleanupThenStartThrows() async throws {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        try await service.prepare(model: "test-model")
        service.cleanup()

        do {
            try await service.startTranscription(language: "en") { _ in }
            XCTFail("Expected error after cleanup")
        } catch let error as TranscriptionServiceError {
            XCTAssertEqual(error, .engineNotReady)
        }
    }

    func testCorrectSpeakerAssignmentForwardsToEngine() {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        let embedding: [Float] = [1.0, 2.0, 3.0]
        let oldId = UUID()
        let newId = UUID()
        service.correctSpeakerAssignment(embedding: embedding, from: oldId.uuidString, to: newId.uuidString)

        XCTAssertEqual(engine.correctedAssignments.count, 1)
        XCTAssertEqual(engine.correctedAssignments[0].oldId, oldId)
        XCTAssertEqual(engine.correctedAssignments[0].newId, newId)
        XCTAssertEqual(engine.correctedAssignments[0].embedding, embedding)
    }

    func testCorrectSpeakerAssignmentWithInvalidUUIDIsNoOp() {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        let embedding: [Float] = [1.0, 2.0, 3.0]
        service.correctSpeakerAssignment(embedding: embedding, from: "not-a-uuid", to: "also-not-a-uuid")

        XCTAssertEqual(engine.correctedAssignments.count, 0, "Invalid UUID strings should result in no-op")
    }

    func testServiceErrorDescriptions() {
        XCTAssertNotNil(TranscriptionServiceError.engineNotReady.errorDescription)
        XCTAssertNotNil(TranscriptionServiceError.alreadyStreaming.errorDescription)
    }
}
