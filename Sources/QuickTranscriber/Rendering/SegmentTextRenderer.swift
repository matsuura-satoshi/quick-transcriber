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
