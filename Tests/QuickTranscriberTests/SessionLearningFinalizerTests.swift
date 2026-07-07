import XCTest
@testable import QuickTranscriberLib

final class SessionLearningFinalizerTests: XCTestCase {

    private func makeEmbedding(dominant dim: Int, dimensions: Int = 4) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    private func makeStore() -> SpeakerProfileStore {
        SpeakerProfileStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLearningFinalizerTests-\(UUID().uuidString)"))
    }

    private func makeFinalizer(store: SpeakerProfileStore?) -> SessionLearningFinalizer {
        SessionLearningFinalizer(profileStore: store, embeddingHistoryStore: nil)
    }

    // MARK: - Manual mode post-hoc learning（PostHocLearningTests から移植）

    func testPostHocLearning_updatesProfileFromAllQualifyingSegments() {
        let store = makeStore()
        let idA = UUID()
        let idB = UUID()
        let initialA = makeEmbedding(dominant: 0)
        let initialB = makeEmbedding(dominant: 1)
        store.profiles.append(StoredSpeakerProfile(id: idA, displayName: "A", embedding: initialA))
        store.profiles.append(StoredSpeakerProfile(id: idB, displayName: "B", embedding: initialB))

        let sessionEmb = makeEmbedding(dominant: 2)
        let correctedEmb = makeEmbedding(dominant: 3)
        let segments: [ConfirmedSegment] = [
            ConfirmedSegment(text: "s1", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s2", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s3", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s4", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s5", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            // User-corrected segment: a trusted ground-truth sample for idA.
            // Under the new design this is INCLUDED in post-hoc learning.
            ConfirmedSegment(text: "sc", speaker: idA.uuidString, speakerConfidence: 1.0, isUserCorrected: true, originalSpeaker: idB.uuidString, speakerEmbedding: correctedEmb),
            // B has only 2 samples → below MIN_SAMPLES (3), skipped
            ConfirmedSegment(text: "b1", speaker: idB.uuidString, speakerConfidence: 0.8, speakerEmbedding: makeEmbedding(dominant: 1)),
            ConfirmedSegment(text: "b2", speaker: idB.uuidString, speakerConfidence: 0.8, speakerEmbedding: makeEmbedding(dominant: 1))
        ]

        makeFinalizer(store: store).applyManualModePostHocLearning(
            participantIds: [idA, idB],
            segments: segments
        )

        // A has 6 qualifying samples (5 non-corrected with sessionEmb + 1 corrected with correctedEmb)
        // centroid = (5 * sessionEmb + 1 * correctedEmb) / 6
        // α = min(0.2, 6/50) = 0.12
        let dims = initialA.count
        var centroid = [Float](repeating: 0, count: dims)
        for i in 0..<dims {
            centroid[i] = (5 * sessionEmb[i] + 1 * correctedEmb[i]) / 6
        }
        let updatedA = store.profiles.first(where: { $0.id == idA })!
        let alpha: Float = 0.12
        let expectedA: [Float] = zip(initialA, centroid).map { (1 - alpha) * $0 + alpha * $1 }
        for (e, u) in zip(expectedA, updatedA.embedding) {
            XCTAssertEqual(e, u, accuracy: 1e-5)
        }

        // B has only 2 samples → unchanged
        let updatedB = store.profiles.first(where: { $0.id == idB })!
        XCTAssertEqual(updatedB.embedding, initialB)
    }

    func testPostHocLearning_includesUserCorrectedSegments() {
        // Regression guard for the "manual label is trusted truth" design:
        // corrected segments alone must be enough to drive post-hoc learning,
        // even when the auto-labeled sample count is below MIN_SAMPLES.
        let store = makeStore()
        let id = UUID()
        let initial = makeEmbedding(dominant: 0)
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        let sessionEmb = makeEmbedding(dominant: 1)
        // 1 non-corrected + 2 user-corrected = 3 total (meets MIN_SAMPLES only if corrected are counted).
        let segs: [ConfirmedSegment] = [
            ConfirmedSegment(text: "auto", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "cor1", speaker: id.uuidString, speakerConfidence: 1.0, isUserCorrected: true, originalSpeaker: UUID().uuidString, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "cor2", speaker: id.uuidString, speakerConfidence: 1.0, isUserCorrected: true, originalSpeaker: UUID().uuidString, speakerEmbedding: sessionEmb)
        ]

        makeFinalizer(store: store).applyManualModePostHocLearning(
            participantIds: [id],
            segments: segs
        )

        // 3 samples, all with sessionEmb → centroid = sessionEmb; α = min(0.2, 3/50) = 0.06
        let alpha: Float = 0.06
        let expected = zip(initial, sessionEmb).map { (1 - alpha) * $0 + alpha * $1 }
        let updated = store.profiles.first!
        XCTAssertNotEqual(updated.embedding, initial,
            "corrected segments must contribute to post-hoc learning even when non-corrected samples are below MIN_SAMPLES alone")
        for (e, u) in zip(expected, updated.embedding) {
            XCTAssertEqual(e, u, accuracy: 1e-5)
        }
    }

    func testPostHocLearning_skipsLockedProfile() {
        let store = makeStore()
        let id = UUID()
        var profile = StoredSpeakerProfile(id: id, displayName: "Locked", embedding: makeEmbedding(dominant: 0))
        profile.isLocked = true
        store.profiles.append(profile)

        var segs = [ConfirmedSegment]()
        for _ in 0..<10 {
            segs.append(ConfirmedSegment(text: "x", speaker: id.uuidString, speakerConfidence: 0.9, speakerEmbedding: makeEmbedding(dominant: 2)))
        }

        makeFinalizer(store: store).applyManualModePostHocLearning(
            participantIds: [id],
            segments: segs
        )

        let updated = store.profiles.first!
        XCTAssertEqual(updated.embedding, makeEmbedding(dominant: 0),
            "locked profile should not be updated")
    }

    func testPostHocLearning_alphaScalesWithSampleCount() {
        let store = makeStore()
        let id = UUID()
        let initial = makeEmbedding(dominant: 0)
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        let sessionEmb = makeEmbedding(dominant: 1)
        // 60 サンプル → α = min(0.2, 60/50) = 0.2 (上限)
        var segs = [ConfirmedSegment]()
        for _ in 0..<60 {
            segs.append(ConfirmedSegment(text: "x", speaker: id.uuidString, speakerConfidence: 0.9, speakerEmbedding: sessionEmb))
        }

        makeFinalizer(store: store).applyManualModePostHocLearning(
            participantIds: [id],
            segments: segs
        )

        let updated = store.profiles.first!
        let expected = zip(initial, sessionEmb).map { 0.8 * $0 + 0.2 * $1 }
        for (e, u) in zip(expected, updated.embedding) {
            XCTAssertEqual(e, u, accuracy: 1e-5)
        }
    }

    func testPostHocLearning_filtersLowConfidenceSamples() {
        let store = makeStore()
        let id = UUID()
        let initial = makeEmbedding(dominant: 0)
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        let sessionEmb = makeEmbedding(dominant: 1)
        // 3 サンプル、うち 2 個は confidence が閾値未満
        let segs: [ConfirmedSegment] = [
            ConfirmedSegment(text: "ok", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "low", speaker: id.uuidString, speakerConfidence: 0.3, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "low2", speaker: id.uuidString, speakerConfidence: 0.2, speakerEmbedding: sessionEmb)
        ]

        makeFinalizer(store: store).applyManualModePostHocLearning(
            participantIds: [id],
            segments: segs
        )

        // 有効サンプル 1 個 → MIN_SAMPLES (3) 未満なのでスキップ
        let updated = store.profiles.first!
        XCTAssertEqual(updated.embedding, initial, "should skip when too few high-confidence samples")
    }

    func testCentroid_skipsDimensionMismatchCorrectly() {
        let store = makeStore()
        let id = UUID()
        let initial: [Float] = [1.0, 0.0, 0.0, 0.0]
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        // 3 normal + 1 wrong-dim → wrong-dim is skipped
        let good: [Float] = [0.0, 1.0, 0.0, 0.0]
        let wrongDim: [Float] = [0.0, 1.0]
        let segs: [ConfirmedSegment] = [
            ConfirmedSegment(text: "s1", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: good),
            ConfirmedSegment(text: "s2", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: good),
            ConfirmedSegment(text: "s3", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: good),
            ConfirmedSegment(text: "bad", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: wrongDim)
        ]

        makeFinalizer(store: store).applyManualModePostHocLearning(
            participantIds: [id],
            segments: segs
        )

        // centroid of 3 good samples = [0,1,0,0], α = min(0.2, 4/50) = 0.08
        // (note: 4 segments pass confidence/embedding filter, but only 3 have correct dimension)
        // expected = 0.92*[1,0,0,0] + 0.08*[0,1,0,0] = [0.92, 0.08, 0, 0]
        let updated = store.profiles.first!
        XCTAssertEqual(updated.embedding[0], 0.92, accuracy: 1e-5)
        XCTAssertEqual(updated.embedding[1], 0.08, accuracy: 1e-5)
    }

    // MARK: - Auto mode merge（新規: 移植ロジックの直接テスト）

    func testAutoMerge_skipsProfilesCorrectedAway() {
        // 修正で「元話者」となった session profile は store にマージしない
        // （誤認識だった声のプロファイル汚染を防ぐ既存挙動の直接テスト）
        let store = makeStore()
        let sessionSpeaker = UUID()
        let segments: [ConfirmedSegment] = [
            ConfirmedSegment(text: "x", speaker: UUID().uuidString, speakerConfidence: 1.0,
                             isUserCorrected: true, originalSpeaker: sessionSpeaker.uuidString)
        ]

        makeFinalizer(store: store).finalize(
            mode: .auto,
            participantIds: [],
            segments: segments,
            speakerDisplayNames: [sessionSpeaker.uuidString: "Alice"],
            sessionProfiles: [(speakerId: sessionSpeaker, embedding: makeEmbedding(dominant: 0))],
            detailedProfiles: []
        )

        XCTAssertTrue(store.profiles.isEmpty,
            "corrected-away session speaker must not be merged into the store")
    }

    func testAutoMerge_skipsUnmappedProfilesAndMergesMapped() {
        // displayName マッピングのない profile はスキップ、あるものだけマージ
        let store = makeStore()
        let mapped = UUID()
        let unmapped = UUID()

        makeFinalizer(store: store).finalize(
            mode: .auto,
            participantIds: [],
            segments: [],
            speakerDisplayNames: [mapped.uuidString: "Alice"],
            sessionProfiles: [
                (speakerId: mapped, embedding: makeEmbedding(dominant: 0)),
                (speakerId: unmapped, embedding: makeEmbedding(dominant: 1))
            ],
            detailedProfiles: []
        )

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].id, mapped)
        XCTAssertEqual(store.profiles[0].displayName, "Alice")
    }

    // MARK: - Embedding history（新規: 移植ロジックの直接テスト）

    func testFinalize_savesEmbeddingHistorySkippingEmptyHistories() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLearningFinalizerTests-\(UUID().uuidString)")
        let historyStore = EmbeddingHistoryStore(directory: dir)
        let finalizer = SessionLearningFinalizer(profileStore: nil, embeddingHistoryStore: historyStore)
        let withHistory = UUID()
        let withoutHistory = UUID()

        finalizer.finalize(
            mode: .auto,
            participantIds: [],
            segments: [],
            speakerDisplayNames: [:],
            sessionProfiles: [],
            detailedProfiles: [
                (speakerId: withHistory, embedding: [1, 0],
                 embeddingHistory: [WeightedEmbedding(embedding: [1, 0], confidence: 0.9)]),
                (speakerId: withoutHistory, embedding: [0, 1], embeddingHistory: [])
            ]
        )

        let entries = try historyStore.loadAll()
        XCTAssertEqual(entries.count, 1, "empty-history profiles must be skipped")
        XCTAssertEqual(entries[0].speakerProfileId, withHistory)
        XCTAssertEqual(entries[0].label, withHistory.uuidString)
        XCTAssertEqual(entries[0].embeddings.map(\.embedding), [[1, 0]])
        XCTAssertEqual(entries[0].embeddings[0].confidence, 0.9)
    }
}
