import Foundation

public struct ZoomSegment: Sendable, Equatable {
    public let speaker: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
}

public enum ZoomTranscriptParserError: Error, Equatable {
    case malformedHeader(line: String)
    case timestampParseFailed(line: String)
}

/// Parses Zoom-style transcripts of the form:
///
///     [Speaker Name] HH:MM:SS
///     line of text
///     (optional) more lines
///
///     [Next Speaker] HH:MM:SS
///     ...
///
/// Returns segments with `(speaker, startSeconds, endSeconds, text)`.
/// `endSeconds` is the next segment's start, or `sessionDurationSeconds` for the last.
public enum ZoomTranscriptParser {
    private static let headerPattern = #/^\[(?<speaker>.+?)\]\s+(?<h>\d{1,2}):(?<m>\d{2}):(?<s>\d{2})$/#

    public static func timeOfDay(hour: Int, minute: Int, second: Int) -> Double {
        Double(hour * 3600 + minute * 60 + second)
    }

    public static func parse(
        _ raw: String,
        sessionStart: Double,
        sessionDurationSeconds: Double
    ) throws -> [ZoomSegment] {
        var segments: [(speaker: String, startAbs: Double, text: String)] = []
        var currentSpeaker: String?
        var currentStart: Double?
        var currentLines: [String] = []

        func flush() {
            guard let speaker = currentSpeaker, let start = currentStart else { return }
            let text = currentLines.joined(separator: "\n")
            segments.append((speaker, start, text))
            currentSpeaker = nil
            currentStart = nil
            currentLines = []
        }

        for rawLine in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            if line.hasPrefix("[") {
                guard let match = try? headerPattern.wholeMatch(in: line) else {
                    throw ZoomTranscriptParserError.malformedHeader(line: line)
                }
                flush()
                let h = Int(match.output.h) ?? 0
                let m = Int(match.output.m) ?? 0
                let s = Int(match.output.s) ?? 0
                let absSeconds = Double(h * 3600 + m * 60 + s)
                currentSpeaker = String(match.output.speaker)
                currentStart = absSeconds
            } else {
                currentLines.append(line)
            }
        }
        flush()

        // Convert absolute timestamps to session-relative and assign end times.
        var result: [ZoomSegment] = []
        result.reserveCapacity(segments.count)
        for (i, seg) in segments.enumerated() {
            let startRel = max(0, seg.startAbs - sessionStart)
            let endRel: Double
            if i + 1 < segments.count {
                endRel = max(startRel, segments[i + 1].startAbs - sessionStart)
            } else {
                endRel = max(startRel, sessionDurationSeconds)
            }
            result.append(
                ZoomSegment(
                    speaker: seg.speaker,
                    startSeconds: startRel,
                    endSeconds: endRel,
                    text: seg.text
                )
            )
        }
        return result
    }

    public static func uniqueSpeakers(in segments: [ZoomSegment]) -> [String] {
        Array(Set(segments.map(\.speaker))).sorted()
    }
}
