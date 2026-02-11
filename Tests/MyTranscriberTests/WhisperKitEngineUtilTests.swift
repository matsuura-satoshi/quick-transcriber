import XCTest
@testable import MyTranscriberLib

final class WhisperKitEngineUtilTests: XCTestCase {

    func testCleanSegmentTextRemovesSpecialTokens() {
        let input = "<|startoftranscript|>Hello world<|endoftext|>"
        let result = WhisperKitEngine.cleanSegmentText(input)
        XCTAssertEqual(result, "Hello world")
    }

    func testCleanSegmentTextRemovesTimestampTokens() {
        let input = "<|0.00|>Hello<|2.50|>"
        let result = WhisperKitEngine.cleanSegmentText(input)
        XCTAssertEqual(result, "Hello")
    }

    func testCleanSegmentTextRemovesUnicodeReplacement() {
        let input = "Hello\u{FFFD}World"
        let result = WhisperKitEngine.cleanSegmentText(input)
        XCTAssertEqual(result, "HelloWorld")
    }

    func testCleanSegmentTextTrimsWhitespace() {
        let input = "  Hello World  "
        let result = WhisperKitEngine.cleanSegmentText(input)
        XCTAssertEqual(result, "Hello World")
    }

    func testCleanSegmentTextHandlesEmpty() {
        let result = WhisperKitEngine.cleanSegmentText("")
        XCTAssertEqual(result, "")
    }

    func testCleanSegmentTextOnlySpecialTokens() {
        let input = "<|startoftranscript|><|en|><|transcribe|>"
        let result = WhisperKitEngine.cleanSegmentText(input)
        XCTAssertEqual(result, "")
    }

    func testCleanSegmentTextPreservesNormalText() {
        let input = "The quick brown fox"
        let result = WhisperKitEngine.cleanSegmentText(input)
        XCTAssertEqual(result, "The quick brown fox")
    }

    func testCleanSegmentTextJapanese() {
        let input = "<|ja|>こんにちは世界<|endoftext|>"
        let result = WhisperKitEngine.cleanSegmentText(input)
        XCTAssertEqual(result, "こんにちは世界")
    }

    func testCleanSegmentTextMultipleReplacements() {
        let input = "<|0.00|>\u{FFFD}Hello <|notranslate|> World\u{FFFD}<|2.50|>"
        let result = WhisperKitEngine.cleanSegmentText(input)
        XCTAssertEqual(result, "Hello  World")
    }
}
