import XCTest
@testable import QuickTranscriberLib

final class TranscriptionUtilsTests: XCTestCase {

    func testCleanSegmentTextRemovesSpecialTokens() {
        let input = "<|startoftranscript|>Hello world<|endoftext|>"
        let result = TranscriptionUtils.cleanSegmentText(input)
        XCTAssertEqual(result, "Hello world")
    }

    func testCleanSegmentTextRemovesTimestampTokens() {
        let input = "<|0.00|>Hello<|2.50|>"
        let result = TranscriptionUtils.cleanSegmentText(input)
        XCTAssertEqual(result, "Hello")
    }

    func testCleanSegmentTextRemovesUnicodeReplacement() {
        let input = "Hello\u{FFFD}World"
        let result = TranscriptionUtils.cleanSegmentText(input)
        XCTAssertEqual(result, "HelloWorld")
    }

    func testCleanSegmentTextTrimsWhitespace() {
        let input = "  Hello World  "
        let result = TranscriptionUtils.cleanSegmentText(input)
        XCTAssertEqual(result, "Hello World")
    }

    func testCleanSegmentTextHandlesEmpty() {
        let result = TranscriptionUtils.cleanSegmentText("")
        XCTAssertEqual(result, "")
    }

    func testCleanSegmentTextOnlySpecialTokens() {
        let input = "<|startoftranscript|><|en|><|transcribe|>"
        let result = TranscriptionUtils.cleanSegmentText(input)
        XCTAssertEqual(result, "")
    }

    func testCleanSegmentTextPreservesNormalText() {
        let input = "The quick brown fox"
        let result = TranscriptionUtils.cleanSegmentText(input)
        XCTAssertEqual(result, "The quick brown fox")
    }

    func testCleanSegmentTextJapanese() {
        let input = "<|ja|>こんにちは世界<|endoftext|>"
        let result = TranscriptionUtils.cleanSegmentText(input)
        XCTAssertEqual(result, "こんにちは世界")
    }

    func testCleanSegmentTextMultipleReplacements() {
        let input = "<|0.00|>\u{FFFD}Hello <|notranslate|> World\u{FFFD}<|2.50|>"
        let result = TranscriptionUtils.cleanSegmentText(input)
        XCTAssertEqual(result, "Hello  World")
    }

    // MARK: - joinSegments

    func testJoinSegmentsEmptyArray() {
        let result = TranscriptionUtils.joinSegments([], language: "en")
        XCTAssertEqual(result, "")
    }

    func testJoinSegmentsSingleSegment() {
        let result = TranscriptionUtils.joinSegments(["Hello"], language: "en")
        XCTAssertEqual(result, "Hello")
    }

    func testJoinSegmentsEnglishNoSentenceEnd() {
        let result = TranscriptionUtils.joinSegments(["Hello", "world"], language: "en")
        XCTAssertEqual(result, "Hello world")
    }

    func testJoinSegmentsEnglishWithPeriod() {
        let result = TranscriptionUtils.joinSegments(["Hello.", "World"], language: "en")
        XCTAssertEqual(result, "Hello.\nWorld")
    }

    func testJoinSegmentsEnglishWithExclamation() {
        let result = TranscriptionUtils.joinSegments(["Wow!", "Amazing"], language: "en")
        XCTAssertEqual(result, "Wow!\nAmazing")
    }

    func testJoinSegmentsEnglishWithQuestion() {
        let result = TranscriptionUtils.joinSegments(["How?", "Like this"], language: "en")
        XCTAssertEqual(result, "How?\nLike this")
    }

    func testJoinSegmentsJapaneseNoSentenceEnd() {
        let result = TranscriptionUtils.joinSegments(["今日は", "いい天気"], language: "ja")
        XCTAssertEqual(result, "今日はいい天気")
    }

    func testJoinSegmentsJapaneseWithPeriod() {
        let result = TranscriptionUtils.joinSegments(["いい天気です。", "明日も晴れ"], language: "ja")
        XCTAssertEqual(result, "いい天気です。\n明日も晴れ")
    }

    func testJoinSegmentsJapaneseWithExclamation() {
        let result = TranscriptionUtils.joinSegments(["すごい！", "本当に"], language: "ja")
        XCTAssertEqual(result, "すごい！\n本当に")
    }

    func testJoinSegmentsJapaneseWithQuestion() {
        let result = TranscriptionUtils.joinSegments(["何？", "分からない"], language: "ja")
        XCTAssertEqual(result, "何？\n分からない")
    }

    func testJoinSegmentsSkipsEmptySegments() {
        let result = TranscriptionUtils.joinSegments(["Hello", "", "world"], language: "en")
        XCTAssertEqual(result, "Hello world")
    }

    func testJoinSegmentsMultipleSentences() {
        let result = TranscriptionUtils.joinSegments(["First.", "Second.", "Third"], language: "en")
        XCTAssertEqual(result, "First.\nSecond.\nThird")
    }

    // MARK: - joinSegments (ConfirmedSegment version)

    func testJoinConfirmedSegmentsEmpty() {
        let result = TranscriptionUtils.joinSegments([ConfirmedSegment](), language: "en")
        XCTAssertEqual(result, "")
    }

    func testJoinConfirmedSegmentsSingle() {
        let segments = [ConfirmedSegment(text: "Hello")]
        let result = TranscriptionUtils.joinSegments(segments, language: "en")
        XCTAssertEqual(result, "Hello")
    }

    func testJoinConfirmedSegmentsSilenceBreakEnglish() {
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0),
            ConfirmedSegment(text: "world", precedingSilence: 1.5),
        ]
        let result = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(result, "Hello\nworld")
    }

    func testJoinConfirmedSegmentsSilenceBreakJapanese() {
        let segments = [
            ConfirmedSegment(text: "今日は", precedingSilence: 0),
            ConfirmedSegment(text: "いい天気", precedingSilence: 2.0),
        ]
        let result = TranscriptionUtils.joinSegments(segments, language: "ja", silenceThreshold: 1.0)
        XCTAssertEqual(result, "今日は\nいい天気")
    }

    func testJoinConfirmedSegmentsNoSilenceBreak() {
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0),
            ConfirmedSegment(text: "world", precedingSilence: 0.3),
        ]
        let result = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(result, "Hello world")
    }

    func testJoinConfirmedSegmentsSentenceEndStillWorks() {
        let segments = [
            ConfirmedSegment(text: "Hello.", precedingSilence: 0),
            ConfirmedSegment(text: "World", precedingSilence: 0.2),
        ]
        let result = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(result, "Hello.\nWorld")
    }

    func testJoinConfirmedSegmentsMixedSilenceAndSentenceEnd() {
        let segments = [
            ConfirmedSegment(text: "First.", precedingSilence: 0),
            ConfirmedSegment(text: "Second", precedingSilence: 0.1),
            ConfirmedSegment(text: "Third", precedingSilence: 1.5),
        ]
        let result = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(result, "First.\nSecond\nThird")
    }

    func testJoinConfirmedSegmentsJapaneseInlineConcatenation() {
        let segments = [
            ConfirmedSegment(text: "今日は", precedingSilence: 0),
            ConfirmedSegment(text: "いい天気", precedingSilence: 0.3),
        ]
        let result = TranscriptionUtils.joinSegments(segments, language: "ja", silenceThreshold: 1.0)
        XCTAssertEqual(result, "今日はいい天気")
    }

    func testJoinConfirmedSegmentsBackwardCompatibility() {
        // String version should still work and delegate correctly
        let result = TranscriptionUtils.joinSegments(["Hello", "world"], language: "en")
        XCTAssertEqual(result, "Hello world")
    }

    func testJoinConfirmedSegmentsSkipsEmpty() {
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0),
            ConfirmedSegment(text: "", precedingSilence: 0.5),
            ConfirmedSegment(text: "world", precedingSilence: 0.3),
        ]
        let result = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(result, "Hello world")
    }

    func testJoinConfirmedSegmentsSilenceExactBoundary() {
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0),
            ConfirmedSegment(text: "world", precedingSilence: 1.0),
        ]
        // Exactly at threshold → should trigger line break (>=)
        let result = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(result, "Hello\nworld")
    }

    // MARK: - joinSegments with speaker labels

    func testJoinConfirmedSegmentsSpeakerChange() {
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A"),
            ConfirmedSegment(text: "Hi there", precedingSilence: 0.5, speaker: "B"),
        ]
        let names = ["A": "A", "B": "B"]
        let result = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0, speakerDisplayNames: names)
        XCTAssertEqual(result, "A: Hello\nB: Hi there")
    }

    func testJoinConfirmedSegmentsSameSpeakerContinuation() {
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A"),
            ConfirmedSegment(text: "how are you", precedingSilence: 0.3, speaker: "A"),
        ]
        let names = ["A": "A"]
        let result = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0, speakerDisplayNames: names)
        XCTAssertEqual(result, "A: Hello how are you")
    }

    func testJoinConfirmedSegmentsMultipleSpeakerChanges() {
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A"),
            ConfirmedSegment(text: "Hi", precedingSilence: 0.5, speaker: "B"),
            ConfirmedSegment(text: "Good morning", precedingSilence: 0.3, speaker: "A"),
        ]
        let names = ["A": "A", "B": "B"]
        let result = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0, speakerDisplayNames: names)
        XCTAssertEqual(result, "A: Hello\nB: Hi\nA: Good morning")
    }

    func testJoinConfirmedSegmentsNilSpeakerFallback() {
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: nil),
            ConfirmedSegment(text: "world", precedingSilence: 0.3, speaker: nil),
        ]
        let result = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0)
        // No speaker labels, behaves like Phase 1
        XCTAssertEqual(result, "Hello world")
    }

    func testJoinConfirmedSegmentsSpeakerWithSilenceBreak() {
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A"),
            ConfirmedSegment(text: "continued", precedingSilence: 2.0, speaker: "A"),
        ]
        let names = ["A": "A"]
        let result = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0, speakerDisplayNames: names)
        // Same speaker but silence break → newline without new label
        XCTAssertEqual(result, "A: Hello\ncontinued")
    }

    func testRetroactiveSpeakerUpdate() {
        // Simulate: segments created without speaker, then retroactively updated
        var segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A"),
            ConfirmedSegment(text: "new speaker", precedingSilence: 0.5, speaker: nil),  // pending
            ConfirmedSegment(text: "still talking", precedingSilence: 0.3, speaker: nil), // pending
        ]
        let names = ["A": "A", "B": "B"]

        // Before update: pending segments have no label
        let beforeUpdate = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0, speakerDisplayNames: names)
        XCTAssertEqual(beforeUpdate, "A: Hello new speaker still talking")

        // Retroactive update: confirm speaker B
        for i in 1..<segments.count {
            segments[i].speaker = "B"
        }

        let afterUpdate = TranscriptionUtils.joinSegments(segments, language: "en", silenceThreshold: 1.0, speakerDisplayNames: names)
        XCTAssertEqual(afterUpdate, "A: Hello\nB: new speaker still talking")
    }

    func testJoinConfirmedSegmentsJapaneseSpeakerChange() {
        let segments = [
            ConfirmedSegment(text: "おはようございます", precedingSilence: 0, speaker: "A"),
            ConfirmedSegment(text: "おはよう", precedingSilence: 0.5, speaker: "B"),
        ]
        let names = ["A": "A", "B": "B"]
        let result = TranscriptionUtils.joinSegments(segments, language: "ja", silenceThreshold: 1.0, speakerDisplayNames: names)
        XCTAssertEqual(result, "A: おはようございます\nB: おはよう")
    }

    // MARK: - joinSegments with display names

    func testJoinSegmentsResolvesDisplayNames() {
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A"),
            ConfirmedSegment(text: "Hi there", precedingSilence: 0.5, speaker: "B"),
        ]
        let names = ["A": "Alice", "B": "Bob"]
        let result = TranscriptionUtils.joinSegments(
            segments, language: "en", silenceThreshold: 1.0, speakerDisplayNames: names
        )
        XCTAssertEqual(result, "Alice: Hello\nBob: Hi there")
    }

    func testJoinSegmentsFallsBackToUnknownWhenNoDisplayName() {
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A"),
            ConfirmedSegment(text: "Hi", precedingSilence: 0.5, speaker: "C"),
        ]
        let names = ["A": "Alice"]  // C has no mapping
        let result = TranscriptionUtils.joinSegments(
            segments, language: "en", silenceThreshold: 1.0, speakerDisplayNames: names
        )
        XCTAssertEqual(result, "Alice: Hello\nUnknown: Hi")
    }

    func testJoinSegmentsEmptyDisplayNamesUsesUnknown() {
        let segments = [
            ConfirmedSegment(text: "Hello", precedingSilence: 0, speaker: "A"),
            ConfirmedSegment(text: "Hi", precedingSilence: 0.5, speaker: "B"),
        ]
        let result = TranscriptionUtils.joinSegments(
            segments, language: "en", silenceThreshold: 1.0, speakerDisplayNames: [:]
        )
        XCTAssertEqual(result, "Unknown: Hello\nUnknown: Hi")
    }

    // MARK: - ConfirmedSegment isUserCorrected and originalSpeaker

    func testConfirmedSegmentDefaultsIsUserCorrectedFalse() {
        let segment = ConfirmedSegment(text: "Hello", speaker: "A")
        XCTAssertFalse(segment.isUserCorrected)
        XCTAssertNil(segment.originalSpeaker)
    }

    func testConfirmedSegmentIsUserCorrectedCanBeSet() {
        var segment = ConfirmedSegment(text: "Hello", speaker: "A")
        segment.isUserCorrected = true
        segment.originalSpeaker = "B"
        XCTAssertTrue(segment.isUserCorrected)
        XCTAssertEqual(segment.originalSpeaker, "B")
    }

    func testConfirmedSegmentTextIsMutable() {
        var segment = ConfirmedSegment(text: "Hello")
        segment.text = "World"
        XCTAssertEqual(segment.text, "World")
    }

    func testConfirmedSegmentPrecedingSilenceIsMutable() {
        var segment = ConfirmedSegment(text: "Hello", precedingSilence: 2.0)
        segment.precedingSilence = 0
        XCTAssertEqual(segment.precedingSilence, 0)
    }

    func testConfirmedSegmentInitWithAllParameters() {
        let segment = ConfirmedSegment(
            text: "Hello",
            precedingSilence: 1.0,
            speaker: "A",
            speakerConfidence: 0.9,
            isUserCorrected: true,
            originalSpeaker: "B"
        )
        XCTAssertEqual(segment.text, "Hello")
        XCTAssertEqual(segment.precedingSilence, 1.0)
        XCTAssertEqual(segment.speaker, "A")
        XCTAssertEqual(segment.speakerConfidence, 0.9)
        XCTAssertTrue(segment.isUserCorrected)
        XCTAssertEqual(segment.originalSpeaker, "B")
    }
}
