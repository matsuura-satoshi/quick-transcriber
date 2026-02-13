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
}
