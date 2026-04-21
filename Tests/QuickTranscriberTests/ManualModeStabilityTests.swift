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

    func testCorrection_trustedLearningReducesFutureMisidentification() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let idA = UUID()
        let idB = UUID()
        let profileA = makeEmbedding(dominant: 0)
        let profileB = makeEmbedding(dominant: 1)
        tracker.loadProfiles([(speakerId: idA, embedding: profileA), (speakerId: idB, embedding: profileB)])
        tracker.expectedSpeakerCount = 2
        tracker.suppressLearning = true

        let typicalA = makeEmbedding(dominant: 0)
        // Utterance by speaker A that is acoustically ambiguous and initially
        // gets misidentified as B. (dim 1 dominant, but with dim 0 component.)
        var ambiguousA = makeEmbedding(dominant: 1)
        ambiguousA[0] = 0.5

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
        XCTAssertEqual(tracker.exportUserCorrections().count, misidentifications)

        // After trusted-learning from corrections, typical A embeddings still identify as A:
        // the centroid shift is bounded and does not corrupt the core identity.
        for _ in 0..<10 {
            XCTAssertEqual(tracker.identify(embedding: typicalA).speakerId, idA,
                "typical A must remain correctly identified even after centroid updates from manual corrections")
        }

        // And the "learning" property: a later ambiguous utterance from A is now less likely
        // to be misidentified — the centroid has moved toward the ambiguous sample.
        let finalAmbiguousResult = tracker.identify(embedding: ambiguousA).speakerId
        XCTAssertEqual(finalAmbiguousResult, idA,
            "after enough trusted corrections, ambiguous A utterances should also identify as A")
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
