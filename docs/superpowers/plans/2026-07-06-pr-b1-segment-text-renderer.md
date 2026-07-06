# PR-B1: SegmentTextRenderer 統合 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** セグメント→テキスト変換（4 優先度の改行判定）の 3 層重複実装を `SegmentTextRenderer` の単一実装に統合し、Engine をセグメントのみの emit に、VM の `confirmedText` を stored `@Published` にする。

**Architecture:** 新設 `SegmentTextRenderer.layout()` が改行判定の唯一の実装となり、plain テキスト・`NSAttributedString`・`SegmentCharacterMap` は全て同一の layout 決定から導出される（オフサット不整合の構造的排除）。`TranscriptionUtils.joinSegments` と `TranscriptionTextView.buildAttributedStringFromSegments` は公開シグネチャを維持したまま内部委譲に置き換え、既存テストをゴールデンテストとして流用する。

**Tech Stack:** Swift / SwiftUI + AppKit (NSTextView) / XCTest。ターゲットは `QuickTranscriberLib` 単一モジュール（Rendering/ は新設フォルダで、モジュール境界は増えない）。

**Spec:** `docs/superpowers/specs/2026-07-02-simplification-refactoring-design.md` の「Part B1」

## Global Constraints

- ブランチ: `refactor/simplification-pr-b1`（最新 main から作成。実行時は superpowers:using-git-worktrees で隔離ワークスペースを確保）
- テストゲート: `swift test --filter QuickTranscriberTests`（モデル不要、~2秒）。**既知の失敗 `ManualModeStabilityTests.testCorrection_trustedLearningReducesFutureMisidentification` は main 由来で本 PR と無関係（PR #86 とテスト期待の不整合）。この 1 件以外に失敗ゼロ**が合格条件
- 公開シグネチャ維持（ゴールデンテストの前提）: `TranscriptionUtils.joinSegments(_:language:silenceThreshold:speakerDisplayNames:)` / `TranscriptionUtils.joinSegments(_:language:)` / `TranscriptionTextView.buildAttributedStringFromSegments(...)`
- `Constants.Version.patch` は PR 番号に更新（Task 6）。**PR のコミット内でのみ**変更する。次 PR は #88 の見込みだが、PR 作成時に `gh pr list --state all --limit 1` で実番号を確認して合わせること
- ファイル削除は `trash` を使う（`rm` 禁止。このマシンでは rm は trash の alias だが `-f` が失敗する）
- macOS GUI アプリのため実行時デバッグは `NSLog`（`print()` は出ない）
- テスト実行には Xcode が必要（Command Line Tools のみでは不可）

## 事前調査で確定した事実（実装者は再調査不要）

1. **改行判定の 3 実装**: ①`TranscriptionUtils.joinSegments`（`Engines/TranscriptionUtils.swift:148-201`、plain）②`TranscriptionTextView.buildAttributedStringFromSegments`（`Views/TranscriptionTextView.swift:329-458`、attributed+map）③Engine の `processChunk` 内 join（`Engines/ChunkedWhisperEngine.swift:457-461`）
2. **既存の plain/attributed 挙動差（先頭空セグメント edge）**: `joinSegments` は「配列 index 0」を先頭特別扱いするため、先頭セグメントが空テキストだと 2 番目のセグメントが優先度チェーンに落ち、出力の先頭に `"\n"` や `" "` が付く。attributed 版は「result が空」を先頭判定に使うためこの問題がない。**統合実装は attributed 側の意味論（最初に描画されるセグメント = 先頭）に統一する**。この edge を固定するゴールデンテストは存在せず（47 件中、空セグメントは中間位置の `testJoinConfirmedSegmentsSkipsEmpty` のみ）、本番でも Engine/VM は空テキストのセグメントを emit しないため到達不能
3. **`TranscriptionState` の emit 箇所は 1 箇所のみ**: `ChunkedWhisperEngine.processChunk`（`ChunkedWhisperEngine.swift:463`）。`TranscriptionService` はパススルー。file 転写も同じ `processChunk` 経路
4. **`MockTranscriptionEngine` は state を構築しない**（`simulateStateChange` でテストから受け取るだけ）。spec の「モックをセグメント emit に更新」は、**テスト側の `TranscriptionState` 構築 22 箇所**（ConfidenceColoringTests ×3 / SpeakerReassignmentTests ×3 / TranscriptionViewModelTests ×16）の移行を意味する。読み取り側は RetroactiveUpdateGuardTests / QualityFilterTests / ChunkedWhisperEngineTests / ConfidenceColoringTests:366
5. **VM の `confirmedText` 依存経路**: computed property（`TranscriptionViewModel.swift:41-49`）。segments の変更は ①代入（applyIncomingState:661 / clearText:287 / switchLanguage:262）②append（saveUnconfirmedText:753）③coordinator への `&confirmedSegments` inout 渡し（executeMerge / splitSegment / reassignSpeakerForBlock / reassignSpeakerForSelection）。表示名は `syncSpeakerState()`（21 箇所から呼ばれる）と init 内 `$activeSpeakers` sink（line 172）が代入。**inout の書き戻しと直接代入はどちらも property の `didSet` を発火させる**ため、`didSet` が単一チョークポイントになる
6. **`TranscriptionTextView` の非セグメント分岐**（`updateNSView` の else 側、line 236-261）は「segments が空で confirmedText が非空」の場合のみ意味を持つが、B1 後は confirmedText がセグメント由来になるためこの状態は不可能になり、削除できる

---

### Task 1: SegmentTextRenderer 新設（layout コア + plainText）と joinSegments の委譲

**Files:**
- Create: `Sources/QuickTranscriber/Rendering/SegmentTextRenderer.swift`
- Create: `Tests/QuickTranscriberTests/SegmentTextRendererTests.swift`
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionUtils.swift:148-201`（joinSegments 本体を委譲に置換）

**Interfaces:**
- Consumes: `ConfirmedSegment`（既存）、`Constants.Translation.sentenceEndersJA/EN`（既存、`Set<Character>`）
- Produces:
  - `SegmentTextRenderer.SegmentLayout`（struct: `segmentIndex: Int, separator: String, label: String?, labelConfidence: Float?, text: String`）
  - `SegmentTextRenderer.layout(_ segments: [ConfirmedSegment], language: String, silenceThreshold: TimeInterval, speakerDisplayNames: [String: String] = [:]) -> [SegmentLayout]`
  - `SegmentTextRenderer.plainText(_ segments: [ConfirmedSegment], language: String, silenceThreshold: TimeInterval, speakerDisplayNames: [String: String] = [:]) -> String`
  - Task 2 が同ファイルに `render(...)`（attributed+map）を追加する

- [ ] **Step 1: 失敗するテストを書く**

`Tests/QuickTranscriberTests/SegmentTextRendererTests.swift` を新規作成:

```swift
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
```

- [ ] **Step 2: テストが失敗（コンパイルエラー）することを確認**

Run: `swift test --filter SegmentTextRendererTests`
Expected: FAIL — `cannot find 'SegmentTextRenderer' in scope`

- [ ] **Step 3: SegmentTextRenderer を実装**

`Sources/QuickTranscriber/Rendering/SegmentTextRenderer.swift` を新規作成（`Rendering/` ディレクトリも新設）:

```swift
import Foundation

/// セグメント列 → 表示テキスト変換の単一実装。
///
/// 4 優先度の改行判定（1. 話者交代 → 2. 沈黙 → 3. 文末 → 4. インライン）は
/// `layout()` にのみ存在する。plain テキスト・NSAttributedString・
/// SegmentCharacterMap は全て同一の layout 決定から導出されるため、
/// 文字オフセットが構造的に一致する。
public enum SegmentTextRenderer {

    /// 1 セグメント分のレイアウト決定。
    public struct SegmentLayout: Equatable {
        /// 元 segments 配列内の index（空テキストのセグメントは layout に現れない）
        public let segmentIndex: Int
        /// ラベル（無ければ本文）の前に挿入する文字列（"" / "\n" / " "）
        public let separator: String
        /// 話者ラベル（"Alice: "）。話者行の先頭のみ non-nil
        public let label: String?
        /// ラベル色付け用の話者確信度
        public let labelConfidence: Float?
        /// セグメント本文
        public let text: String
    }

    // MARK: - Layout（改行判定の単一実装）

    public static func layout(
        _ segments: [ConfirmedSegment],
        language: String,
        silenceThreshold: TimeInterval,
        speakerDisplayNames: [String: String] = [:]
    ) -> [SegmentLayout] {
        let hasSpeakers = segments.contains { $0.speaker != nil }
        let sentenceEnders: Set<Character> = (language == "ja")
            ? Constants.Translation.sentenceEndersJA : Constants.Translation.sentenceEndersEN
        let inlineSeparator = (language == "ja") ? "" : " "

        var layouts: [SegmentLayout] = []
        var currentSpeaker: String? = nil
        var lastChar: Character? = nil

        for (index, segment) in segments.enumerated() {
            guard !segment.text.isEmpty else { continue }
            let isFirst = layouts.isEmpty

            let separator: String
            var label: String? = nil
            var labelConfidence: Float? = nil

            if hasSpeakers, let speaker = segment.speaker,
               isFirst || speaker != currentSpeaker {
                // 先頭 or Priority 1: 話者交代 → ラベル付き新行
                separator = isFirst ? "" : "\n"
                label = "\(speakerDisplayNames[speaker] ?? "Unknown"): "
                labelConfidence = segment.speakerConfidence
                currentSpeaker = speaker
            } else if isFirst {
                separator = ""
            } else if segment.precedingSilence >= silenceThreshold {
                // Priority 2: 沈黙閾値
                separator = "\n"
            } else if let last = lastChar, sentenceEnders.contains(last) {
                // Priority 3: 文末
                separator = "\n"
            } else {
                // Priority 4: インライン
                separator = inlineSeparator
            }

            layouts.append(SegmentLayout(
                segmentIndex: index,
                separator: separator,
                label: label,
                labelConfidence: labelConfidence,
                text: segment.text
            ))
            lastChar = segment.text.last
        }
        return layouts
    }

    // MARK: - Plain

    public static func plainText(
        _ segments: [ConfirmedSegment],
        language: String,
        silenceThreshold: TimeInterval,
        speakerDisplayNames: [String: String] = [:]
    ) -> String {
        var result = ""
        for piece in layout(
            segments, language: language,
            silenceThreshold: silenceThreshold,
            speakerDisplayNames: speakerDisplayNames
        ) {
            result += piece.separator
            if let label = piece.label { result += label }
            result += piece.text
        }
        return result
    }
}
```

実装メモ:
- 旧 `joinSegments` の優先度 3 は `result.last` を見ていたが、result の末尾は常に直前セグメントの本文末尾なので `lastChar` 追跡と等価（attributed 版と同じ方式）
- `hasSpeakers` は空テキストセグメントを含む全配列で判定する（旧 2 実装とも同じ）

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter SegmentTextRendererTests`
Expected: PASS（全 16 件）

- [ ] **Step 5: TranscriptionUtils.joinSegments を委譲に置換**

`Sources/QuickTranscriber/Engines/TranscriptionUtils.swift` の `joinSegments`（line 146-201）の**本体だけ**を置き換える（doc コメントとシグネチャは維持）:

```swift
    /// Join confirmed segments with speaker labels, silence-based, and punctuation-based line breaks.
    /// Priority: 1) Speaker change → labeled newline  2) Silence threshold → newline  3) Sentence end → newline  4) Inline
    /// 実装は SegmentTextRenderer.layout に委譲（改行判定の単一実装）。
    public static func joinSegments(
        _ segments: [ConfirmedSegment],
        language: String,
        silenceThreshold: TimeInterval = 1.0,
        speakerDisplayNames: [String: String] = [:]
    ) -> String {
        SegmentTextRenderer.plainText(
            segments,
            language: language,
            silenceThreshold: silenceThreshold,
            speakerDisplayNames: speakerDisplayNames
        )
    }
```

`joinSegments(_ segments: [String], language: String)`（line 204-207）は変更しない（既に ConfirmedSegment 版に委譲している）。

- [ ] **Step 6: ゴールデンテストで移植の正しさを検証**

Run: `swift test --filter TranscriptionUtilsTests`
Expected: PASS（47 件全て）— 公開挙動が不変であることの直接証明

Run: `swift test --filter QuickTranscriberTests`
Expected: 既知の 1 件（ManualModeStabilityTests.testCorrection_trustedLearningReducesFutureMisidentification）以外 PASS

- [ ] **Step 7: コミット**

```bash
git add Sources/QuickTranscriber/Rendering/SegmentTextRenderer.swift Tests/QuickTranscriberTests/SegmentTextRendererTests.swift Sources/QuickTranscriber/Engines/TranscriptionUtils.swift
git commit -m "refactor: SegmentTextRenderer 新設 — 改行判定を単一実装化し joinSegments を委譲"
```

---

### Task 2: attributed + SegmentCharacterMap を renderer に統合、TextView を委譲

**Files:**
- Modify: `Sources/QuickTranscriber/Rendering/SegmentTextRenderer.swift`（`render(...)` と属性ヘルパーを追加、import AppKit に変更）
- Create: `Sources/QuickTranscriber/Rendering/SegmentCharacterMap.swift`（TranscriptionTextView.swift:4-48 からの純移動）
- Modify: `Sources/QuickTranscriber/Views/TranscriptionTextView.swift`（`buildAttributedStringFromSegments` を委譲に置換、移動した型・不要になった private を削除）
- Modify: `Tests/QuickTranscriberTests/SegmentTextRendererTests.swift`（オフセット整合性テスト追加）

**Interfaces:**
- Consumes: Task 1 の `SegmentTextRenderer.layout` / `SegmentLayout`
- Produces:
  - `SegmentTextRenderer.render(_ segments: [ConfirmedSegment], language: String, silenceThreshold: TimeInterval, fontSize: CGFloat, unconfirmed: String, speakerDisplayNames: [String: String] = [:]) -> (NSAttributedString, SegmentCharacterMap)`
  - `SegmentTextRenderer.makeParagraphStyle() -> NSMutableParagraphStyle`
  - `SegmentTextRenderer.confirmedAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any]`
  - `TranscriptionTextView.buildAttributedStringFromSegments(...)` は**シグネチャ不変のまま** render への委譲シムとして存続（ConfidenceColoringTests がゴールデンとして参照）

- [ ] **Step 1: 失敗するテストを書く（オフセット整合性）**

`SegmentTextRendererTests.swift` に追加:

```swift
    // MARK: - render: plain / attributed / characterMap のオフセット整合性

    private func offsetFixture() -> ([ConfirmedSegment], [String: String]) {
        let segments = [
            ConfirmedSegment(text: "Hello", speaker: "A", speakerConfidence: 0.9),
            ConfirmedSegment(text: "there", speaker: "A"),
            ConfirmedSegment(text: "World!", speaker: "B", speakerConfidence: 0.3),
            ConfirmedSegment(text: "Next", speaker: "B"),
            ConfirmedSegment(text: "Far", precedingSilence: 2.0, speaker: "B"),
        ]
        return (segments, ["A": "Alice", "B": "Bob"])
    }

    func testRenderAttributedTextEqualsPlainText() {
        let (segments, names) = offsetFixture()
        let plain = SegmentTextRenderer.plainText(
            segments, language: "en", silenceThreshold: 1.0, speakerDisplayNames: names)
        let (attributed, _) = SegmentTextRenderer.render(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", speakerDisplayNames: names)
        XCTAssertEqual(attributed.string, plain)
    }

    func testRenderCharacterMapRangesPointAtSegmentTexts() {
        let (segments, names) = offsetFixture()
        let plain = SegmentTextRenderer.plainText(
            segments, language: "en", silenceThreshold: 1.0, speakerDisplayNames: names)
        let (attributed, map) = SegmentTextRenderer.render(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", speakerDisplayNames: names)

        XCTAssertEqual(map.entries.count, segments.count)
        let attributedNS = attributed.string as NSString
        let plainNS = plain as NSString
        for entry in map.entries {
            let expected = segments[entry.segmentIndex].text
            // attributed / plain の両方で characterRange が同一の本文を指す
            XCTAssertEqual(attributedNS.substring(with: entry.characterRange), expected)
            XCTAssertEqual(plainNS.substring(with: entry.characterRange), expected)
            if let labelRange = entry.labelRange {
                let label = attributedNS.substring(with: labelRange)
                XCTAssertEqual(plainNS.substring(with: labelRange), label)
                XCTAssertTrue(label.hasSuffix(": "), "label は 'Name: ' 形式: \(label)")
            }
        }
    }

    func testRenderJAOffsets() {
        let segments = [
            ConfirmedSegment(text: "今日は", speaker: "A"),
            ConfirmedSegment(text: "いい天気。", speaker: "A"),
            ConfirmedSegment(text: "明日も", speaker: "B"),
        ]
        let names = ["A": "上東", "B": "松浦"]
        let plain = SegmentTextRenderer.plainText(
            segments, language: "ja", silenceThreshold: 1.0, speakerDisplayNames: names)
        let (attributed, map) = SegmentTextRenderer.render(
            segments, language: "ja", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "", speakerDisplayNames: names)
        XCTAssertEqual(attributed.string, plain)
        for entry in map.entries {
            XCTAssertEqual(
                (attributed.string as NSString).substring(with: entry.characterRange),
                segments[entry.segmentIndex].text)
        }
    }

    func testRenderAppendsUnconfirmedAfterNewline() {
        let (segments, names) = offsetFixture()
        let plain = SegmentTextRenderer.plainText(
            segments, language: "en", silenceThreshold: 1.0, speakerDisplayNames: names)
        let (attributed, _) = SegmentTextRenderer.render(
            segments, language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "typing...", speakerDisplayNames: names)
        XCTAssertEqual(attributed.string, plain + "\ntyping...")
    }

    func testRenderUnconfirmedOnlyHasNoLeadingNewline() {
        let (attributed, map) = SegmentTextRenderer.render(
            [], language: "en", silenceThreshold: 1.0,
            fontSize: 15, unconfirmed: "typing...")
        XCTAssertEqual(attributed.string, "typing...")
        XCTAssertTrue(map.entries.isEmpty)
    }

    func testRenderEmptyEverything() {
        let (attributed, map) = SegmentTextRenderer.render(
            [], language: "en", silenceThreshold: 1.0, fontSize: 15, unconfirmed: "")
        XCTAssertEqual(attributed.length, 0)
        XCTAssertTrue(map.entries.isEmpty)
    }
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter SegmentTextRendererTests`
Expected: FAIL — `type 'SegmentTextRenderer' has no member 'render'`

- [ ] **Step 3: SegmentCharacterMap を Rendering/ に移動**

`Sources/QuickTranscriber/Rendering/SegmentCharacterMap.swift` を新規作成し、`TranscriptionTextView.swift:4-48` の `public struct SegmentCharacterMap { ... }` を**一字一句そのまま**移動する（先頭に `import Foundation` を付ける）。`TranscriptionTextView.swift` からは削除。

- [ ] **Step 4: render と属性ヘルパーを実装**

`SegmentTextRenderer.swift` の `import Foundation` を `import AppKit` に変更し、以下を追加:

```swift
    // MARK: - Attributed + CharacterMap

    static let lowConfidenceThreshold: Float = Constants.Embedding.similarityThreshold

    /// segments と unconfirmed から attributed テキストと characterMap を生成する。
    /// テキスト内容は plainText(同引数) + （unconfirmed があれば "\n" + unconfirmed）と一致する。
    public static func render(
        _ segments: [ConfirmedSegment],
        language: String,
        silenceThreshold: TimeInterval,
        fontSize: CGFloat,
        unconfirmed: String,
        speakerDisplayNames: [String: String] = [:]
    ) -> (NSAttributedString, SegmentCharacterMap) {
        let result = NSMutableAttributedString()
        var map = SegmentCharacterMap()
        let normalAttrs = confirmedAttributes(fontSize: fontSize)

        for piece in layout(
            segments, language: language,
            silenceThreshold: silenceThreshold,
            speakerDisplayNames: speakerDisplayNames
        ) {
            if !piece.separator.isEmpty {
                result.append(NSAttributedString(string: piece.separator, attributes: normalAttrs))
            }
            var labelRange: NSRange? = nil
            if let label = piece.label {
                let labelStart = result.length
                result.append(NSAttributedString(
                    string: label,
                    attributes: speakerLabelAttributes(fontSize: fontSize, confidence: piece.labelConfidence)
                ))
                labelRange = NSRange(location: labelStart, length: (label as NSString).length)
            }
            let textStart = result.length
            result.append(NSAttributedString(string: piece.text, attributes: normalAttrs))
            map.entries.append(SegmentCharacterMap.Entry(
                segmentIndex: piece.segmentIndex,
                characterRange: NSRange(location: textStart, length: (piece.text as NSString).length),
                labelRange: labelRange
            ))
        }

        if !unconfirmed.isEmpty {
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n", attributes: normalAttrs))
            }
            result.append(unconfirmedAttributedString(unconfirmed, fontSize: fontSize))
        }
        return (result, map)
    }

    // MARK: - Attributes

    static func makeParagraphStyle() -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = 4
        return paragraphStyle
    }

    static func confirmedAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: makeParagraphStyle()
        ]
    }

    static func speakerLabelAttributes(fontSize: CGFloat, confidence: Float?) -> [NSAttributedString.Key: Any] {
        let color: NSColor
        if let conf = confidence, conf < lowConfidenceThreshold {
            color = .secondaryLabelColor
        } else {
            color = .labelColor
        }
        return [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: makeParagraphStyle()
        ]
    }

    static func unconfirmedAttributedString(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let italicFont = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: fontSize),
            toHaveTrait: .italicFontMask
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: italicFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .backgroundColor: NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.3),
            .paragraphStyle: makeParagraphStyle()
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }
```

挙動差の注記（どちらも既存テスト非依存・本番到達不能）:
- 旧 attributed 版は「segments 非空だが全て空テキスト + unconfirmed 有り」で先頭に `"\n"` が付いたが、統合版は `result.length > 0` 判定なので付かない
- 旧版の優先度 2/3 は `"\n" + text` を 1 回で append していたが、統合版は separator と本文を分けて append する。属性は同一（normalAttrs）なので生成される attributed string は文字・属性とも等価

- [ ] **Step 5: TranscriptionTextView を委譲シムに置換**

`TranscriptionTextView.swift` で以下を実施:

1. `buildAttributedStringFromSegments`（line 329-458 相当）の本体を委譲に置換:

```swift
    /// Build an NSAttributedString from segments, coloring speaker labels by confidence.
    /// Returns a tuple of (attributed string, segment character map).
    /// 実装は SegmentTextRenderer.render に委譲（joinSegments と同一の layout を消費する）。
    static func buildAttributedStringFromSegments(
        _ segments: [ConfirmedSegment],
        language: String,
        silenceThreshold: TimeInterval,
        fontSize: CGFloat,
        unconfirmed: String,
        speakerDisplayNames: [String: String] = [:]
    ) -> (NSAttributedString, SegmentCharacterMap) {
        SegmentTextRenderer.render(
            segments,
            language: language,
            silenceThreshold: silenceThreshold,
            fontSize: fontSize,
            unconfirmed: unconfirmed,
            speakerDisplayNames: speakerDisplayNames
        )
    }
```

2. 不要になった private を削除し、残存参照を renderer に付け替える:
   - `speakerLabelAttributes` / `buildUnconfirmedAttributedString` / `lowConfidenceThreshold` → 削除（renderer に移った）
   - `makeParagraphStyle` / `confirmedAttributes` → TextView 内の残存呼び出し（updateNSView の else 分岐 line 247、`buildAttributedString` line 295）があるため、**本体を renderer への転送に置換**して存続:

```swift
    static func makeParagraphStyle() -> NSMutableParagraphStyle {
        SegmentTextRenderer.makeParagraphStyle()
    }

    static func confirmedAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        SegmentTextRenderer.confirmedAttributes(fontSize: fontSize)
    }
```

   - `buildAttributedString(confirmed:unconfirmed:fontSize:)`（line 287-307）は else 分岐がまだ使うため**この Task では残す**。内部の `buildUnconfirmedAttributedString` 呼び出しを `SegmentTextRenderer.unconfirmedAttributedString` に付け替える（Task 5 で分岐ごと削除する）

- [ ] **Step 6: ゴールデンテスト + 新テストで検証**

Run: `swift test --filter SegmentTextRendererTests`
Expected: PASS

Run: `swift test --filter ConfidenceColoringTests`
Expected: PASS（attributed 出力の属性・色分け挙動が不変であることの直接証明）

Run: `swift test --filter QuickTranscriberTests`
Expected: 既知の 1 件以外 PASS

- [ ] **Step 7: コミット**

```bash
git add Sources/QuickTranscriber/Rendering/ Sources/QuickTranscriber/Views/TranscriptionTextView.swift Tests/QuickTranscriberTests/SegmentTextRendererTests.swift
git commit -m "refactor: attributed 描画と SegmentCharacterMap を SegmentTextRenderer に統合"
```

---

### Task 3: TranscriptionState.confirmedText を削除（Engine はセグメントのみ emit）

**Files:**
- Modify: `Sources/QuickTranscriber/Engines/TranscriptionEngine.swift:17-29`（TranscriptionState 再定義）
- Modify: `Sources/QuickTranscriber/Engines/ChunkedWhisperEngine.swift:457-468`（join 削除、セグメントのみ emit）
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift:642-649`（テキスト→セグメント導出フォールバック削除）
- Modify: `Tests/QuickTranscriberTests/ConfidenceColoringTests.swift`（構築 3 箇所 + 読み取り 1 箇所）
- Modify: `Tests/QuickTranscriberTests/SpeakerReassignmentTests.swift`（構築 3 箇所）
- Modify: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift`（構築 16 箇所）
- Modify: `Tests/QuickTranscriberTests/RetroactiveUpdateGuardTests.swift`（読み取り 2 箇所）
- Modify: `Tests/QuickTranscriberTests/QualityFilterTests.swift`（読み取り 8 箇所）
- Modify: `Tests/QuickTranscriberTests/ChunkedWhisperEngineTests.swift`（読み取り 6 箇所）

**Interfaces:**
- Consumes: なし（削除タスク）
- Produces: `TranscriptionState(unconfirmedText: String, isRecording: Bool, confirmedSegments: [ConfirmedSegment] = [])` — 以降の全タスク・テストはこの形を使う
- 注: `MockTranscriptionEngine` は state をパススルーするだけなのでファイル自体の変更は不要（調査済み）

- [ ] **Step 1: TranscriptionState から confirmedText を削除**

`Sources/QuickTranscriber/Engines/TranscriptionEngine.swift:17-29` を置換:

```swift
public struct TranscriptionState: Sendable {
    public var unconfirmedText: String
    public var isRecording: Bool
    public var confirmedSegments: [ConfirmedSegment]

    public init(unconfirmedText: String, isRecording: Bool, confirmedSegments: [ConfirmedSegment] = []) {
        self.unconfirmedText = unconfirmedText
        self.isRecording = isRecording
        self.confirmedSegments = confirmedSegments
    }
}
```

- [ ] **Step 2: ビルドを赤にして影響箇所を列挙**

Run: `swift build 2>&1 | grep -c "error"`
Expected: 多数のコンパイルエラー（`confirmedText` 参照箇所）。これが事実上の failing test — 以降の Step で全箇所を潰す

- [ ] **Step 3: Engine の emit をセグメントのみに**

`ChunkedWhisperEngine.swift:457-468` を置換（`TranscriptionUtils.joinSegments` 呼び出しブロックを削除）:

```swift
            LatencyInstrumentation.mark(.emitToUI, utteranceId: utteranceId)
            onStateChange(TranscriptionState(
                unconfirmedText: "",
                isRecording: true,
                confirmedSegments: confirmedSegments
            ))
```

- [ ] **Step 4: VM のフォールバック導出を削除**

`TranscriptionViewModel.swift` の `applyIncomingState`（line 642-649）を置換:

```swift
    private func applyIncomingState(_ state: TranscriptionState, sessionSegments: [ConfirmedSegment]) {
        NSLog("[QuickTranscriber] State update - confirmed segments: \(state.confirmedSegments.count), unconfirmed: \(state.unconfirmedText.count) chars")
        unconfirmedText = state.unconfirmedText
        let stateSegments = state.confirmedSegments
```

（続く `let newSegments` 以降は不変。`var stateSegments` → `let stateSegments` になる点に注意）

- [ ] **Step 5: テストの構築・読み取り箇所を機械的に移行**

変換規則（全ファイル共通）:

1. **構築（text のみ）**: `TranscriptionState(confirmedText: "X", unconfirmedText: u, isRecording: r)` → `TranscriptionState(unconfirmedText: u, isRecording: r, confirmedSegments: [ConfirmedSegment(text: "X")])`。confirmedText が `""` の場合は `confirmedSegments: []`（または引数省略）
2. **構築（text + segments 両方）**: `confirmedText:` 引数を削除するだけ（例: ConfidenceColoringTests:22-32 の `confirmedText: "A: Hello\nB: World"` + segments → segments のみ残す）
3. **読み取り（空判定）**: `if !state.confirmedText.isEmpty` → `if !state.confirmedSegments.isEmpty`
4. **読み取り（内容 assert）**: エンジンの責務は B1 後「セグメント列の emit」なので、セグメント単位で assert する:
   - `XCTAssertEqual(lastState?.confirmedText, "Hello world")` → `XCTAssertEqual(lastState?.confirmedSegments.map(\.text), ["Hello", "world"])`（複数セグメントの場合。分割数はテスト実行で確認して合わせる）
   - `XCTAssertEqual(lastState?.confirmedText ?? "", "")` → `XCTAssertTrue(lastState?.confirmedSegments.isEmpty ?? true)`
   - 改行・結合込みの文字列を検証したいテスト（例: 話者ラベル付き）は `TranscriptionUtils.joinSegments(lastState?.confirmedSegments ?? [], language: <テストの言語>, silenceThreshold: <テストの閾値>)` で join してから比較する
5. **VM 経由の assert**（`vm.confirmedText` を見るもの）: 変更不要（VM が join する）

対象（事前調査済みの行番号、移行時は前後を確認）:
- `ConfidenceColoringTests.swift`: 9, 22, 265（構築）、366（読み取り）
- `SpeakerReassignmentTests.swift`: 238, 259（構築。239/260 の `confirmedText:` 引数削除）、300（読み取り）
- `TranscriptionViewModelTests.swift`: 283, 349, 367, 388, 412, 443, 461, 487, 514, 622, 636, 699, 1015, 1244, 1285, 1330（構築）
- `RetroactiveUpdateGuardTests.swift`: 39, 107（読み取り）
- `QualityFilterTests.swift`: 199-200, 220, 232, 277, 319, 352, 373, 386（読み取り）
- `ChunkedWhisperEngineTests.swift`: 89, 100, 145, 195, 211, 463（読み取り）

**重要**: TranscriptionViewModelTests の text のみ構築（規則 1）は、旧フォールバック（text から 1 セグメント導出）と同じ意味になるよう「1 セグメント」に変換する。テキストを分割して複数セグメントにしないこと（`mergePreservingUserCorrections` の index 対応が変わってしまう）。

- [ ] **Step 6: ビルドとテストが通ることを確認**

Run: `swift build`
Expected: Build complete（error 0）

Run: `swift test --filter QuickTranscriberTests`
Expected: 既知の 1 件以外 PASS

- [ ] **Step 7: コミット**

```bash
git add -A
git commit -m "refactor: TranscriptionState.confirmedText を削除 — Engine はセグメントのみ emit"
```

---

### Task 4: VM の confirmedText を stored @Published に変換

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`（プロパティ宣言 line 28-51、init の parameters sink line 176-185、`regenerateText` line 494-496）
- Modify: `Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift`（再計算トリガの回帰テスト追加）

**Interfaces:**
- Consumes: Task 1 の `TranscriptionUtils.joinSegments`（委譲済み）
- Produces: `@Published public private(set) var confirmedText: String`（読み取り側 — ContentView / displayText / fileWriter 呼び出し — は変更不要）
- 再計算チョークポイント: `confirmedSegments` / `speakerDisplayNames` / `currentLanguage` の `didSet` + parametersStore sink。coordinator への `&confirmedSegments` inout 渡しやテストからの直接代入も didSet を発火させるため、個別の呼び出し追加は不要

- [ ] **Step 1: 再計算トリガの回帰テストを書く**

`TranscriptionViewModelTests.swift` に追加（現状の computed 実装でも通る = 挙動保存の回帰ガード。stored 化でトリガが漏れると落ちる）:

```swift
    // MARK: - confirmedText recompute triggers (B1: stored @Published)

    @MainActor
    func testConfirmedTextUpdatesWhenSegmentsAssignedDirectly() {
        let vm = makeViewModel()   // 既存テストのヘルパー/生成パターンに合わせる
        vm.confirmedSegments = [ConfirmedSegment(text: "Hello")]
        XCTAssertEqual(vm.confirmedText, "Hello")
        vm.confirmedSegments = []
        XCTAssertEqual(vm.confirmedText, "")
    }

    @MainActor
    func testConfirmedTextReflectsDisplayNameChange() {
        let vm = makeViewModel()
        let id = UUID()
        vm.confirmedSegments = [ConfirmedSegment(text: "Hello", speaker: id.uuidString)]
        vm.speakerDisplayNames = [id.uuidString: "Alice"]
        XCTAssertEqual(vm.confirmedText, "Alice: Hello")
        vm.speakerDisplayNames = [id.uuidString: "Bob"]
        XCTAssertEqual(vm.confirmedText, "Bob: Hello")
    }

    @MainActor
    func testConfirmedTextReflowsOnLanguageSwitch() {
        let vm = makeViewModel()
        vm.confirmedSegments = [
            ConfirmedSegment(text: "こんにちは。"),
            ConfirmedSegment(text: "元気です"),
        ]
        vm.switchLanguage(.japanese)
        // ja: 文末「。」で改行
        XCTAssertEqual(vm.confirmedText, "こんにちは。\n元気です")
        vm.switchLanguage(.english)
        // en でも「。」は sentenceEndersJA 側なので inline (" ") 結合になる
        XCTAssertEqual(vm.confirmedText, "こんにちは。 元気です")
    }
```

注意: `makeViewModel()` 相当は既存の TranscriptionViewModelTests がやっている生成方法（MockTranscriptionEngine + in-memory store の注入）をそのまま使う。`switchLanguage` は `previousSessionSegments` が空なら区切りセグメントを追加しない（`TranscriptionViewModel.swift:255`）ことを前提に期待値を書いている。もし既存生成ヘルパーが無ければ、近隣テストの setUp をコピーする。

- [ ] **Step 2: テストが通ることを確認（computed でも green = ベースライン）**

Run: `swift test --filter TranscriptionViewModelTests`
Expected: PASS（既存分含む）

- [ ] **Step 3: stored @Published に変換**

`TranscriptionViewModel.swift` line 28-51 のプロパティ群を変更:

```swift
    @Published public var currentLanguage: Language = {
        if let raw = UserDefaults.standard.string(forKey: "selectedLanguage"),
           let lang = Language(rawValue: raw) {
            return lang
        }
        return .english
    }() {
        didSet { refreshConfirmedText() }
    }
```

```swift
    @Published public var confirmedSegments: [ConfirmedSegment] = [] {
        didSet { refreshConfirmedText() }
    }

    /// confirmedSegments から導出した表示テキスト。segments / 表示名 / 言語の didSet と
    /// parametersStore 購読（沈黙閾値変更）で 1 回だけ再計算される stored キャッシュ。
    @Published public private(set) var confirmedText: String = ""
```

（旧 computed `public var confirmedText: String { ... }`（line 41-49）は削除）

```swift
    @Published public var speakerDisplayNames: [String: String] = [:] {
        didSet { refreshConfirmedText() }
    }
```

private セクション（`applyIncomingState` の近く）に追加:

```swift
    private func refreshConfirmedText() {
        let newText: String
        if confirmedSegments.isEmpty {
            newText = ""
        } else {
            newText = TranscriptionUtils.joinSegments(
                confirmedSegments,
                language: currentLanguage.rawValue,
                silenceThreshold: parametersStore.parameters.silenceLineBreakThreshold,
                speakerDisplayNames: speakerDisplayNames
            )
        }
        if newText != confirmedText {
            confirmedText = newText
        }
    }
```

`regenerateText`（line 494-496）を置換:

```swift
    public func regenerateText() {
        refreshConfirmedText()
        fileWriter.updateText(confirmedText)
    }
```

init の parametersStore 購読（line 176-185）の sink 先頭に、沈黙閾値変更時の再計算を追加:

```swift
        resolvedStore.$parameters
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshConfirmedText()   // silenceLineBreakThreshold の変更を反映
                guard self.isRecording else { return }
                NSLog("[QuickTranscriber] Parameters changed, restarting recording")
                self.restartRecording()
            }
            .store(in: &cancellables)
```

**変更しない箇所（didSet が拾うため）**: `applyIncomingState` / `clearText` / `switchLanguage` / `saveUnconfirmedText` / `splitSegment` / coordinator への inout 渡し各種。`switchLanguage` は「セグメント代入時は旧言語で再計算（didSet）→ `currentLanguage = language` 時に新言語で再計算（didSet）」となり、computed 時代のファイル書き込み内容（旧言語 join）と表示（新言語 join）の順序が保存される。

注意: didSet は init 中のデフォルト値代入では発火しない（Swift の仕様）。init 内の `$activeSpeakers` sink が `speakerDisplayNames` を代入するのは全 stored property 初期化後なので安全（調査済み）。

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter TranscriptionViewModelTests`
Expected: PASS（Step 1 の 3 件 + 既存全件）

Run: `swift test --filter QuickTranscriberTests`
Expected: 既知の 1 件以外 PASS（特に SpeakerReassignmentTests:217 `vm.confirmedText` / SpeakerReassignmentUIUpdateTests / QualityFilterTests の VM 経由 assert が生きていること）

- [ ] **Step 5: コミット**

```bash
git add Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift Tests/QuickTranscriberTests/TranscriptionViewModelTests.swift
git commit -m "refactor: VM confirmedText を stored @Published 化 — 再計算を変更時 1 回に"
```

---

### Task 5: TranscriptionTextView の非セグメント経路を削除

**Files:**
- Modify: `Sources/QuickTranscriber/Views/TranscriptionTextView.swift`（updateNSView の else 分岐 + `buildAttributedString` + 不要シム削除）

**Interfaces:**
- Consumes: Task 2 の `SegmentTextRenderer.render`（applySegmentUpdate 経由、変更なし）、Task 3/4 が確立した不変条件「`confirmedText` 非空 ⇒ `confirmedSegments` 非空」
- Produces: `TranscriptionTextView` の描画は常に `Coordinator.applySegmentUpdate`（= renderer）経由。`confirmedText` プロパティは変更検出（rename 等、fingerprint に映らないテキスト変化の検出）専用として存続

- [ ] **Step 1: updateNSView の分岐を統合**

`TranscriptionTextView.swift` の `updateNSView` 内 `if !confirmedSegments.isEmpty { ... } else { ... }`（line 225-261）を置換:

```swift
        coordinator.applySegmentUpdate(
            segments: confirmedSegments,
            language: language,
            silenceThreshold: silenceThreshold,
            fontSize: fontSize,
            unconfirmed: newUnconfirmed,
            oldFontSize: oldFontSize,
            oldUnconfirmed: oldUnconfirmed,
            speakerDisplayNames: speakerDisplayNames
        )
```

（segments が空の場合も renderer が「unconfirmed のみ」「完全空」を正しく描画する — Task 2 の `testRenderUnconfirmedOnlyHasNoLeadingNewline` / `testRenderEmptyEverything` が保証。clearText 後は空 attributed の setAttributedString で全消去される）

`updateNSView` 冒頭の `guard let textView = coordinator.textView, let textStorage = textView.textStorage else { return }`（line 220-221）は、`textStorage` が else 分岐でしか使われていなかった場合 `let textStorage` 部分を削除して warning を出さないこと（`applySegmentUpdate` が内部で textView を解決する）。`isAtBottom` の取得とスクロール処理（line 223, 263-267)は現状のまま残す。

- [ ] **Step 2: 死んだコードを削除**

同ファイルから削除:
- `buildAttributedString(confirmed:unconfirmed:fontSize:)`（Task 2 時点の残存 private、旧 line 287-307）
- `confirmedAttributes(fontSize:)` シム — else 分岐削除後に参照が残っていないか `grep -rn "TranscriptionTextView.confirmedAttributes\|confirmedAttributes(fontSize" Sources/ Tests/` で確認し、**未参照なら削除・テスト等から参照が残るなら存続**
- `makeParagraphStyle()` シム — 同上（`grep -rn "TranscriptionTextView.makeParagraphStyle" Sources/ Tests/`）

`confirmedText` プロパティと `coordinator.lastConfirmedText` による変更検出 guard（line 202-218）は**削除しない**。fingerprint は話者 UUID と confidence しか見ないため、rename（表示名変更）によるテキスト変化はこの guard でしか検出できない（SpeakerReassignmentUIUpdateTests の前提）。

- [ ] **Step 3: ビルドとテストが通ることを確認**

Run: `swift build && swift test --filter QuickTranscriberTests`
Expected: Build complete、既知の 1 件以外 PASS（特に ConfidenceColoringTests / SpeakerReassignmentUIUpdateTests）

- [ ] **Step 4: コミット**

```bash
git add Sources/QuickTranscriber/Views/TranscriptionTextView.swift
git commit -m "refactor: TranscriptionTextView の非セグメント描画経路を削除 — 描画は renderer に一本化"
```

---

### Task 6: バージョン更新・全体検証・PR 作成

**Files:**
- Modify: `Sources/QuickTranscriber/Constants.swift:61`（`patch = 87` → PR 番号）

**Interfaces:**
- Consumes: Task 1-5 の全成果
- Produces: PR（base: main）

- [ ] **Step 1: PR 番号を確認してバージョン更新**

Run: `gh pr list --state all --limit 1 --json number --jq '.[0].number'`
Expected: 直近 PR 番号（87 なら次は 88）

`Sources/QuickTranscriber/Constants.swift:61` を更新（次番号が 88 の場合）:

```swift
        public static let patch = 88
```

- [ ] **Step 2: 全体検証（superpowers:verification-before-completion に従う）**

```bash
swift build 2>&1 | tail -3
swift test --filter QuickTranscriberTests 2>&1 | tail -20
```

Expected: Build complete / 既知の 1 件（ManualModeStabilityTests.testCorrection_trustedLearningReducesFutureMisidentification）以外失敗ゼロ。**出力を実際に確認してから**次へ進む

- [ ] **Step 3: 実機スモーク（.app ビルド → ユーザー確認依頼）**

```bash
./Scripts/build_app.sh
open build/QuickTranscriber.app
```

ユーザーに以下のスモーク項目を依頼（spec の PR-B1 検証要件「実機（ライブ録音 + ファイル文字起こし）」）:
1. ライブ録音（ja）: 話者ラベル行・沈黙/文末改行・追記が正常、長めに録音して劣化がないこと
2. 話者ラベルをクリック → 話者メニューが出てブロック再割当が反映される（characterMap のオフセット整合の実機確認）
3. 本文を範囲選択 → 右クリック「Assign Speaker」で選択再割当（split 経路）
4. 話者 rename → 本文のラベルが即時更新（stored confirmedText のトリガ確認）
5. Clear で全消去 → 再録音
6. WAV ファイルをドロップしてファイル転写
7. 翻訳ペイン（Cmd+T）表示・追従
8. `qt_transcript.md` の内容が画面表示と一致

- [ ] **Step 4: コミットして PR 作成**

```bash
git add Sources/QuickTranscriber/Constants.swift
git commit -m "chore: bump version to v2.4.88"
git push -u origin refactor/simplification-pr-b1
```

PR 本文の要点（superpowers:finishing-a-development-branch に従い、作成前にユーザーへ選択肢を提示）:
- 挙動不変のリファクタ。例外は到達不能 edge 2 点のみ（先頭空セグメントの先頭判定を attributed 意味論に統一 / 全空セグメント+unconfirmed 時の先頭改行）
- join 実行が「チャンク毎 ×2 層 + SwiftUI body 評価毎」→「チャンク毎 1 回（VM didSet）+ 描画更新毎 1 回（TextView、従来通り）」に
- plain / attributed のオフセット不整合バグの構造的排除（単一 layout から導出 + 整合性テスト）

---

## Self-Review（作成時実施済み）

- **Spec coverage**: SegmentTextRenderer 新設（Task 1-2）/ joinSegments 公開シグネチャ維持で委譲（Task 1）/ TranscriptionState.confirmedText 削除 + モック経路のセグメント化（Task 3）/ VM stored @Published（Task 4）/ TextView は renderer 消費 + diff-append 維持（Task 2, 5）/ characterMap 整合性テスト（Task 2）/ ConfidenceColoringTests・TextView テスト維持（Task 2, 5）— spec Part B1 の全項目にタスクが対応
- **Placeholder scan**: 全コード Step に完全なコードを記載。テスト移行（Task 3 Step 5）のみ「規則 + 対象行番号列挙」形式だが、これは 36 箇所の機械的変換であり規則が完全（変換例も記載）
- **Type consistency**: `SegmentLayout(segmentIndex:separator:label:labelConfidence:text:)` / `layout(_:language:silenceThreshold:speakerDisplayNames:)` / `plainText(...)` / `render(_:language:silenceThreshold:fontSize:unconfirmed:speakerDisplayNames:)` の署名は Task 1/2/5 で一致。`refreshConfirmedText()` は Task 4 内で定義・使用が閉じている
