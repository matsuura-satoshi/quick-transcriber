import XCTest
@testable import QuickTranscriberLib

final class ZoomReferenceCleanerTests: XCTestCase {
    func test_normalize_stripsZoomCharLevelPeriods() {
        // Zoom artefact: "。" inserted between kana mid-word.
        let zoom = "あ。れか。も。し。れ。な。い。で。す。が。"
        let cleaned = ZoomReferenceCleaner.normalize(zoom)
        XCTAssertEqual(cleaned, "あれかもしれないですが")
    }

    func test_normalize_removesAllPunctuationAndWhitespace() {
        let input = "こんにちは。  元気ですか？\nそうですね、おはよう！"
        let cleaned = ZoomReferenceCleaner.normalize(input)
        XCTAssertEqual(cleaned, "こんにちは元気ですかそうですねおはよう")
    }

    func test_normalize_preservesContentChars() {
        let input = "東大は1774件、灯台じゃない。"
        let cleaned = ZoomReferenceCleaner.normalize(input)
        XCTAssertEqual(cleaned, "東大は1774件灯台じゃない")
    }

    func test_normalize_handlesEmptyInput() {
        XCTAssertEqual(ZoomReferenceCleaner.normalize(""), "")
    }

    func test_normalize_handlesAsciiPunctuation() {
        let input = "Hello, world! How are you? I'm fine."
        let cleaned = ZoomReferenceCleaner.normalize(input)
        XCTAssertEqual(cleaned, "HelloworldHowareyouI'mfine")
    }

    func test_concatenateZoomSegments_joinsAllText() {
        let segments = [
            ZoomSegment(speaker: "A", startSeconds: 0, endSeconds: 1, text: "おはよう。"),
            ZoomSegment(speaker: "B", startSeconds: 1, endSeconds: 2, text: "こんにちは"),
        ]
        let concat = ZoomReferenceCleaner.concatenateText(of: segments)
        XCTAssertEqual(concat, "おはよう。\nこんにちは")
    }

    func test_cer_returnsZeroForIdenticalNormalizedStrings() {
        let cer = ZoomReferenceCleaner.cer(
            predicted: "おはようございます",
            reference: "おはよう。ございます。"
        )
        XCTAssertEqual(cer, 0.0, accuracy: 0.001)
    }

    func test_cer_handlesSubstitutionsAndInsertions() {
        // Reference (normalized): "おはよう"
        // Predicted: "おはう" (2 ops: substitute よ→う, then nothing... actually:
        //   "おはう" → "おはよう": insert よ at pos 2, then substitute う→う (no), so 1 edit
        //   Or insert+match. Levenshtein → 1.
        let cer = ZoomReferenceCleaner.cer(
            predicted: "おはう",
            reference: "おはよう"
        )
        XCTAssertEqual(cer, 0.25, accuracy: 0.001) // 1 / 4
    }
}
