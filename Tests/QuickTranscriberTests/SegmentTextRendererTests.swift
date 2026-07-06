import XCTest
@testable import QuickTranscriberLib

final class SegmentTextRendererTests: XCTestCase {

    // MARK: - layout: 4 優先度の改行判定

    func testLayoutFirstSegmentHasNoSeparator() {
        let layouts = SegmentTextRenderer.layout(
            [ConfirmedSegment(text: "Hello")],
            language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(layouts, [SegmentTextRenderer.SegmentLayout(
            segmentIndex: 0, separator: "", label: nil, labelConfidence: nil, text: "Hello")])
    }

    func testLayoutFirstSpeakerSegmentGetsLabelWithoutSeparator() {
        let layouts = SegmentTextRenderer.layout(
            [ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.9)],
            language: "en", silenceThreshold: 1.0,
            speakerDisplayNames: ["A": "Alice"])
        XCTAssertEqual(layouts, [SegmentTextRenderer.SegmentLayout(
            segmentIndex: 0, separator: "", label: "Alice: ", labelConfidence: 0.9, text: "Hello")])
    }

    func testLayoutSpeakerChangeGetsLabeledNewline() {
        let layouts = SegmentTextRenderer.layout(
            [
                ConfirmedSegment(text: "Hello", speaker: "A"),
                ConfirmedSegment(text: "World", speaker: "B", speakerConfidence: 0.4),
            ],
            language: "en", silenceThreshold: 1.0,
            speakerDisplayNames: ["A": "Alice", "B": "Bob"])
        XCTAssertEqual(layouts[1], SegmentTextRenderer.SegmentLayout(
            segmentIndex: 1, separator: "\n", label: "Bob: ", labelConfidence: 0.4, text: "World"))
    }

    func testLayoutSameSpeakerContinuesInline() {
        let layouts = SegmentTextRenderer.layout(
            [
                ConfirmedSegment(text: "Hello", speaker: "A"),
                ConfirmedSegment(text: "world", speaker: "A"),
            ],
            language: "en", silenceThreshold: 1.0,
            speakerDisplayNames: ["A": "Alice"])
        XCTAssertEqual(layouts[1], SegmentTextRenderer.SegmentLayout(
            segmentIndex: 1, separator: " ", label: nil, labelConfidence: nil, text: "world"))
    }

    func testLayoutUnknownSpeakerNameFallsBackToUnknown() {
        let layouts = SegmentTextRenderer.layout(
            [ConfirmedSegment(text: "Hi", speaker: "X")],
            language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(layouts[0].label, "Unknown: ")
    }

    func testLayoutSilenceBreakAtThreshold() {
        let layouts = SegmentTextRenderer.layout(
            [
                ConfirmedSegment(text: "Hello"),
                ConfirmedSegment(text: "world", precedingSilence: 1.0),
            ],
            language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(layouts[1].separator, "\n")
    }

    func testLayoutSentenceEndBreakEN() {
        let layouts = SegmentTextRenderer.layout(
            [ConfirmedSegment(text: "Hello."), ConfirmedSegment(text: "World")],
            language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(layouts[1].separator, "\n")
    }

    func testLayoutSentenceEndBreakJA() {
        let layouts = SegmentTextRenderer.layout(
            [ConfirmedSegment(text: "晴れです。"), ConfirmedSegment(text: "明日も")],
            language: "ja", silenceThreshold: 1.0)
        XCTAssertEqual(layouts[1].separator, "\n")
    }

    func testLayoutInlineSeparatorIsEmptyForJA() {
        let layouts = SegmentTextRenderer.layout(
            [ConfirmedSegment(text: "今日は"), ConfirmedSegment(text: "いい天気")],
            language: "ja", silenceThreshold: 1.0)
        XCTAssertEqual(layouts[1].separator, "")
    }

    func testLayoutSkipsEmptySegmentsButKeepsOriginalIndices() {
        let layouts = SegmentTextRenderer.layout(
            [
                ConfirmedSegment(text: "Hello"),
                ConfirmedSegment(text: "", precedingSilence: 0.5),
                ConfirmedSegment(text: "world", precedingSilence: 0.3),
            ],
            language: "en", silenceThreshold: 1.0)
        XCTAssertEqual(layouts.map(\.segmentIndex), [0, 2])
        XCTAssertEqual(layouts.map(\.text), ["Hello", "world"])
    }

    /// 統一後の挙動を固定: 先頭セグメントが空テキストなら「最初に描画されるセグメント」が
    /// 先頭扱いになる（旧 joinSegments は配列 index 0 基準だったため先頭に改行/空白が付いた。
    /// attributed 版の意味論に統一。本番では空テキストセグメントは emit されず到達不能）。
    func testLayoutEmptyFirstSegmentTreatsNextRenderedAsFirst() {
        let layouts = SegmentTextRenderer.layout(
            [
                ConfirmedSegment(text: ""),
                ConfirmedSegment(text: "Hello", precedingSilence: 2.0, speaker: "A"),
            ],
            language: "en", silenceThreshold: 1.0,
            speakerDisplayNames: ["A": "Alice"])
        XCTAssertEqual(layouts, [SegmentTextRenderer.SegmentLayout(
            segmentIndex: 1, separator: "", label: "Alice: ", labelConfidence: nil, text: "Hello")])
    }

    func testLayoutSpeakerlessFirstThenSpeakerGetsLabel() {
        // hasSpeakers な列で先頭の speaker が nil の場合: 先頭はラベルなし、
        // 次の speaker 付きセグメントで初ラベル行
        let layouts = SegmentTextRenderer.layout(
            [
                ConfirmedSegment(text: "Hello"),
                ConfirmedSegment(text: "World", speaker: "A"),
            ],
            language: "en", silenceThreshold: 1.0,
            speakerDisplayNames: ["A": "Alice"])
        XCTAssertNil(layouts[0].label)
        XCTAssertEqual(layouts[1].separator, "\n")
        XCTAssertEqual(layouts[1].label, "Alice: ")
    }

    // MARK: - plainText

    func testPlainTextEmptySegments() {
        XCTAssertEqual(
            SegmentTextRenderer.plainText([], language: "en", silenceThreshold: 1.0), "")
    }

    func testPlainTextSpeakerFixture() {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A"),
            ConfirmedSegment(text: "there", speaker: "A"),
            ConfirmedSegment(text: "World", speaker: "B"),
            ConfirmedSegment(text: "Bye.", precedingSilence: 2.0, speaker: "B"),
            ConfirmedSegment(text: "End", speaker: "B"),
        ]
        let result = SegmentTextRenderer.plainText(
            segments, language: "en", silenceThreshold: 1.0,
            speakerDisplayNames: ["A": "Alice", "B": "Bob"])
        XCTAssertEqual(result, "Alice: Hello there\nBob: World\nBye.\nEnd")
    }

    func testPlainTextJAFixture() {
        let segments = [
            ConfirmedSegment(text: "今日は"),
            ConfirmedSegment(text: "いい天気です。"),
            ConfirmedSegment(text: "明日も晴れ"),
        ]
        let result = SegmentTextRenderer.plainText(segments, language: "ja", silenceThreshold: 1.0)
        XCTAssertEqual(result, "今日はいい天気です。\n明日も晴れ")
    }
}
