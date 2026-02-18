import Foundation

public struct ConfirmedSegment: Sendable, Equatable {
    public let text: String
    public let precedingSilence: TimeInterval
    public var speaker: String?
    public var speakerConfidence: Float?

    public init(text: String, precedingSilence: TimeInterval = 0, speaker: String? = nil, speakerConfidence: Float? = nil) {
        self.text = text
        self.precedingSilence = precedingSilence
        self.speaker = speaker
        self.speakerConfidence = speakerConfidence
    }
}

public struct TranscribedSegment: Sendable {
    public let text: String
    public let avgLogprob: Float
    public let compressionRatio: Float
    public let noSpeechProb: Float

    public init(text: String, avgLogprob: Float, compressionRatio: Float, noSpeechProb: Float) {
        self.text = text
        self.avgLogprob = avgLogprob
        self.compressionRatio = compressionRatio
        self.noSpeechProb = noSpeechProb
    }
}

public enum TranscriptionUtils {
    public static func cleanSegmentText(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "\u{FFFD}", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Quality Filters

    /// Check if text is consistent with the expected language.
    /// For Japanese: requires at least one CJK/Hiragana/Katakana character,
    /// unless the text is purely numeric/punctuation.
    public static func isLanguageConsistent(_ text: String, language: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Only apply language filter for Japanese
        guard language == "ja" else { return true }

        // Check if text contains any Japanese characters
        let hasJapanese = trimmed.unicodeScalars.contains { scalar in
            // Hiragana
            (scalar.value >= 0x3040 && scalar.value <= 0x309F) ||
            // Katakana
            (scalar.value >= 0x30A0 && scalar.value <= 0x30FF) ||
            // CJK Unified Ideographs
            (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF) ||
            // CJK Extension A
            (scalar.value >= 0x3400 && scalar.value <= 0x4DBF) ||
            // Halfwidth Katakana
            (scalar.value >= 0xFF65 && scalar.value <= 0xFF9F)
        }

        if hasJapanese { return true }

        // Allow numbers-only (with punctuation/spaces)
        let strippedOfPunctuation = trimmed.unicodeScalars.filter { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.whitespaces.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        let isNumericOnly = !strippedOfPunctuation.isEmpty &&
            strippedOfPunctuation.allSatisfy { CharacterSet.decimalDigits.contains($0) }

        return isNumericOnly
    }

    /// Check if text has excessive repetition (hallucination loops).
    public static func isRepetitive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return false }

        // Character-level: same character repeated 10+ times consecutively
        if hasConsecutiveCharRepetition(trimmed, threshold: 10) {
            return true
        }

        // Phrase-level: detect repeating substrings
        if hasRepeatingPhrase(trimmed, minRepeats: 3) {
            return true
        }

        // Compression ratio: unique characters / total characters
        let uniqueChars = Set(trimmed).count
        let totalChars = trimmed.count
        let ratio = Double(uniqueChars) / Double(totalChars)
        // Very low ratio indicates excessive repetition
        // threshold 0.1: "7、" x55 = 110 chars, 2 unique → ratio 0.018
        // "はい、はい" = 5 chars, 4 unique → ratio 0.8 (safe)
        if totalChars >= 20 && ratio < 0.1 {
            return true
        }

        return false
    }

    /// Metadata-based filter: returns true if segment should be filtered out.
    /// Filters when noSpeechProb > 0.7 AND avgLogprob < -1.5 (likely noise hallucination).
    public static func shouldFilterByMetadata(_ segment: TranscribedSegment) -> Bool {
        return segment.noSpeechProb > 0.7 && segment.avgLogprob < -1.5
    }

    /// Combined filter: returns true if segment should be filtered out.
    public static func shouldFilterSegment(_ text: String, language: String) -> Bool {
        if !isLanguageConsistent(text, language: language) {
            return true
        }
        if isRepetitive(text) {
            return true
        }
        return false
    }

    // MARK: - Segment Joining

    /// Join confirmed segments with speaker labels, silence-based, and punctuation-based line breaks.
    /// Priority: 1) Speaker change → labeled newline  2) Silence threshold → newline  3) Sentence end → newline  4) Inline
    public static func joinSegments(
        _ segments: [ConfirmedSegment],
        language: String,
        silenceThreshold: TimeInterval = 1.0,
        labelDisplayNames: [String: String] = [:]
    ) -> String {
        guard !segments.isEmpty else { return "" }
        let hasSpeakers = segments.contains { $0.speaker != nil }
        let sentenceEnders: Set<Character> = (language == "ja")
            ? ["。", "！", "？"] : [".", "!", "?"]
        let separator = (language == "ja") ? "" : " "

        var result = ""
        var currentSpeaker: String? = nil

        for (index, segment) in segments.enumerated() {
            guard !segment.text.isEmpty else { continue }

            if index == 0 {
                if hasSpeakers, let speaker = segment.speaker {
                    let displayName = labelDisplayNames[speaker] ?? speaker
                    result = "\(displayName): \(segment.text)"
                    currentSpeaker = speaker
                } else {
                    result = segment.text
                }
                continue
            }

            // Priority 1: Speaker change
            if hasSpeakers, let speaker = segment.speaker, speaker != currentSpeaker {
                let displayName = labelDisplayNames[speaker] ?? speaker
                result += "\n\(displayName): \(segment.text)"
                currentSpeaker = speaker
                continue
            }

            // Priority 2: Silence threshold
            if segment.precedingSilence >= silenceThreshold {
                result += "\n" + segment.text
                continue
            }

            // Priority 3: Sentence end
            if let last = result.last, sentenceEnders.contains(last) {
                result += "\n" + segment.text
                continue
            }

            // Priority 4: Inline
            result += separator + segment.text
        }
        return result
    }

    /// Join string segments with language-aware separators (backward compatibility).
    public static func joinSegments(_ segments: [String], language: String) -> String {
        let confirmed = segments.map { ConfirmedSegment(text: $0) }
        return joinSegments(confirmed, language: language)
    }

    // MARK: - Private Helpers

    private static func hasConsecutiveCharRepetition(_ text: String, threshold: Int) -> Bool {
        var count = 1
        var prev: Character?
        for char in text {
            if char == prev {
                count += 1
                if count >= threshold { return true }
            } else {
                count = 1
            }
            prev = char
        }
        return false
    }

    private static func hasRepeatingPhrase(_ text: String, minRepeats: Int) -> Bool {
        let chars = Array(text)
        let len = chars.count
        // Check phrase lengths from 2 to len/minRepeats
        let maxPhraseLen = len / minRepeats
        for phraseLen in 2...max(2, maxPhraseLen) {
            let phrase = chars[0..<phraseLen]
            var repeats = 0
            var i = 0
            while i + phraseLen <= len {
                if chars[i..<(i + phraseLen)].elementsEqual(phrase) {
                    repeats += 1
                    i += phraseLen
                } else {
                    i += 1
                }
            }
            if repeats >= minRepeats && repeats * phraseLen >= len / 2 {
                return true
            }
        }
        return false
    }
}

public enum TranscriptionEngineError: LocalizedError {
    case notInitialized
    case tokenizerNotAvailable

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit is not initialized. Call setup() first."
        case .tokenizerNotAvailable:
            return "Tokenizer is not available. Model may not be loaded correctly."
        }
    }
}
