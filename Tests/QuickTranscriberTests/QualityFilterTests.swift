import XCTest
@testable import QuickTranscriberLib

final class QualityFilterTests: XCTestCase {

    // MARK: - Language Mismatch Filter (Phase 1.1)

    // English hallucinations should be filtered when language is "ja"
    func testLanguageFilter_rejectsEnglishOnlyWhenJapanese() {
        XCTAssertFalse(TranscriptionUtils.isLanguageConsistent("Yeah.", language: "ja"))
        XCTAssertFalse(TranscriptionUtils.isLanguageConsistent("Bye.", language: "ja"))
        XCTAssertFalse(TranscriptionUtils.isLanguageConsistent("Oh, I'm sleeping. What's that?", language: "ja"))
        XCTAssertFalse(TranscriptionUtils.isLanguageConsistent("Thank you very much.", language: "ja"))
    }

    // Garbage strings should be filtered
    func testLanguageFilter_rejectsGarbageStringsWhenJapanese() {
        XCTAssertFalse(TranscriptionUtils.isLanguageConsistent("QMG no QM.", language: "ja"))
        XCTAssertFalse(TranscriptionUtils.isLanguageConsistent("--- English → Japanese ---", language: "ja"))
    }

    // Normal Japanese text should pass
    func testLanguageFilter_acceptsNormalJapanese() {
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("こんにちは", language: "ja"))
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("今日はいい天気ですね", language: "ja"))
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("深層学習について説明します", language: "ja"))
    }

    // Japanese text mixed with English/numbers should pass
    func testLanguageFilter_acceptsMixedJapaneseEnglish() {
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("WhisperKitを使って文字起こしをします", language: "ja"))
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("APIのエンドポイント", language: "ja"))
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("macOSアプリ", language: "ja"))
    }

    // Numbers-only should pass (e.g. timestamps, codes)
    func testLanguageFilter_acceptsNumbersOnly() {
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("1710", language: "ja"))
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("2024年", language: "ja"))
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("3.14", language: "ja"))
    }

    // Katakana English should pass
    func testLanguageFilter_acceptsKatakanaEnglish() {
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("ファイアウォール", language: "ja"))
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("サーバー", language: "ja"))
    }

    // When language is "en", should not filter English text
    func testLanguageFilter_acceptsEnglishWhenEnglish() {
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("Hello world", language: "en"))
        XCTAssertTrue(TranscriptionUtils.isLanguageConsistent("Yeah.", language: "en"))
    }

    // Empty/whitespace should be rejected
    func testLanguageFilter_rejectsEmptyOrWhitespace() {
        XCTAssertFalse(TranscriptionUtils.isLanguageConsistent("", language: "ja"))
        XCTAssertFalse(TranscriptionUtils.isLanguageConsistent("   ", language: "ja"))
    }

    // MARK: - Repetition Filter (Phase 1.2)

    // Character-level repetition: same character repeated many times
    func testRepetitionFilter_rejectsCharacterRepetition() {
        XCTAssertTrue(TranscriptionUtils.isRepetitive("ああああああああああああああああ"))
        XCTAssertTrue(TranscriptionUtils.isRepetitive("7777777777777777777777"))
    }

    // Phrase-level repetition: same phrase repeated 3+ times
    func testRepetitionFilter_rejectsPhraseRepetition() {
        XCTAssertTrue(TranscriptionUtils.isRepetitive("お客様にお客様にお客様にお客様にお客様に"))
        XCTAssertTrue(TranscriptionUtils.isRepetitive("Thank you. Thank you. Thank you. Thank you."))
    }

    // Normal text should not be flagged
    func testRepetitionFilter_acceptsNormalText() {
        XCTAssertFalse(TranscriptionUtils.isRepetitive("今日はいい天気ですね"))
        XCTAssertFalse(TranscriptionUtils.isRepetitive("深層学習について説明します"))
        XCTAssertFalse(TranscriptionUtils.isRepetitive("Hello, how are you today?"))
    }

    // Natural repetitions should not be flagged (e.g. "はい、はい")
    func testRepetitionFilter_acceptsNaturalRepetition() {
        XCTAssertFalse(TranscriptionUtils.isRepetitive("はい、はい"))
        XCTAssertFalse(TranscriptionUtils.isRepetitive("ええ、ええ"))
        XCTAssertFalse(TranscriptionUtils.isRepetitive("そうですね、そうですね"))
    }

    // Compression ratio: very low unique character ratio
    func testRepetitionFilter_rejectsLowUniqueRatio() {
        // "7" repeated 110 times - extremely low unique ratio
        let repeated7 = String(repeating: "7、", count: 55)
        XCTAssertTrue(TranscriptionUtils.isRepetitive(repeated7))
    }

    // MARK: - Combined Filter (shouldFilterSegment)

    func testShouldFilter_englishHallucination() {
        XCTAssertTrue(TranscriptionUtils.shouldFilterSegment("Yeah.", language: "ja"))
        XCTAssertTrue(TranscriptionUtils.shouldFilterSegment("Bye.", language: "ja"))
    }

    func testShouldFilter_repetitionLoop() {
        let repeated = "お客様にお客様にお客様にお客様にお客様に"
        XCTAssertTrue(TranscriptionUtils.shouldFilterSegment(repeated, language: "ja"))
    }

    func testShouldFilter_normalJapanese() {
        XCTAssertFalse(TranscriptionUtils.shouldFilterSegment("今日はいい天気ですね", language: "ja"))
        XCTAssertFalse(TranscriptionUtils.shouldFilterSegment("WhisperKitを使います", language: "ja"))
    }

    func testShouldFilter_numbersOnly() {
        XCTAssertFalse(TranscriptionUtils.shouldFilterSegment("1710", language: "ja"))
    }

    // MARK: - Metadata Filter (Phase 3)

    func testMetadataFilter_rejectsHighNoSpeechAndLowLogprob() {
        let segment = TranscribedSegment(
            text: "phantom text",
            avgLogprob: -2.0,
            compressionRatio: 1.0,
            noSpeechProb: 0.8
        )
        XCTAssertTrue(TranscriptionUtils.shouldFilterByMetadata(segment))
    }

    func testMetadataFilter_acceptsLowNoSpeechProb() {
        let segment = TranscribedSegment(
            text: "real speech",
            avgLogprob: -2.0,
            compressionRatio: 1.0,
            noSpeechProb: 0.3
        )
        XCTAssertFalse(TranscriptionUtils.shouldFilterByMetadata(segment))
    }

    func testMetadataFilter_acceptsHighLogprob() {
        let segment = TranscribedSegment(
            text: "confident text",
            avgLogprob: -0.5,
            compressionRatio: 1.0,
            noSpeechProb: 0.8
        )
        XCTAssertFalse(TranscriptionUtils.shouldFilterByMetadata(segment))
    }

    func testMetadataFilter_borderlineNoSpeechProbPasses() {
        // Exactly at threshold (0.7) should pass (> not >=)
        let segment = TranscribedSegment(
            text: "borderline",
            avgLogprob: -2.0,
            compressionRatio: 1.0,
            noSpeechProb: 0.7
        )
        XCTAssertFalse(TranscriptionUtils.shouldFilterByMetadata(segment))
    }

    func testMetadataFilter_borderlineLogprobPasses() {
        // Exactly at threshold (-1.5) should pass (< not <=)
        let segment = TranscribedSegment(
            text: "borderline",
            avgLogprob: -1.5,
            compressionRatio: 1.0,
            noSpeechProb: 0.8
        )
        XCTAssertFalse(TranscriptionUtils.shouldFilterByMetadata(segment))
    }

    // MARK: - Integration: ChunkedWhisperEngine filters hallucinations

    func testEngine_filtersEnglishHallucinationInJapaneseMode() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        // Simulate WhisperKit returning English hallucination when language is "ja"
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "Yeah.", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        var lastState: TranscriptionState?
        try await engine.startStreaming(language: "ja") { state in
            lastState = state
        }

        // Feed 3 seconds of audio to trigger chunk
        let buffer = [Float](repeating: 0.1, count: 48000)
        mockCapture.simulateBuffer(buffer)

        try await Task.sleep(nanoseconds: 500_000_000)

        // "Yeah." should be filtered — confirmedText should be empty
        XCTAssertEqual(lastState?.confirmedText ?? "", "")

        await engine.stopStreaming()
    }

    func testEngine_passesValidJapaneseInJapaneseMode() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "今日はいい天気ですね", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        let expectation = XCTestExpectation(description: "Japanese text passes")
        var lastState: TranscriptionState?
        try await engine.startStreaming(language: "ja") { state in
            if !state.confirmedText.isEmpty {
                lastState = state
                expectation.fulfill()
            }
        }

        let buffer = [Float](repeating: 0.1, count: 48000)
        mockCapture.simulateBuffer(buffer)

        await fulfillment(of: [expectation], timeout: 3.0)
        XCTAssertEqual(lastState?.confirmedText, "今日はいい天気ですね")

        await engine.stopStreaming()
    }

    func testEngine_skipsSilentChunk() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "hallucination", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        try await engine.startStreaming(language: "en") { _ in }

        // Feed 3 seconds of silence (all zeros) → should skip transcription
        let silentBuffer = [Float](repeating: 0.0, count: 48000)
        mockCapture.simulateBuffer(silentBuffer)

        try await Task.sleep(nanoseconds: 500_000_000)

        // Transcriber should NOT have been called for silent chunk
        XCTAssertEqual(mockTranscriber.transcribeCallCount, 0)

        await engine.stopStreaming()
    }

    func testEngine_processesNonSilentChunk() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "Hello", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        let expectation = XCTestExpectation(description: "Non-silent chunk processed")
        try await engine.startStreaming(language: "en") { state in
            if !state.confirmedText.isEmpty {
                expectation.fulfill()
            }
        }

        // Feed 3 seconds of non-silent audio
        let loudBuffer = [Float](repeating: 0.1, count: 48000)
        mockCapture.simulateBuffer(loudBuffer)

        await fulfillment(of: [expectation], timeout: 3.0)
        XCTAssertEqual(mockTranscriber.transcribeCallCount, 1)

        await engine.stopStreaming()
    }

    func testEngine_filtersRepetitionLoop() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "お客様にお客様にお客様にお客様にお客様に", avgLogprob: -0.5, compressionRatio: 1.0, noSpeechProb: 0.1)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        var lastState: TranscriptionState?
        try await engine.startStreaming(language: "ja") { state in
            lastState = state
        }

        let buffer = [Float](repeating: 0.1, count: 48000)
        mockCapture.simulateBuffer(buffer)

        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(lastState?.confirmedText ?? "", "")

        await engine.stopStreaming()
    }

    // MARK: - Integration: ChunkedWhisperEngine filters by metadata

    func testEngine_filtersHighNoSpeechSegment() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        // High noSpeechProb + low avgLogprob → should be filtered
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "phantom", avgLogprob: -2.0, compressionRatio: 1.0, noSpeechProb: 0.8)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        var lastState: TranscriptionState?
        try await engine.startStreaming(language: "en") { state in
            lastState = state
        }

        let buffer = [Float](repeating: 0.1, count: 48000)
        mockCapture.simulateBuffer(buffer)

        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(lastState?.confirmedText ?? "", "")

        await engine.stopStreaming()
    }

    func testEngine_passesGoodMetadataSegment() async throws {
        let mockCapture = MockAudioCaptureService()
        let mockTranscriber = MockChunkTranscriber()
        // Good metadata → should pass
        mockTranscriber.transcribeResults = [
            TranscribedSegment(text: "Hello world", avgLogprob: -0.5, compressionRatio: 1.2, noSpeechProb: 0.1)
        ]
        let engine = ChunkedWhisperEngine(
            audioCaptureService: mockCapture,
            transcriber: mockTranscriber
        )
        try await engine.setup(model: "test-model")

        let expectation = XCTestExpectation(description: "Good segment passes")
        var lastState: TranscriptionState?
        try await engine.startStreaming(language: "en") { state in
            if !state.confirmedText.isEmpty {
                lastState = state
                expectation.fulfill()
            }
        }

        let buffer = [Float](repeating: 0.1, count: 48000)
        mockCapture.simulateBuffer(buffer)

        await fulfillment(of: [expectation], timeout: 3.0)
        XCTAssertEqual(lastState?.confirmedText, "Hello world")

        await engine.stopStreaming()
    }
}
