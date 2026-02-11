import XCTest
@testable import MyTranscriberLib

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
}
