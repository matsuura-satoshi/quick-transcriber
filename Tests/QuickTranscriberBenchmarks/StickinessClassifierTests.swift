import XCTest
@testable import QuickTranscriberLib

/// Pure-logic tests for the misattribution-cause classifier (no model, no datasets).
final class StickinessClassifierTests: XCTestCase {

    private func diag(
        raw: String?,
        smoothed: String?,
        final: String?,
        cached: Bool = false,
        significantSilence: Bool = false,
        inherited: Bool = false
    ) -> ChunkDiagnostic {
        ChunkDiagnostic(
            start: 0, end: 1,
            rawName: raw, rawConfidence: raw == nil ? nil : 0.7,
            cached: cached, significantSilence: significantSilence,
            smoothedName: smoothed, finalName: final, inherited: inherited,
            cosines: [:]
        )
    }

    // Correctly attributed chunks are not classified at all.
    func testCorrectChunkReturnsNil() {
        let d = diag(raw: "上東", smoothed: "上東", final: "上東")
        XCTAssertNil(StickinessClassifier.classify(chunk: d, groundTruth: "上東"))
    }

    // Raw was right, smoother overrode it → smoother-flip (stickiness).
    func testRawCorrectSmoothedWrongIsSmootherFlip() {
        let d = diag(raw: "上東", smoothed: "松浦", final: "松浦")
        XCTAssertEqual(StickinessClassifier.classify(chunk: d, groundTruth: "上東"), .smootherFlip)
    }

    // Raw was wrong on a FRESH diarization result → raw-side embedding confusion.
    func testRawWrongFreshIsRawWrongFresh() {
        let d = diag(raw: "松浦", smoothed: "松浦", final: "松浦", cached: false)
        XCTAssertEqual(StickinessClassifier.classify(chunk: d, groundTruth: "上東"), .rawWrongFresh)
    }

    // Raw was wrong but the result was a pacer-cached value from an earlier window.
    func testRawWrongCachedIsStaleCache() {
        let d = diag(raw: "松浦", smoothed: "松浦", final: "松浦", cached: true)
        XCTAssertEqual(StickinessClassifier.classify(chunk: d, groundTruth: "上東"), .staleCache)
    }

    // Chunk never got its own confirmation; label inherited from a later flush.
    func testInheritedWrongIsPendingInherit() {
        let d = diag(raw: "上東", smoothed: nil, final: "松浦", inherited: true)
        XCTAssertEqual(StickinessClassifier.classify(chunk: d, groundTruth: "上東"), .pendingInherit)
    }

    // No diarizer observation at all; smoother held the previous speaker.
    func testNilRawWrongIsNoObservationHold() {
        let d = diag(raw: nil, smoothed: "松浦", final: "松浦")
        XCTAssertEqual(StickinessClassifier.classify(chunk: d, groundTruth: "上東"), .noObservationHold)
    }

    // Raw wrong AND smoother flipped it to a third speaker: still a raw-side error
    // (the smoother can't be blamed for fixing nothing) → classified by raw freshness.
    func testRawWrongSmoothedDifferentWrongIsStillRawSide() {
        let d = diag(raw: "森", smoothed: "松浦", final: "松浦", cached: false)
        XCTAssertEqual(StickinessClassifier.classify(chunk: d, groundTruth: "上東"), .rawWrongFresh)
    }

    // Aggregation: counts by cause for a (gt → wrong-pred) pair filter.
    func testAggregateSplit() {
        let chunks: [(ChunkDiagnostic, String)] = [
            (diag(raw: "上東", smoothed: "松浦", final: "松浦"), "上東"),
            (diag(raw: "松浦", smoothed: "松浦", final: "松浦"), "上東"),
            (diag(raw: "松浦", smoothed: "松浦", final: "松浦", cached: true), "上東"),
            (diag(raw: "上東", smoothed: "上東", final: "上東"), "上東"),  // correct, excluded
        ]
        let split = StickinessClassifier.aggregate(chunks: chunks)
        XCTAssertEqual(split[.smootherFlip], 1)
        XCTAssertEqual(split[.rawWrongFresh], 1)
        XCTAssertEqual(split[.staleCache], 1)
        XCTAssertNil(split[.pendingInherit])
    }
}
