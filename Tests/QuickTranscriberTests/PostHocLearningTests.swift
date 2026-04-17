import XCTest
@testable import QuickTranscriberLib

final class PostHocLearningTests: XCTestCase {

    private func makeEmbedding(dominant dim: Int, dimensions: Int = 4) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    private func makeEngine(
        store: SpeakerProfileStore
    ) -> ChunkedWhisperEngine {
        ChunkedWhisperEngine(
            audioCaptureService: MockAudioCaptureService(),
            transcriber: MockChunkTranscriber(),
            diarizer: MockSpeakerDiarizer(),
            speakerProfileStore: store,
            embeddingHistoryStore: EmbeddingHistoryStore()
        )
    }

    func testPostHocLearning_updatesProfileFromNonCorrectedSegments() {
        let store = SpeakerProfileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PostHocLearningTests-\(UUID().uuidString)"))
        let idA = UUID()
        let idB = UUID()
        let initialA = makeEmbedding(dominant: 0)
        let initialB = makeEmbedding(dominant: 1)
        store.profiles.append(StoredSpeakerProfile(id: idA, displayName: "A", embedding: initialA))
        store.profiles.append(StoredSpeakerProfile(id: idB, displayName: "B", embedding: initialB))

        let engine = makeEngine(store: store)

        let sessionEmb = makeEmbedding(dominant: 2)
        let correctedEmb = makeEmbedding(dominant: 3)
        let segments: [ConfirmedSegment] = [
            ConfirmedSegment(text: "s1", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s2", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s3", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s4", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "s5", speaker: idA.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "sc", speaker: idA.uuidString, speakerConfidence: 0.8, isUserCorrected: true, originalSpeaker: idB.uuidString, speakerEmbedding: correctedEmb),
            // B は 2 サンプルのみ → MIN_SAMPLES (3) 未満でスキップされるはず
            ConfirmedSegment(text: "b1", speaker: idB.uuidString, speakerConfidence: 0.8, speakerEmbedding: makeEmbedding(dominant: 1)),
            ConfirmedSegment(text: "b2", speaker: idB.uuidString, speakerConfidence: 0.8, speakerEmbedding: makeEmbedding(dominant: 1))
        ]

        engine.applyManualModePostHocLearningForTesting(
            store: store,
            participantIds: [idA, idB],
            segments: segments
        )

        // A は 5 サンプル → α = min(0.2, 5/50) = 0.1
        let updatedA = store.profiles.first(where: { $0.id == idA })!
        let expectedA: [Float] = zip(initialA, sessionEmb).map { 0.9 * $0 + 0.1 * $1 }
        for (e, u) in zip(expectedA, updatedA.embedding) {
            XCTAssertEqual(e, u, accuracy: 1e-5)
        }

        // B は 2 サンプルのみなので不変
        let updatedB = store.profiles.first(where: { $0.id == idB })!
        XCTAssertEqual(updatedB.embedding, initialB)
    }

    func testPostHocLearning_skipsLockedProfile() {
        let store = SpeakerProfileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PostHocLearningTests-\(UUID().uuidString)"))
        let id = UUID()
        var profile = StoredSpeakerProfile(id: id, displayName: "Locked", embedding: makeEmbedding(dominant: 0))
        profile.isLocked = true
        store.profiles.append(profile)

        let engine = makeEngine(store: store)

        var segs = [ConfirmedSegment]()
        for _ in 0..<10 {
            segs.append(ConfirmedSegment(text: "x", speaker: id.uuidString, speakerConfidence: 0.9, speakerEmbedding: makeEmbedding(dominant: 2)))
        }

        engine.applyManualModePostHocLearningForTesting(
            store: store,
            participantIds: [id],
            segments: segs
        )

        let updated = store.profiles.first!
        XCTAssertEqual(updated.embedding, makeEmbedding(dominant: 0),
            "locked profile should not be updated")
    }

    func testPostHocLearning_alphaScalesWithSampleCount() {
        let store = SpeakerProfileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PostHocLearningTests-\(UUID().uuidString)"))
        let id = UUID()
        let initial = makeEmbedding(dominant: 0)
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        let engine = makeEngine(store: store)

        let sessionEmb = makeEmbedding(dominant: 1)
        // 60 サンプル → α = min(0.2, 60/50) = 0.2 (上限)
        var segs = [ConfirmedSegment]()
        for _ in 0..<60 {
            segs.append(ConfirmedSegment(text: "x", speaker: id.uuidString, speakerConfidence: 0.9, speakerEmbedding: sessionEmb))
        }

        engine.applyManualModePostHocLearningForTesting(
            store: store,
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
        let store = SpeakerProfileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PostHocLearningTests-\(UUID().uuidString)"))
        let id = UUID()
        let initial = makeEmbedding(dominant: 0)
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        let engine = makeEngine(store: store)

        let sessionEmb = makeEmbedding(dominant: 1)
        // 3 サンプル、うち 2 個は confidence が閾値未満
        let segs: [ConfirmedSegment] = [
            ConfirmedSegment(text: "ok", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "low", speaker: id.uuidString, speakerConfidence: 0.3, speakerEmbedding: sessionEmb),
            ConfirmedSegment(text: "low2", speaker: id.uuidString, speakerConfidence: 0.2, speakerEmbedding: sessionEmb)
        ]

        engine.applyManualModePostHocLearningForTesting(
            store: store,
            participantIds: [id],
            segments: segs
        )

        // 有効サンプル 1 個 → MIN_SAMPLES (3) 未満なのでスキップ
        let updated = store.profiles.first!
        XCTAssertEqual(updated.embedding, initial, "should skip when too few high-confidence samples")
    }

    func testCentroid_skipsDimensionMismatchCorrectly() {
        let store = SpeakerProfileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PostHocLearningTests-\(UUID().uuidString)"))
        let id = UUID()
        let initial: [Float] = [1.0, 0.0, 0.0, 0.0]
        store.profiles.append(StoredSpeakerProfile(id: id, displayName: "A", embedding: initial))

        let engine = makeEngine(store: store)

        // 3 normal + 1 wrong-dim → wrong-dim is skipped
        let good: [Float] = [0.0, 1.0, 0.0, 0.0]
        let wrongDim: [Float] = [0.0, 1.0]
        let segs: [ConfirmedSegment] = [
            ConfirmedSegment(text: "s1", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: good),
            ConfirmedSegment(text: "s2", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: good),
            ConfirmedSegment(text: "s3", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: good),
            ConfirmedSegment(text: "bad", speaker: id.uuidString, speakerConfidence: 0.8, speakerEmbedding: wrongDim)
        ]

        engine.applyManualModePostHocLearningForTesting(
            store: store,
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
}
