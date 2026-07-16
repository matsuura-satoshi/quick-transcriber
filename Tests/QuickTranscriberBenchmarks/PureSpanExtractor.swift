import Foundation

/// A single-speaker time interval (input GT segment or extracted pure span).
struct PureSpan: Equatable {
    let speaker: String
    let start: Double
    let end: Double

    var duration: Double { end - start }
}

/// Turns per-utterance ground-truth segments into single-speaker "pure spans"
/// for per-span embedding extraction (separability diagnostic, 2026-07-14):
/// merge same-speaker segments across gaps ≤ mergeGap, subtract every raw
/// interval of other speakers, trim boundaryTrim from both ends, drop pieces
/// shorter than minDuration, split pieces longer than maxDuration.
enum PureSpanExtractor {
    static func extract(
        segments: [PureSpan],
        mergeGap: Double = 1.0,
        boundaryTrim: Double = 0.25,
        minDuration: Double = 5.0,
        maxDuration: Double = 15.0
    ) -> [PureSpan] {
        let bySpeaker = Dictionary(grouping: segments, by: \.speaker)

        // Merge same-speaker segments whose gap is ≤ mergeGap.
        var mergedBySpeaker: [String: [(start: Double, end: Double)]] = [:]
        for (speaker, segs) in bySpeaker {
            var merged: [(start: Double, end: Double)] = []
            for seg in segs.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, seg.start - last.end <= mergeGap {
                    merged[merged.count - 1].end = max(last.end, seg.end)
                } else {
                    merged.append((seg.start, seg.end))
                }
            }
            mergedBySpeaker[speaker] = merged
        }

        var result: [PureSpan] = []
        for (speaker, intervals) in mergedBySpeaker {
            // Subtract every RAW interval of other speakers (raw, not merged:
            // a bridged gap of the target must stay pure only where nobody
            // else actually speaks).
            let others = segments.filter { $0.speaker != speaker }
            for interval in intervals {
                var pieces = [interval]
                for other in others {
                    var next: [(start: Double, end: Double)] = []
                    for piece in pieces {
                        if other.end <= piece.start || other.start >= piece.end {
                            next.append(piece)
                        } else {
                            if other.start > piece.start { next.append((piece.start, other.start)) }
                            if other.end < piece.end { next.append((other.end, piece.end)) }
                        }
                    }
                    pieces = next
                }

                // Trim boundaries, then emit maxDuration slices; a slice
                // (including the final remainder) must be ≥ minDuration.
                for piece in pieces {
                    let end = piece.end - boundaryTrim
                    var cursor = piece.start + boundaryTrim
                    while end - cursor >= minDuration {
                        let sliceEnd = min(cursor + maxDuration, end)
                        result.append(PureSpan(speaker: speaker, start: cursor, end: sliceEnd))
                        cursor = sliceEnd
                    }
                }
            }
        }

        return result.sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.speaker < $1.speaker
        }
    }
}
