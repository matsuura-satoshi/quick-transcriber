import XCTest
@testable import QuickTranscriberLib

/// Integration test to verify that a user correction does not cause
/// the same segment-type to be misidentified on the next chunk
/// (the primary user complaint).
final class ManualModeStabilityTests: XCTestCase {

    private func makeEmbedding(dominant dim: Int, dimensions: Int = 16) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    /// v2.4.86 correction-poisoning fix (PR #86): a manual correction whose
    /// embedding is IMPLAUSIBLE for the target (cos < similarityThreshold) is
    /// recorded as a UserCorrection but NOT learned into the target centroid.
    /// The immediate label flip for such chunks is the Viterbi confirmSpeaker's
    /// job; the tracker's job is to stay uncorrupted. (The pre-#86 expectation
    /// — "enough corrections make ambiguous utterances identify as A" — is
    /// exactly the centroid-fusion path the fix closes: 上東↔松浦 0.769→0.958,
    /// 2026-06-10 diagnostic.)
    func testCorrection_ambiguousSampleIsGatedWithoutCentroidPollution() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let idA = UUID()
        let idB = UUID()
        let profileA = makeEmbedding(dominant: 0)
        let profileB = makeEmbedding(dominant: 1)
        tracker.loadProfiles([(speakerId: idA, embedding: profileA), (speakerId: idB, embedding: profileB)])
        tracker.expectedSpeakerCount = 2
        tracker.suppressLearning = true

        let typicalA = makeEmbedding(dominant: 0)
        // Utterance by speaker A that is acoustically ambiguous and gets
        // misidentified as B. (dim 1 dominant, but with dim 0 component.)
        var ambiguousA = makeEmbedding(dominant: 1)
        ambiguousA[0] = 0.5

        // Precondition for the gate: the ambiguous embedding is implausible
        // for A (below the identify threshold), so corrections must not learn it.
        XCTAssertLessThan(
            EmbeddingMath.cosineSimilarity(ambiguousA, profileA),
            Constants.Embedding.similarityThreshold,
            "test premise: ambiguousA must be below-threshold vs A's centroid")

        var misidentifications = 0
        for i in 0..<10 {
            let emb = [1, 4, 7].contains(i) ? ambiguousA : typicalA
            let result = tracker.identify(embedding: emb)
            if result.speakerId != idA {
                misidentifications += 1
                tracker.correctAssignment(embedding: emb, from: result.speakerId, to: idA)
            }
        }

        // Setup must actually exercise the correction path; otherwise the test is vacuous.
        XCTAssertGreaterThan(misidentifications, 0,
            "ambiguous embedding must trigger at least one misidentification for this test to be meaningful")
        // The label is always trusted: every correction is recorded for export.
        XCTAssertEqual(tracker.exportUserCorrections().count, misidentifications)

        // The vector is not: all corrected samples were below threshold, so A's
        // centroid must be exactly its seeded profile — no pollution.
        let centroidA = tracker.exportProfiles().first { $0.speakerId == idA }!.embedding
        XCTAssertEqual(centroidA, profileA,
            "gated corrections must leave the target centroid untouched")

        // Typical A remains correctly identified.
        for _ in 0..<10 {
            XCTAssertEqual(tracker.identify(embedding: typicalA).speakerId, idA,
                "typical A must remain correctly identified after gated corrections")
        }

        // And the ambiguous utterance still identifies as B — the tracker does
        // not absorb implausible samples no matter how often they are corrected.
        XCTAssertEqual(tracker.identify(embedding: ambiguousA).speakerId, idB,
            "an implausible sample stays gated: no amount of corrections may fuse the centroids")
    }

    func testAutoMode_correctionCentroidShiftIsLimited() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let idA = UUID()
        let profileA = makeEmbedding(dominant: 0)
        tracker.loadProfiles([(speakerId: idA, embedding: profileA)])
        // suppressLearning=false (Auto mode のデフォルト)

        let initialA = tracker.exportProfiles().first!.embedding

        // 曖昧な embedding を 1 回 correctAssignment で追加
        let ambiguous = makeEmbedding(dominant: 5)
        tracker.correctAssignment(embedding: ambiguous, from: UUID(), to: idA)

        let afterA = tracker.exportProfiles().first!.embedding

        // confidence 1.0 時代なら大きくシフト、0.3 なら控えめ
        // 具体的には (1.0 * [original] + 0.3 * [ambiguous]) / 1.3 ≈ 23% ambiguous 方向
        // 同条件で confidence 1.0 だったら 50% ambiguous 方向
        let shift = zip(initialA, afterA).map { abs($0 - $1) }.reduce(0, +)
        XCTAssertLessThan(shift, 1.0, "user correction centroid shift should be limited in Auto mode")
    }
}
