import XCTest
@testable import QuickTranscriberLib

/// PureSpanExtractor turns per-utterance GT segments into single-speaker
/// "pure spans" suitable for per-span embedding extraction:
/// merge (gap ≤ mergeGap) → subtract other speakers → boundary trim →
/// drop < minDuration → split > maxDuration.
/// Model-free unit tests (run with the fast test gate).
final class PureSpanExtractorTests: XCTestCase {

    private func extract(
        _ segments: [PureSpan],
        mergeGap: Double = 1.0,
        boundaryTrim: Double = 0.25,
        minDuration: Double = 5.0,
        maxDuration: Double = 15.0
    ) -> [PureSpan] {
        PureSpanExtractor.extract(
            segments: segments,
            mergeGap: mergeGap,
            boundaryTrim: boundaryTrim,
            minDuration: minDuration,
            maxDuration: maxDuration
        )
    }

    func testEmptyInputYieldsNoSpans() {
        XCTAssertEqual(extract([]), [])
    }

    func testShortSegmentIsDropped() {
        // 3s − 2×0.25 trim = 2.5s < 5s
        let spans = extract([PureSpan(speaker: "A", start: 0, end: 3)])
        XCTAssertEqual(spans, [])
    }

    func testSingleSegmentIsTrimmedAndKept() {
        let spans = extract([PureSpan(speaker: "A", start: 10, end: 20)])
        XCTAssertEqual(spans, [PureSpan(speaker: "A", start: 10.25, end: 19.75)])
    }

    func testAdjacentSameSpeakerSegmentsMergeAcrossSmallGap() {
        // gap 0.5 ≤ mergeGap 1.0 → merged 0–10 → trimmed 0.25–9.75 (9.5s)
        let spans = extract([
            PureSpan(speaker: "A", start: 0, end: 4),
            PureSpan(speaker: "A", start: 4.5, end: 10),
        ])
        XCTAssertEqual(spans, [PureSpan(speaker: "A", start: 0.25, end: 9.75)])
    }

    func testLargeGapDoesNotMerge() {
        // gap 2.0 > 1.0 → two intervals, each 6s − 0.5 = 5.5s ≥ 5s
        let spans = extract([
            PureSpan(speaker: "A", start: 0, end: 6),
            PureSpan(speaker: "A", start: 8, end: 14),
        ])
        XCTAssertEqual(spans, [
            PureSpan(speaker: "A", start: 0.25, end: 5.75),
            PureSpan(speaker: "A", start: 8.25, end: 13.75),
        ])
    }

    func testOverlappingOtherSpeakerIsSubtracted() {
        // A: 0–20, B: 8–12 → A pure 0–8 and 12–20 (7.5s each after trim);
        // B's own 4s − 0.5 = 3.5s < 5s → dropped
        let spans = extract([
            PureSpan(speaker: "A", start: 0, end: 20),
            PureSpan(speaker: "B", start: 8, end: 12),
        ])
        XCTAssertEqual(spans, [
            PureSpan(speaker: "A", start: 0.25, end: 7.75),
            PureSpan(speaker: "A", start: 12.25, end: 19.75),
        ])
    }

    func testLongSpanIsSplitIntoMaxDurationPieces() {
        // 0–35 → trimmed 0.25–34.75 (34.5s) → [0.25,15.25], [15.25,30.25],
        // remainder 4.5s < 5s → dropped
        let spans = extract([PureSpan(speaker: "A", start: 0, end: 35)])
        XCTAssertEqual(spans, [
            PureSpan(speaker: "A", start: 0.25, end: 15.25),
            PureSpan(speaker: "A", start: 15.25, end: 30.25),
        ])
    }

    func testSplitRemainderIsKeptWhenLongEnough() {
        // 0–21 → trimmed 0.25–20.75 (20.5s) → [0.25,15.25] + remainder 5.5s ≥ 5s
        let spans = extract([PureSpan(speaker: "A", start: 0, end: 21)])
        XCTAssertEqual(spans, [
            PureSpan(speaker: "A", start: 0.25, end: 15.25),
            PureSpan(speaker: "A", start: 15.25, end: 20.75),
        ])
    }

    func testOutputIsSortedByStartAcrossSpeakers() {
        let spans = extract([
            PureSpan(speaker: "B", start: 30, end: 40),
            PureSpan(speaker: "A", start: 0, end: 10),
        ])
        XCTAssertEqual(spans, [
            PureSpan(speaker: "A", start: 0.25, end: 9.75),
            PureSpan(speaker: "B", start: 30.25, end: 39.75),
        ])
    }
}
