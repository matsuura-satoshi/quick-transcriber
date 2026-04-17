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

    func testCorrection_doesNotAmplifyMisidentification() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let idA = UUID()
        let idB = UUID()
        let profileA = makeEmbedding(dominant: 0)
        let profileB = makeEmbedding(dominant: 1)
        tracker.loadProfiles([(speakerId: idA, embedding: profileA), (speakerId: idB, embedding: profileB)])
        tracker.expectedSpeakerCount = 2
        tracker.suppressLearning = true

        // A さんの typical な embedding を 10 回投入。ただし
        // そのうち 3 回は「曖昧」で B に引き寄せられるバージョン。
        let typicalA = makeEmbedding(dominant: 0)
        var ambiguousA = makeEmbedding(dominant: 0)
        ambiguousA[1] = 0.4  // B 方向にブレ

        var misidentifications = 0
        for i in 0..<10 {
            let emb = [1, 4, 7].contains(i) ? ambiguousA : typicalA
            let result = tracker.identify(embedding: emb)
            if result.speakerId != idA {
                misidentifications += 1
                // ユーザーが手動で A に修正
                tracker.correctAssignment(embedding: emb, from: result.speakerId, to: idA)
            }
        }

        // Manual mode では centroid が不動なので誤認の確率は一定
        // （フィードバックループなし）。3 回の ambiguous サンプルで
        // すべてが誤認されても、以降の typical サンプルには影響しない。
        let typicalResults = (0..<10).filter { ![1, 4, 7].contains($0) }.map { _ -> UUID in
            tracker.identify(embedding: typicalA).speakerId
        }

        // typical な embedding は安定して A と識別される
        for r in typicalResults {
            XCTAssertEqual(r, idA, "typical A embeddings should always identify as A (no drift)")
        }

        // userCorrections に記録されている（profile は不動だが修正情報は残る）
        XCTAssertEqual(tracker.exportUserCorrections().count, misidentifications)

        // Profile A の centroid は初期値のまま
        let exported = tracker.exportProfiles().first(where: { $0.speakerId == idA })!
        XCTAssertEqual(exported.embedding, profileA, "profile must remain frozen in Manual mode")
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
