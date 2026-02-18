import XCTest
@testable import QuickTranscriberLib

final class EmbeddingBasedSpeakerTrackerTests: XCTestCase {

    // Helper: create a normalized embedding with a dominant dimension
    private func makeEmbedding(dominant dim: Int, dimensions: Int = 256) -> [Float] {
        var v = [Float](repeating: 0.01, count: dimensions)
        v[dim] = 1.0
        return v
    }

    // MARK: - First speaker is registered and labeled

    func testFirstSpeakerGetsLabelA() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        let result = tracker.identify(embedding: emb)
        XCTAssertEqual(result.label, "A")
    }

    // MARK: - Same speaker returns same label

    func testSameSpeakerReturnsSameLabel() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb)
        let result = tracker.identify(embedding: emb)
        XCTAssertEqual(result.label, "A")
    }

    // MARK: - Different speaker gets new label

    func testDifferentSpeakerGetsNewLabel() {
        let tracker = EmbeddingBasedSpeakerTracker()
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
        let result = tracker.identify(embedding: makeEmbedding(dominant: 1))
        XCTAssertEqual(result.label, "B")
    }

    // MARK: - Three distinct speakers

    func testThreeDistinctSpeakers() {
        let tracker = EmbeddingBasedSpeakerTracker()
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 0)).label, "A")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 1)).label, "B")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 2)).label, "C")
    }

    // MARK: - Return to first speaker

    func testReturnToFirstSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        _ = tracker.identify(embedding: embA)
        _ = tracker.identify(embedding: embB)
        let result = tracker.identify(embedding: embA)
        XCTAssertEqual(result.label, "A")
    }

    // MARK: - Similar embeddings match (slight variation)

    func testSimilarEmbeddingsMatchSameSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb1 = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb1)

        // Slightly perturbed version of same speaker
        var emb2 = emb1
        emb2[1] = 0.15
        emb2[2] = 0.1
        let result = tracker.identify(embedding: emb2)
        XCTAssertEqual(result.label, "A")
    }

    // MARK: - Profile update (moving average)

    func testProfileUpdatesOverTime() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb1 = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb1)

        // Feed slightly drifted embedding multiple times
        var drifted = makeEmbedding(dominant: 0)
        drifted[3] = 0.3
        for _ in 0..<5 {
            let result = tracker.identify(embedding: drifted)
            XCTAssertEqual(result.label, "A")
        }
        // Profile should have adapted toward drifted embedding
        // Verify by checking the profile still matches drifted
        XCTAssertEqual(tracker.identify(embedding: drifted).label, "A")
    }

    // MARK: - Reset clears all profiles

    func testResetClearsProfiles() {
        let tracker = EmbeddingBasedSpeakerTracker()
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))
        tracker.reset()
        // After reset, next speaker starts from A again
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 2)).label, "A")
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
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 0)).label, "A")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 1)).label, "B")
        // Third distinct voice should NOT create "C" — should assign to closest existing
        let result = tracker.identify(embedding: makeEmbedding(dominant: 2))
        XCTAssertNotEqual(result.label, "C", "Should not create a third speaker when limit is 2")
        XCTAssertTrue(result.label == "A" || result.label == "B", "Should assign to existing speaker")
    }

    func testExpectedSpeakerCountAssignsToBestMatch() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))  // A
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))  // B

        // Create embedding closer to speaker A (dominant dim 0, with small contribution from dim 2)
        var closerToA = makeEmbedding(dominant: 2)
        closerToA[0] = 0.5  // Add similarity to A
        let result = tracker.identify(embedding: closerToA)
        XCTAssertEqual(result.label, "A", "Should assign to most similar existing speaker (A)")
    }

    func testNilExpectedSpeakerCountAllowsUnlimited() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: nil)
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 0)).label, "A")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 1)).label, "B")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 2)).label, "C")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 3)).label, "D")
    }

    // MARK: - Export / Load Profiles

    func testExportProfilesReturnsRegisteredSpeakers() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        _ = tracker.identify(embedding: embA)
        _ = tracker.identify(embedding: embB)

        let exported = tracker.exportProfiles()
        XCTAssertEqual(exported.count, 2)
        XCTAssertEqual(exported[0].label, "A")
        XCTAssertEqual(exported[1].label, "B")
    }

    func testLoadProfilesInitializesTracker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        tracker.loadProfiles([
            (label: "A", embedding: embA),
            (label: "B", embedding: embB)
        ])

        let result = tracker.identify(embedding: embA)
        XCTAssertEqual(result.label, "A")
    }

    func testLoadProfilesNextLabelContinuesFromLoaded() {
        let tracker = EmbeddingBasedSpeakerTracker()
        tracker.loadProfiles([
            (label: "A", embedding: makeEmbedding(dominant: 0)),
            (label: "B", embedding: makeEmbedding(dominant: 1))
        ])

        let result = tracker.identify(embedding: makeEmbedding(dominant: 2))
        XCTAssertEqual(result.label, "C", "New speaker should get next label after loaded profiles")
    }

    func testLoadProfilesClearsExistingState() {
        let tracker = EmbeddingBasedSpeakerTracker()
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))

        tracker.loadProfiles([
            (label: "X", embedding: makeEmbedding(dominant: 2))
        ])

        let exported = tracker.exportProfiles()
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported[0].label, "X")
    }

    // MARK: - Profile Strategy

    func testProfileStrategyNoneIsDefault() {
        let tracker = EmbeddingBasedSpeakerTracker()
        // Default strategy should behave identically to current behavior
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 0)).label, "A")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 1)).label, "B")
        XCTAssertEqual(tracker.identify(embedding: makeEmbedding(dominant: 2)).label, "C")
    }

    func testHitCountIncrementsOnMatch() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: emb)  // Register A
        _ = tracker.identify(embedding: emb)  // Match A
        _ = tracker.identify(embedding: emb)  // Match A

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].hitCount, 3)
    }

    // MARK: - Culling Strategy

    func testCullingRemovesLowHitProfiles() {
        let tracker = EmbeddingBasedSpeakerTracker(strategy: .culling(interval: 5, minHits: 2))

        let embA = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: embA)  // Register A, hit=1
        _ = tracker.identify(embedding: embA)  // Match A, hit=2
        _ = tracker.identify(embedding: embA)  // Match A, hit=3

        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))  // Register B, hit=1

        // 5th call triggers maintenance: B has hitCount=1 < minHits=2, should be culled
        _ = tracker.identify(embedding: embA)  // identifyCount=5, triggers maintenance

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles.count, 1, "B should have been culled")
        XCTAssertEqual(profiles[0].label, "A")
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

        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))  // Register A

        // This embedding has sim~0.39 with A: below 0.5 (no match) but above 0.3 (gated)
        var embSomewhatSimilar = makeEmbedding(dominant: 3)
        embSomewhatSimilar[0] = 0.4
        let result = tracker.identify(embedding: embSomewhatSimilar)

        XCTAssertEqual(result.label, "A", "Should be gated to existing speaker A")
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
        _ = tracker.identify(embedding: embA)  // 1: Register A, hit=1
        _ = tracker.identify(embedding: embA)  // 2: Match A, hit=2
        _ = tracker.identify(embedding: embA)  // 3: Match A, hit=3

        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))  // 4: Register B, hit=1

        _ = tracker.identify(embedding: embA)  // 5: Triggers maintenance, B has hit=1 < minHits=2, culled

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles.count, 1, "B should have been culled")
        XCTAssertEqual(profiles[0].label, "A")
    }

    // MARK: - Confidence Score

    func testIdentifyReturnsConfidenceForNewSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let result = tracker.identify(embedding: makeEmbedding(dominant: 0))
        XCTAssertEqual(result.label, "A")
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.001)
    }

    func testIdentifyReturnsConfidenceForMatchedSpeaker() {
        let tracker = EmbeddingBasedSpeakerTracker()
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
        var similar = makeEmbedding(dominant: 0)
        similar[1] = 0.15
        let result = tracker.identify(embedding: similar)
        XCTAssertEqual(result.label, "A")
        XCTAssertGreaterThan(result.confidence, 0.5)
        XCTAssertLessThan(result.confidence, 1.0)
    }

    func testIdentifyReturnsLowConfidenceForForcedAssignment() {
        let tracker = EmbeddingBasedSpeakerTracker(expectedSpeakerCount: 2)
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))
        _ = tracker.identify(embedding: makeEmbedding(dominant: 1))
        let result = tracker.identify(embedding: makeEmbedding(dominant: 2))
        XCTAssertTrue(result.label == "A" || result.label == "B")
        XCTAssertLessThan(result.confidence, 0.5)
    }

    // MARK: - correctSpeaker

    func testCorrectSpeakerSwapsBothExisting() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        _ = tracker.identify(embedding: embA)  // A
        _ = tracker.identify(embedding: embB)  // B

        let result = tracker.correctSpeaker(from: "A", to: "B")
        XCTAssertTrue(result)

        // After swap: embA's profile is now labeled B, embB's profile is now labeled A
        let profiles = tracker.exportProfiles()
        let profileA = profiles.first { $0.label == "A" }
        let profileB = profiles.first { $0.label == "B" }
        XCTAssertNotNil(profileA)
        XCTAssertNotNil(profileB)

        // Verify by identifying with original embeddings
        let resultA = tracker.identify(embedding: embA)
        XCTAssertEqual(resultA.label, "B", "embA should now match profile B after swap")
        let resultB = tracker.identify(embedding: embB)
        XCTAssertEqual(resultB.label, "A", "embB should now match profile A after swap")
    }

    func testCorrectSpeakerRenamesFromOnly() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        _ = tracker.identify(embedding: embA)  // A

        let result = tracker.correctSpeaker(from: "A", to: "X")
        XCTAssertTrue(result)

        let profiles = tracker.exportProfiles()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].label, "X")

        // Original embedding should now match X
        let resultX = tracker.identify(embedding: embA)
        XCTAssertEqual(resultX.label, "X")
    }

    func testCorrectSpeakerReturnsFalseForNonexistentFrom() {
        let tracker = EmbeddingBasedSpeakerTracker()
        _ = tracker.identify(embedding: makeEmbedding(dominant: 0))  // A

        let result = tracker.correctSpeaker(from: "Z", to: "A")
        XCTAssertFalse(result)
    }

    // MARK: - SpeakerIdentification embedding

    func testIdentifyIncludesEmbedding() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let emb = makeEmbedding(dominant: 0)
        let result = tracker.identify(embedding: emb)
        XCTAssertNotNil(result.embedding)
        XCTAssertEqual(result.embedding?.count, 256)
    }

    func testSpeakerIdentificationEqualityIgnoresEmbedding() {
        let id1 = SpeakerIdentification(label: "A", confidence: 0.9, embedding: [1.0, 2.0])
        let id2 = SpeakerIdentification(label: "A", confidence: 0.9, embedding: [3.0, 4.0])
        XCTAssertEqual(id1, id2, "Equality should only compare label and confidence")
    }

    func testSpeakerIdentificationEqualityWithNilEmbedding() {
        let id1 = SpeakerIdentification(label: "A", confidence: 0.9, embedding: nil)
        let id2 = SpeakerIdentification(label: "A", confidence: 0.9, embedding: [1.0])
        XCTAssertEqual(id1, id2)
    }

    func testCorrectSpeakerChainedCorrections() {
        let tracker = EmbeddingBasedSpeakerTracker()
        let embA = makeEmbedding(dominant: 0)
        let embB = makeEmbedding(dominant: 1)
        _ = tracker.identify(embedding: embA)  // A
        _ = tracker.identify(embedding: embB)  // B

        // First: swap A↔B
        XCTAssertTrue(tracker.correctSpeaker(from: "A", to: "B"))
        // Then: swap back A↔B
        XCTAssertTrue(tracker.correctSpeaker(from: "A", to: "B"))

        // Should be back to original state
        XCTAssertEqual(tracker.identify(embedding: embA).label, "A")
        XCTAssertEqual(tracker.identify(embedding: embB).label, "B")
    }
}
