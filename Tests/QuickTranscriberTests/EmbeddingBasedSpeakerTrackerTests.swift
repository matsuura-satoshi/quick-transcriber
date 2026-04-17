import XCTest
@testable import QuickTranscriberLib

final class EmbeddingBasedSpeakerTrackerTests: XCTestCase {

    // Helper: create a normalized embedding with a dominant dimension
    private func makeEmbedding(dominant dim: Int, dimensions: Int = 256) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    // MARK: - First speaker is registered with a UUID

    func testFirstSpeakerGetsUUID() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        let result = tracker.identify(embedding: emb)
        // Should return a valid UUID (non-nil speakerId)
        XCTAssertFalse(result.speakerId.uuidString.isEmpty)
    }

    // MARK: - Same speaker returns same UUID

    func testSameSpeakerReturnsSameId() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        let first = tracker.identify(embedding: emb)
        let second = tracker.identify(embedding: emb)
        XCTAssertEqual(first.speakerId, second.speakerId)
    }

    // MARK: - Different speaker gets new UUID

    func testDifferentSpeakerGetsNewId() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let resultA = tracker.identify(embedding: makeEmbedding(dominant: 0))
        let resultB = tracker.identify(embedding: makeEmbedding(dominant: 1))
        XCTAssertNotEqual(resultA.speakerId, resultB.speakerId)
    }

    // MARK: - Three distinct speakers

    func testThreeDistinctSpeakers() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let r1 = tracker.identify(embedding: makeEmbedding(dominant: 0))
        let r2 = tracker.identify(embedding: makeEmbedding(dominant: 1))
        let r3 = tracker.identify(embedding: makeEmbedding(dominant: 2))
        let ids = Set([r1.speakerId, r2.speakerId, r3.speakerId])
        XCTAssertEqual(ids.count, 3, "Three distinct speakers should have three distinct UUIDs")
    }

    // MARK: - Return to first speaker

    func testReturnToFirstSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let firstResult = tracker.identify(embedding: embA)
        _ = tracker.identify(embedding: embB)
        let returnResult = tracker.identify(embedding: embA)
        XCTAssertEqual(returnResult.speakerId, firstResult.speakerId)
    }

    // MARK: - Similar embeddings match (slight variation)

    func testSimilarEmbeddingsMatchSameSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb1 = makeEmbedding(dominant: 0)
        let firstResult = tracker.identify(embedding: emb1)

        // Slightly perturbed version of same speaker
        var emb2 = emb1
        emb2[1] = 0.15
        emb2[2] = 0.1
        let result = tracker.identify(embedding: emb2)
        XCTAssertEqual(result.speakerId, firstResult.speakerId)
    }

    // MARK: - Profile update (moving average)

    func testProfileUpdatesOverTime() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb1 = makeEmbedding(dominant: 0)
        let firstResult = tracker.identify(embedding: emb1)

        // Feed slightly drifted embedding multiple times
        var drifted = makeEmbedding(dominant: 0)
        drifted[3] = 0.3
        for _ in 0..<5 {
            let result = tracker.identify(embedding: drifted)
            XCTAssertEqual(result.speakerId, firstResult.speakerId)
        }
        // Profile should have adapted toward drifted embedding
        // Verify by checking the profile still matches drifted
        XCTAssertEqual(tracker.identify(embedding: drifted).speakerId, firstResult.speakerId)
    }

    // MARK: - Reset clears all profiles

    func testResetClearsProfiles() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let firstResult = tracker.identify(embedding: makeEmbedding(dominant: 0))
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))
        tracker.reset()
        // After reset, next speaker gets a new UUID (different from pre-reset)
        let afterReset = tracker.identify(embedding: makeEmbedding(dominant: 2))
        XCTAssertNotEqual(afterReset.speakerId, firstResult.speakerId)
        XCTAssertEqual(tracker.exportProfiles().count, 1)
    }

    // MARK: - Cosine similarity helper

    func testCosineSimilarityIdentical() {
        let v = makeEmbedding(dominant: 0)
        let similarity = EmbeddingBasedSpeakerTracker.cosineSimilarity(v, v)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.001)
    }

    func testCosineSimilarityOrthogonal() {
        var a = [Float](repeating: 0, count: 256)
        a[0] = 1.0
        var b = [Float](repeating: 0, count: 256)
        b[1] = 1.0
        let similarity = EmbeddingBasedSpeakerTracker.cosineSimilarity(a, b)
        XCTAssertEqual(similarity, 0.0, accuracy: 0.001)
    }

    // MARK: - Expected Speaker Count

    func testExpectedSpeakerCountLimitsNewSpeakers() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
        let idA = tracker.identify(embedding: makeEmbedding(dominant: 0)).speakerId
        let idB = tracker.identify(embedding: makeEmbedding(dominant: 1)).speakerId
        // Third distinct voice should NOT create a new speaker — should assign to closest existing
        let result = tracker.identify(embedding: makeEmbedding(dominant: 2))
        XCTAssertTrue(result.speakerId == idA || result.speakerId == idB, "Should assign to existing speaker")
        XCTAssertEqual(tracker.exportProfiles().count, 2)
    }

    func testExpectedSpeakerCountAssignsToBestMatch() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
        let idA = tracker.identify(embedding: makeEmbedding(dominant: 0)).speakerId
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))  // B

        // Create embedding closer to speaker A (dominant dim 0, with small contribution from dim 2)
        var closerToA = makeEmbedding(dominant: 2)
        closerToA[0] = 0.5  // Add similarity to A
        let result = tracker.identify(embedding: closerToA)
        XCTAssertEqual(result.speakerId, idA, "Should assign to most similar existing speaker (A)")
    }

    func testNilExpectedSpeakerCountAllowsUnlimited() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: nil)
        let ids = [
            tracker.identify(embedding: makeEmbedding(dominant: 0)).speakerId,
            tracker.identify(embedding: makeEmbedding(dominant: 1)).speakerId,
            tracker.identify(embedding: makeEmbedding(dominant: 2)).speakerId,
            tracker.identify(embedding: makeEmbedding(dominant: 3)).speakerId,
        ]
        XCTAssertEqual(Set(ids).count, 4, "All four speakers should have distinct UUIDs")
    }

    // MARK: - Export / Load Profiles

    func testExportProfilesReturnsRegisteredSpeakers() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let idA = tracker.identify(embedding: embA).speakerId
        let idB = tracker.identify(embedding: embB).speakerId

        let exported = tracker.exportProfiles()
        XCTAssertEqual(exported.count, 2)
        XCTAssertEqual(exported[0].speakerId, idA)
        XCTAssertEqual(exported[1].speakerId, idB)
    }

    func testLoadProfilesInitializesTracker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let idA = UUID()
        let idB = UUID()
        tracker.loadProfiles([
            (speakerId: idA, embedding: embA),
            (speakerId: idB, embedding: embB)
        ])

        let result = tracker.identify(embedding: embA)
        XCTAssertEqual(result.speakerId, idA)
    }

    func testLoadProfilesNewSpeakerGetsNewId() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let idA = UUID()
        let idB = UUID()
        tracker.loadProfiles([
            (speakerId: idA, embedding: makeEmbedding(dominant: 0)),
            (speakerId: idB, embedding: makeEmbedding(dominant: 1))
        ])

        let result = tracker.identify(embedding: makeEmbedding(dominant: 2))
        XCTAssertNotEqual(result.speakerId, idA)
        XCTAssertNotEqual(result.speakerId, idB)
    }

    func testLoadProfilesClearsExistingState() {
        let tracker = EmbeddingBasedSpeakerTracker()
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))

        let loadedId = UUID()
        tracker.loadProfiles([
            (speakerId: loadedId, embedding: makeEmbedding(dominant: 2))
        ])

        let exported = tracker.exportProfiles()
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported[0].speakerId, loadedId)
    }

    // MARK: - Profile Strategy

    func testProfileStrategyNoneIsDefault() {
        let tracker = EmbeddingBasedSpeakerTracker()
        // Default strategy should create distinct speakers
        let ids = [
            tracker.identify(embedding: makeEmbedding(dominant: 0)).speakerId,
            tracker.identify(embedding: makeEmbedding(dominant: 1)).speakerId,
            tracker.identify(embedding: makeEmbedding(dominant: 2)).speakerId,
        ]
        XCTAssertEqual(Set(ids).count, 3)
    }

    func testHitCountIncrementsOnMatch() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb)  // Register
        _ = tracker.identify(embedding: emb)  // Match
        _ = tracker.identify(embedding: emb)  // Match

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].hitCount, 3)
    }

    // MARK: - Culling Strategy

    func testCullingRemovesLowHitProfiles() {
        let tracker = EmbeddingBasedSpeakerTracker(strategy: .culling(interval: 5, minHits: 2))

        let embA = makeEmbedding(dominant: 0)
        let idA = tracker.identify(embedding: embA).speakerId
        _ = tracker.identify(embedding: embA)  // Match A, hit=2
        _ = tracker.identify(embedding: embA)  // Match A, hit=3

        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))  // Register B, hit=1

        // 5th call triggers maintenance: B has hitCount=1 < minHits=2, should be culled
        _ = tracker.identify(embedding: embA)  // identifyCount=5, triggers maintenance

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles.count, 1, "B should have been culled")
        XCTAssertEqual(profiles[0].speakerId, idA)
    }

    // MARK: - Merging Strategy

    func testMergingCombinesSimilarProfiles() {
        // similarityThreshold=0.99 so embSimilar (sim~0.983) registers separately
        // mergeThreshold=0.95 so they get merged back (0.983 > 0.95)
        let tracker = EmbeddingBasedSpeakerTracker(
            similarityThreshold: 0.99,
            strategy: .merging(interval: 5, threshold: 0.95)
        )

        let embA = makeEmbedding(dominant: 0)          // Speaker A
        _ = tracker.identify(embedding: embA)           // 1: Register A

        var embSimilar = makeEmbedding(dominant: 0)
        embSimilar[1] = 0.2                             // sim~0.983 with A, below 0.99
        _ = tracker.identify(embedding: embSimilar)     // 2: Register B

        _ = tracker.identify(embedding: makeEmbedding(dominant: 100))  // 3: Register C (different)

        _ = tracker.identify(embedding: makeEmbedding(dominant: 100))  // 4: Match C
        _ = tracker.identify(embedding: makeEmbedding(dominant: 100))  // 5: Triggers merge

        let profiles = tracker.exportProfiles()
        // Before merge: 3 profiles (A, B, C). After merge: A+B merged -> 2 profiles
        XCTAssertEqual(profiles.count, 2, "Similar profiles A and B should have merged")
    }

    // MARK: - Registration Gate Strategy

    func testRegistrationGateBlocksSimilarNewSpeaker() {
        // similarityThreshold=0.5: only match if sim >= 0.5
        // minSeparation=0.3: gate registration if best sim >= 0.3
        let tracker = EmbeddingBasedSpeakerTracker(
            similarityThreshold: 0.5,
            strategy: .registrationGate(minSeparation: 0.3)
        )

        let idA = tracker.identify(embedding: makeEmbedding(dominant: 0)).speakerId

        // This embedding has sim~0.39 with A: below 0.5 (no match) but above 0.3 (gated)
        var embSomewhatSimilar = makeEmbedding(dominant: 3)
        embSomewhatSimilar[0] = 0.4
        let result = tracker.identify(embedding: embSomewhatSimilar)

        XCTAssertEqual(result.speakerId, idA, "Should be gated to existing speaker")
        XCTAssertEqual(tracker.exportProfiles().count, 1)
    }

    func testRegistrationGateAllowsTrulyDifferentSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker(
            similarityThreshold: 0.5,
            strategy: .registrationGate(minSeparation: 0.3)
        )

        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))   // Register A
        // dim 100 has sim~0.044 with dim 0, well below minSeparation=0.3
        _ = tracker.identify(embedding: makeEmbedding(dominant: 100)) // Truly different, should register B

        XCTAssertEqual(tracker.exportProfiles().count, 2)
    }

    // MARK: - Combined Strategy

    func testCombinedStrategyCullsThenMerges() {
        let tracker = EmbeddingBasedSpeakerTracker(
            similarityThreshold: 0.3,
            strategy: .combined(cullInterval: 5, minHits: 2, mergeThreshold: 0.7)
        )

        let embA = makeEmbedding(dominant: 0)
        let idA = tracker.identify(embedding: embA).speakerId
        _ = tracker.identify(embedding: embA)  // 2: Match A, hit=2
        _ = tracker.identify(embedding: embA)  // 3: Match A, hit=3

        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))  // 4: Register B, hit=1

        _ = tracker.identify(embedding: embA)  // 5: Triggers maintenance, B has hit=1 < minHits=2, culled

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles.count, 1, "B should have been culled")
        XCTAssertEqual(profiles[0].speakerId, idA)
    }

    // MARK: - Confidence Score

    func testIdentifyReturnsConfidenceForNewSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let result = tracker.identify(embedding: makeEmbedding(dominant: 0))
        XCTAssertFalse(result.speakerId.uuidString.isEmpty)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.001)
    }

    func testIdentifyReturnsConfidenceForMatchedSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let firstResult = tracker.identify(embedding: makeEmbedding(dominant: 0))
        var similar = makeEmbedding(dominant: 0)
        similar[1] = 0.15
        let result = tracker.identify(embedding: similar)
        XCTAssertEqual(result.speakerId, firstResult.speakerId)
        XCTAssertGreaterThan(result.confidence, 0.5)
        XCTAssertLessThan(result.confidence, 1.0)
    }

    func testIdentifyReturnsLowConfidenceForForcedAssignment() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
        let idA = tracker.identify(embedding: makeEmbedding(dominant: 0)).speakerId
        let idB = tracker.identify(embedding: makeEmbedding(dominant: 1)).speakerId
        let result = tracker.identify(embedding: makeEmbedding(dominant: 2))
        XCTAssertTrue(result.speakerId == idA || result.speakerId == idB)
        XCTAssertLessThan(result.confidence, 0.5)
    }

    // MARK: - Embedding History

    func testIdentifyStoresEmbeddingHistory() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb1 = makeEmbedding(dominant: 0)
        var emb2 = makeEmbedding(dominant: 0)  // similar, matches A
        emb2[1] = 0.15  // make slightly different so mean differs from moving average
        _ = tracker.identify(embedding: emb1)
        let result2 = tracker.identify(embedding: emb2)
        let conf2 = result2.confidence

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles[0].hitCount, 2)
        // Verify embedding is weighted mean: (1.0 * emb1 + conf2 * emb2) / (1.0 + conf2)
        let totalWeight = 1.0 + conf2
        let expectedWeighted = zip(emb1, emb2).map { (1.0 * $0 + conf2 * $1) / totalWeight }
        for i in 0..<expectedWeighted.count {
            XCTAssertEqual(profiles[0].embedding[i], expectedWeighted[i], accuracy: 0.001)
        }
    }

    func testIdentifyNewSpeakerHasSingleHistoryEntry() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb)

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles[0].hitCount, 1)
        XCTAssertEqual(profiles[0].embedding, emb)
    }

    func testLoadProfilesSeedsHistory() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        let loadedId = UUID()
        tracker.loadProfiles([(speakerId: loadedId, embedding: emb)])

        var similar = makeEmbedding(dominant: 0)
        similar[1] = 0.15
        let result = tracker.identify(embedding: similar)
        let conf = result.confidence

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles[0].hitCount, 2)
        // Loaded profile has confidence 1.0, new match has actual confidence
        let totalWeight = 1.0 + conf
        let expectedWeighted = zip(emb, similar).map { (1.0 * $0 + conf * $1) / totalWeight }
        for i in 0..<expectedWeighted.count {
            XCTAssertEqual(profiles[0].embedding[i], expectedWeighted[i], accuracy: 0.001)
        }
    }

    // MARK: - Correct Assignment

    func testCorrectAssignmentMovesEmbeddingBetweenProfiles() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let idA = tracker.identify(embedding: embA).speakerId
        let idB = tracker.identify(embedding: embB).speakerId

        tracker.correctAssignment(embedding: embB, from: idB, to: idA)

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].speakerId, idA)
        XCTAssertEqual(profiles[0].hitCount, 2)
    }

    func testCorrectAssignmentRecalculatesProfiles() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA1 = makeEmbedding(dominant: 0)
        var embA2 = makeEmbedding(dominant: 0)
        embA2[1] = 0.15
        let embB = makeEmbedding(dominant: 1)
        let idA = tracker.identify(embedding: embA1).speakerId
        _ = tracker.identify(embedding: embA2)
        let idB = tracker.identify(embedding: embB).speakerId

        tracker.correctAssignment(embedding: embA2, from: idA, to: idB)

        let profiles = tracker.exportProfiles()
        let profileA = profiles.first { $0.speakerId == idA }!
        let profileB = profiles.first { $0.speakerId == idB }!
        XCTAssertEqual(profileA.hitCount, 1)
        XCTAssertEqual(profileA.embedding, embA1)
        // B has 2 embeddings: embB (conf 1.0, new speaker) + embA2 (conf userCorrectionConfidence, user-corrected)
        XCTAssertEqual(profileB.hitCount, 2)
    }

    func testCorrectAssignmentToNewSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        let idA = tracker.identify(embedding: emb).speakerId
        let newId = UUID()

        tracker.correctAssignment(embedding: emb, from: idA, to: newId)

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].speakerId, newId)
        XCTAssertEqual(profiles[0].embedding, emb)
    }

    func testCorrectAssignmentWithNonexistentEmbeddingIsGraceful() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let idA = tracker.identify(embedding: embA).speakerId
        let newId = UUID()

        let nonexistent = makeEmbedding(dominant: 5)
        tracker.correctAssignment(embedding: nonexistent, from: idA, to: newId)

        let profiles = tracker.exportProfiles()
        // A should still have its embedding, new profile created with nonexistent
        XCTAssertEqual(profiles.count, 2)
    }

    // MARK: - SpeakerIdentification Embedding

    func testIdentifyReturnsSpeakerIdentificationWithEmbedding() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        let result = tracker.identify(embedding: emb)
        XCTAssertEqual(result.embedding, emb)
    }

    // MARK: - ConfirmedSegment speakerEmbedding

    func testConfirmedSegmentWithEmbedding() {
        let emb: [Float] = [0.1, 0.2, 0.3]
        let segment = ConfirmedSegment(text: "Hello", speakerEmbedding: emb)
        XCTAssertEqual(segment.speakerEmbedding, emb)
    }

    func testConfirmedSegmentDefaultNilEmbedding() {
        let segment = ConfirmedSegment(text: "Hello")
        XCTAssertNil(segment.speakerEmbedding)
    }

    // MARK: - Export Detailed Profiles

    func testExportDetailedProfilesIncludesHistory() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb1 = makeEmbedding(dominant: 0)
        let emb2 = makeEmbedding(dominant: 0)  // matches A
        let idA = tracker.identify(embedding: emb1).speakerId
        _ = tracker.identify(embedding: emb2)

        let detailed = tracker.exportDetailedProfiles()
        XCTAssertEqual(detailed.count, 1)
        XCTAssertEqual(detailed[0].speakerId, idA)
        XCTAssertEqual(detailed[0].embeddingHistory.count, 2)
        XCTAssertEqual(detailed[0].embeddingHistory[0].embedding, emb1)
        XCTAssertEqual(detailed[0].embeddingHistory[1].embedding, emb2)
    }

    // MARK: - Weighted Embedding

    func testWeightedMeanReducesLowConfidenceInfluence() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
        // High-confidence embedding: dominant dim 0
        let highConf = makeEmbedding(dominant: 0)
        let idA = tracker.identify(embedding: highConf).speakerId  // confidence=1.0
        // Register B so that next identify of different embedding is forced to A (low confidence)
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))  // B

        // Low-confidence forced assignment: very different embedding forced to A
        var lowConf = makeEmbedding(dominant: 2)
        lowConf[0] = 0.3  // slightly closer to A so it picks A over B
        let result = tracker.identify(embedding: lowConf)
        XCTAssertEqual(result.speakerId, idA)
        XCTAssertLessThan(result.confidence, 0.5)  // low confidence

        // With weighted mean, the centroid should be closer to highConf than to lowConf
        let profiles = tracker.exportProfiles()
        let profileA = profiles.first { $0.speakerId == idA }!
        // dim 0 should be dominant (pulled toward highConf which has confidence 1.0)
        XCTAssertGreaterThan(profileA.embedding[0], profileA.embedding[2],
            "High-confidence embedding should have more influence on centroid")
    }

    func testNewSpeakerRegistrationHasConfidenceOne() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb)

        let detailed = tracker.exportDetailedProfiles()
        XCTAssertEqual(detailed[0].embeddingHistory.count, 1)
        XCTAssertEqual(detailed[0].embeddingHistory[0].confidence, 1.0)
    }

    func testCorrectAssignmentSetsUserCorrectionConfidence() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let idA = tracker.identify(embedding: embA).speakerId
        let idB = tracker.identify(embedding: embB).speakerId

        tracker.correctAssignment(embedding: embB, from: idB, to: idA)

        let detailed = tracker.exportDetailedProfiles()
        let profileA = detailed.first { $0.speakerId == idA }!
        // Auto mode: moved embedding should have userCorrectionConfidence (0.3), not 1.0,
        // to reduce centroid pollution speed.
        let movedEntry = profileA.embeddingHistory.first { $0.embedding == embB }
        XCTAssertNotNil(movedEntry)
        XCTAssertEqual(movedEntry!.confidence, Constants.Embedding.userCorrectionConfidence, accuracy: 0.001)
    }

    // MARK: - mergeProfile

    func testMergeProfile_movesHistoryAndRecalculatesCentroid() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let idA = tracker.identify(embedding: embA).speakerId
        let idB = tracker.identify(embedding: embB).speakerId

        tracker.mergeProfile(from: idB, into: idA)

        let profiles = tracker.exportDetailedProfiles()
        // Source profile should be gone
        XCTAssertNil(profiles.first { $0.speakerId == idB })
        // Target profile should have history entries from both
        let merged = profiles.first { $0.speakerId == idA }!
        XCTAssertEqual(merged.embeddingHistory.count, 2)
    }

    func testMergeProfile_nonexistentSource_noOp() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let idA = tracker.identify(embedding: embA).speakerId

        // Merging from a nonexistent UUID should be a no-op
        tracker.mergeProfile(from: UUID(), into: idA)

        let profiles = tracker.exportDetailedProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].embeddingHistory.count, 1)
    }

    // MARK: - Suppress Learning

    func testSuppressLearning_identifyDoesNotUpdateProfiles() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let idA = UUID()
        let idB = UUID()
        tracker.loadProfiles([
            (speakerId: idA, embedding: embA),
            (speakerId: idB, embedding: embB)
        ])
        tracker.suppressLearning = true

        // Identify 10 times with slight variations — profiles should NOT update
        for i in 0..<10 {
            var emb = makeEmbedding(dominant: 0)
            emb[2] = Float(i) * 0.02
            _ = tracker.identify(embedding: emb)
        }

        let detailed = tracker.exportDetailedProfiles()
        let profileA = detailed.first { $0.speakerId == idA }!
        let profileB = detailed.first { $0.speakerId == idB }!
        // Each profile should still have only the initial embedding from loadProfiles
        XCTAssertEqual(profileA.embeddingHistory.count, 1)
        XCTAssertEqual(profileB.embeddingHistory.count, 1)
    }

    func testSuppressLearning_identifyStillReturnsCorrectSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let idA = UUID()
        let idB = UUID()
        tracker.loadProfiles([
            (speakerId: idA, embedding: embA),
            (speakerId: idB, embedding: embB)
        ])
        tracker.suppressLearning = true

        let resultA = tracker.identify(embedding: embA)
        let resultB = tracker.identify(embedding: embB)
        XCTAssertEqual(resultA.speakerId, idA)
        XCTAssertEqual(resultB.speakerId, idB)
    }

    func testSuppressLearning_correctAssignmentRecordsCorrection_notCentroid() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let idA = UUID()
        let idB = UUID()
        tracker.loadProfiles([
            (speakerId: idA, embedding: embA),
            (speakerId: idB, embedding: embB)
        ])
        tracker.suppressLearning = true

        // Manual mode: correctAssignment should record UserCorrection, NOT update centroid
        tracker.correctAssignment(embedding: embA, from: idA, to: idB)

        // Profiles must remain unchanged (centroid frozen)
        let detailed = tracker.exportDetailedProfiles()
        let profileA = detailed.first { $0.speakerId == idA }!
        let profileB = detailed.first { $0.speakerId == idB }!
        XCTAssertEqual(profileA.embeddingHistory.count, 1, "profileA centroid must not change")
        XCTAssertEqual(profileB.embeddingHistory.count, 1, "profileB centroid must not change")

        // The correction is recorded in userCorrections
        let corrections = tracker.exportUserCorrections()
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections[0].fromId, idA)
        XCTAssertEqual(corrections[0].toId, idB)
    }

    func testSuppressLearning_atCapacityDoesNotUpdateProfiles() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let idA = UUID()
        let idB = UUID()
        tracker.loadProfiles([
            (speakerId: idA, embedding: embA),
            (speakerId: idB, embedding: embB)
        ])
        tracker.suppressLearning = true

        // Identify with a completely different embedding — at capacity, forced to best match
        let result = tracker.identify(embedding: makeEmbedding(dominant: 2))
        XCTAssertTrue(result.speakerId == idA || result.speakerId == idB)

        let detailed = tracker.exportDetailedProfiles()
        // No profile should have been updated
        for profile in detailed {
            XCTAssertEqual(profile.embeddingHistory.count, 1)
        }
    }

    // MARK: - At-Capacity Threshold Gate

    func testAtCapacity_lowSimilarityDoesNotUpdateProfile() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let idA = UUID()
        let idB = UUID()
        tracker.loadProfiles([
            (speakerId: idA, embedding: embA),
            (speakerId: idB, embedding: embB)
        ])
        // suppressLearning=false (auto mode), but low similarity should still be blocked

        // Completely different embedding — cosine sim will be well below 0.5
        let result = tracker.identify(embedding: makeEmbedding(dominant: 2))
        XCTAssertTrue(result.speakerId == idA || result.speakerId == idB,
            "Should still return a speaker ID")

        let detailed = tracker.exportDetailedProfiles()
        // The matched profile should NOT have the low-similarity embedding added
        for profile in detailed {
            XCTAssertEqual(profile.embeddingHistory.count, 1,
                "Low-similarity embedding should not be added to profile history")
        }
    }

    func testAtCapacity_highSimilarityUpdatesProfile() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let idA = UUID()
        let idB = UUID()
        tracker.loadProfiles([
            (speakerId: idA, embedding: embA),
            (speakerId: idB, embedding: embB)
        ])
        // suppressLearning=false (default), high similarity should update

        // Very similar to A — cosine sim will be well above 0.5
        var similar = makeEmbedding(dominant: 0)
        similar[2] = 0.1
        let result = tracker.identify(embedding: similar)
        XCTAssertEqual(result.speakerId, idA)

        let detailed = tracker.exportDetailedProfiles()
        let profileA = detailed.first { $0.speakerId == idA }!
        // This goes through Path 1 (above threshold), should update
        XCTAssertEqual(profileA.embeddingHistory.count, 2)
    }

    // MARK: - Thread Safety

    func testConcurrentIdentifyAndCorrectAssignment() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let idA = UUID()
        let idB = UUID()
        tracker.loadProfiles([
            (speakerId: idA, embedding: embA),
            (speakerId: idB, embedding: embB)
        ])

        let expectation = XCTestExpectation(description: "Concurrent access completes without crash")
        expectation.expectedFulfillmentCount = 2

        // Concurrent identify() calls
        DispatchQueue.global().async {
            for i in 0..<100 {
                var emb = self.makeEmbedding(dominant: 0)
                emb[2] = Float(i) * 0.01
                _ = tracker.identify(embedding: emb)
            }
            expectation.fulfill()
        }

        // Concurrent correctAssignment() calls
        DispatchQueue.global().async {
            for _ in 0..<100 {
                let emb = self.makeEmbedding(dominant: 0)
                tracker.correctAssignment(embedding: emb, from: idA, to: idB)
                tracker.correctAssignment(embedding: emb, from: idB, to: idA)
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
        // If we get here without crashing, the test passes
    }

    // MARK: - WeightedEmbedding entryId

    func testWeightedEmbedding_hasUniqueEntryId() {
        let a = WeightedEmbedding(embedding: [1.0, 2.0], confidence: 0.5)
        let b = WeightedEmbedding(embedding: [1.0, 2.0], confidence: 0.5)
        XCTAssertNotEqual(a.entryId, b.entryId, "Two WeightedEmbedding instances should have distinct entryIds even with identical content")
    }

    func testWeightedEmbedding_equalityIgnoresEntryId() {
        let a = WeightedEmbedding(embedding: [1.0, 2.0], confidence: 0.5)
        let b = WeightedEmbedding(embedding: [1.0, 2.0], confidence: 0.5)
        XCTAssertEqual(a, b, "Equality should compare embedding + confidence, not entryId")
    }

    func testWeightedEmbedding_explicitEntryIdPreserved() {
        let id = UUID()
        let a = WeightedEmbedding(entryId: id, embedding: [1.0], confidence: 1.0)
        XCTAssertEqual(a.entryId, id)
    }

    // MARK: - UserCorrections

    func testExportUserCorrections_initiallyEmpty() {
        let tracker = EmbeddingBasedSpeakerTracker()
        XCTAssertTrue(tracker.exportUserCorrections().isEmpty)
    }

    func testResetUserCorrections_clearsList() {
        let tracker = EmbeddingBasedSpeakerTracker()
        // 後段のタスクで correctAssignment 経由で要素を追加するが、
        // ここでは API の存在だけを検証する
        tracker.resetUserCorrections()
        XCTAssertTrue(tracker.exportUserCorrections().isEmpty)
    }

    // MARK: - correctAssignment with suppressLearning

    func testCorrectAssignment_suppressLearning_doesNotMutateCentroid() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let rA = tracker.identify(embedding: embA)
        let rB = tracker.identify(embedding: embB)

        tracker.suppressLearning = true
        let profileBefore = tracker.exportProfiles().map { (id: $0.speakerId, emb: $0.embedding) }

        // 誤認された embedding を修正する操作を 10 回繰り返す
        let bogus = makeEmbedding(dominant: 2)
        for _ in 0..<10 {
            tracker.correctAssignment(embedding: bogus, from: rB.speakerId, to: rA.speakerId)
        }

        let profileAfter = tracker.exportProfiles().map { (id: $0.speakerId, emb: $0.embedding) }

        XCTAssertEqual(profileBefore.count, profileAfter.count)
        for (before, after) in zip(profileBefore, profileAfter) {
            XCTAssertEqual(before.id, after.id)
            XCTAssertEqual(before.emb, after.emb, "centroid must not change while suppressLearning=true")
        }
    }

    func testCorrectAssignment_suppressLearning_recordsUserCorrection() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let rA = tracker.identify(embedding: makeEmbedding(dominant: 0))
        let rB = tracker.identify(embedding: makeEmbedding(dominant: 1))

        tracker.suppressLearning = true
        tracker.correctAssignment(embedding: makeEmbedding(dominant: 2), from: rB.speakerId, to: rA.speakerId)

        let corrections = tracker.exportUserCorrections()
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections[0].fromId, rB.speakerId)
        XCTAssertEqual(corrections[0].toId, rA.speakerId)
    }

    func testCorrectAssignment_nonSuppress_usesLowerConfidence() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        let rA = tracker.identify(embedding: embA)
        _ = tracker.identify(embedding: embB)

        // suppressLearning=false （デフォルト）
        let bogus = makeEmbedding(dominant: 2)
        tracker.correctAssignment(embedding: bogus, from: UUID(), to: rA.speakerId)

        // rA の profile に低 confidence (0.3) で追加されているはず
        let detailed = tracker.exportDetailedProfiles().first { $0.speakerId == rA.speakerId }!
        let newEntry = detailed.embeddingHistory.last!
        XCTAssertEqual(newEntry.confidence, Constants.Embedding.userCorrectionConfidence, accuracy: 0.001)
        XCTAssertEqual(newEntry.embedding, bogus)
    }

    // MARK: - correctAssignment with approximate match

    func testCorrectAssignment_removesMatchingEntryDespiteFloatJitter() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embOriginal = makeEmbedding(dominant: 0)
        let rA = tracker.identify(embedding: embOriginal)

        // 浮動小数点の僅かな揺らぎをシミュレート (最後の有効桁)
        var embJittered = embOriginal
        embJittered[0] = embOriginal[0] + 1e-7

        // jittered を使って修正（value exact match は失敗するはず）
        tracker.correctAssignment(embedding: embJittered, from: rA.speakerId, to: UUID())

        let detailed = tracker.exportDetailedProfiles()
        // rA の profile は空になって消えているはず (履歴 1 件だったのが 0 件 → 削除)
        XCTAssertFalse(detailed.contains(where: { $0.speakerId == rA.speakerId }),
            "jittered embedding should match within tolerance and trigger removal")
    }

    // MARK: - Tie-breaker

    func testIdentify_tieBreaker_prefersHigherHitCount() {
        let tracker = EmbeddingBasedSpeakerTracker()

        // 2 つの profile を初期化 (直接 loadProfiles で)
        let idA = UUID()
        let idB = UUID()
        let baseA = makeEmbedding(dominant: 0)
        let baseB = makeEmbedding(dominant: 1)
        tracker.loadProfiles([(speakerId: idA, embedding: baseA), (speakerId: idB, embedding: baseB)])

        // A を何度も identify して hitCount を増やす
        for _ in 0..<5 {
            _ = tracker.identify(embedding: baseA)
        }

        // A と B に等距離の embedding を投入
        let midpoint = zip(baseA, baseB).map { 0.5 * $0 + 0.5 * $1 }
        let result = tracker.identify(embedding: midpoint)

        XCTAssertEqual(result.speakerId, idA, "tie should prefer higher hitCount")
    }

    func testIdentify_tieBreaker_prefersLastConfirmed() {
        let tracker = EmbeddingBasedSpeakerTracker()

        let idA = UUID()
        let idB = UUID()
        let baseA = makeEmbedding(dominant: 0)
        let baseB = makeEmbedding(dominant: 1)
        tracker.loadProfiles([(speakerId: idA, embedding: baseA), (speakerId: idB, embedding: baseB)])
        tracker.suppressLearning = true   // hitCount 増加を防ぐため

        // 最後に B を confirm
        _ = tracker.identify(embedding: baseB)

        // 等距離 embedding を投入
        let midpoint = zip(baseA, baseB).map { 0.5 * $0 + 0.5 * $1 }
        let result = tracker.identify(embedding: midpoint)

        XCTAssertEqual(result.speakerId, idB, "tie with equal hitCount should prefer lastConfirmedId")
    }
}
