import Foundation

/// Normalizes Zoom transcript text for fair CER comparison and concatenates
/// segment text into a session-level reference string.
///
/// Zoom's Japanese ASR inserts `。` between mid-word kana (e.g.,
/// `あ。れか。も。し。れ。な。い。で。す。が。`). To make CER comparisons
/// against QT output fair, we strip ALL punctuation and whitespace from both
/// sides before computing edit distance. Predicted text from the ablation runs
/// must be passed through `normalize` as well.
public enum ZoomReferenceCleaner {
    /// Characters removed from both reference and predicted strings.
    /// Includes Japanese sentence punctuation, ASCII punctuation, and whitespace.
    private static let strippedCharacters: Set<Character> = [
        "。", "、", "？", "！", "・", "「", "」", "『", "』",
        ",", ".", "?", "!", ";", ":",
        " ", "\t", "\n", "\r",
        "　", // full-width space
    ]

    public static func normalize(_ text: String) -> String {
        text.filter { !strippedCharacters.contains($0) }
    }

    public static func concatenateText(of segments: [ZoomSegment]) -> String {
        segments.map(\.text).joined(separator: "\n")
    }

    /// Character Error Rate. Both inputs are normalized first, then compared
    /// by Levenshtein distance / reference-length.
    public static func cer(predicted: String, reference: String) -> Double {
        let p = normalize(predicted)
        let r = normalize(reference)
        guard !r.isEmpty else { return p.isEmpty ? 0.0 : 1.0 }
        let d = levenshtein(Array(p), Array(r))
        return Double(d) / Double(r.count)
    }

    // MARK: - Levenshtein

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    curr[j - 1] + 1,        // insertion
                    prev[j] + 1,            // deletion
                    prev[j - 1] + cost      // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
