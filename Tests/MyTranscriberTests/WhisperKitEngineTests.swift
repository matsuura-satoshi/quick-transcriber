import XCTest
@testable import MyTranscriberLib

final class WhisperKitEngineTests: XCTestCase {

    func testInitialStateNotStreaming() async {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)
        let streaming = await engine.isStreaming
        XCTAssertFalse(streaming)
    }

    func testSetupDelegatesToProvider() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)
        try await engine.setup(model: "test-model")
        XCTAssertTrue(mock.setupCalled)
        XCTAssertEqual(mock.setupModel, "test-model")
    }

    func testSetupPropagatesError() async {
        let mock = MockWhisperKitProvider()
        mock.setupError = WhisperKitEngineError.notInitialized
        let engine = WhisperKitEngine(provider: mock)
        do {
            try await engine.setup(model: "test-model")
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is WhisperKitEngineError)
        }
    }

    func testStartStreamingSetsIsStreaming() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)
        try await engine.startStreaming(language: "en") { _ in }
        let streaming = await engine.isStreaming
        XCTAssertTrue(streaming)
        XCTAssertTrue(mock.startStreamCalled)
        XCTAssertEqual(mock.startStreamLanguage, "en")
    }

    func testStartStreamingPassesLanguageAndParameters() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)
        let params = TranscriptionParameters.aggressive
        try await engine.startStreaming(language: "ja", parameters: params) { _ in }
        XCTAssertEqual(mock.startStreamLanguage, "ja")
        XCTAssertEqual(mock.startStreamParameters, params)
    }

    func testStartStreamingPropagatesError() async {
        let mock = MockWhisperKitProvider()
        mock.startStreamError = WhisperKitEngineError.notInitialized
        let engine = WhisperKitEngine(provider: mock)
        do {
            try await engine.startStreaming(language: "en") { _ in }
            XCTFail("Expected error")
        } catch {
            // Error propagated correctly
        }
    }

    func testStopStreamingResetsState() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)
        try await engine.startStreaming(language: "en") { _ in }
        await engine.stopStreaming()
        let streaming = await engine.isStreaming
        XCTAssertFalse(streaming)
        XCTAssertTrue(mock.stopStreamCalled)
    }

    func testSegmentsAreCleaned() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)
        let expectation = XCTestExpectation(description: "State change")
        var receivedState: TranscriptionState?
        try await engine.startStreaming(language: "en") { state in
            receivedState = state
            expectation.fulfill()
        }
        mock.simulateSegments(
            confirmed: ["<|en|> Hello world <|0.00|>"],
            unconfirmed: [" typing..."]
        )
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedState?.confirmedText, "Hello world")
        XCTAssertEqual(receivedState?.unconfirmedText, "typing...")
        XCTAssertTrue(receivedState?.isRecording ?? false)
    }

    func testEmptySegmentsAreFiltered() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)
        let expectation = XCTestExpectation(description: "State change")
        var receivedState: TranscriptionState?
        try await engine.startStreaming(language: "en") { state in
            receivedState = state
            expectation.fulfill()
        }
        mock.simulateSegments(confirmed: ["Hello", "", "  ", "World"], unconfirmed: [])
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedState?.confirmedText, "Hello\nWorld")
        XCTAssertEqual(receivedState?.unconfirmedText, "")
    }

    func testJapaneseSegments() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)
        let expectation = XCTestExpectation(description: "State change")
        var receivedState: TranscriptionState?
        try await engine.startStreaming(language: "ja") { state in
            receivedState = state
            expectation.fulfill()
        }
        mock.simulateSegments(confirmed: ["こんにちは", "世界"], unconfirmed: ["テスト中"])
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedState?.confirmedText, "こんにちは\n世界")
        XCTAssertEqual(receivedState?.unconfirmedText, "テスト中")
    }

    func testCleanupCallsStop() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)
        try await engine.startStreaming(language: "en") { _ in }
        engine.cleanup()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(mock.stopStreamCalled)
    }

    func testErrorDescriptions() {
        XCTAssertNotNil(WhisperKitEngineError.notInitialized.errorDescription)
        XCTAssertNotNil(WhisperKitEngineError.tokenizerNotAvailable.errorDescription)
        XCTAssertTrue(WhisperKitEngineError.notInitialized.errorDescription!.contains("setup"))
        XCTAssertTrue(WhisperKitEngineError.tokenizerNotAvailable.errorDescription!.contains("Tokenizer"))
    }
}
