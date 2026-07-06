import AppKit

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
}
